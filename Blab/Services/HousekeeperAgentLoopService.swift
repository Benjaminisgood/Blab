import Foundation

struct HousekeeperAgentLoopStats: Codable {
    var rounds: Int
    var toolCalls: Int
    var emptyToolResults: Int
    var invalidDecisionCount: Int
    var repairedDecisionCount: Int
    var repeatedToolBlocked: Bool
    var usedFallbackPlan: Bool
}

struct HousekeeperAgentLoopResult {
    var plan: AgentPlan
    var trace: [String]
    var stats: HousekeeperAgentLoopStats
}

struct HousekeeperLoopSelfCheckReport: Codable {
    var generatedAt: Date
    var entries: [HousekeeperLoopSelfCheckEntry]

    var ok: Bool {
        entries.allSatisfy(\.passed)
    }
}

struct HousekeeperLoopSelfCheckEntry: Codable {
    var name: String
    var passed: Bool
    var detail: String
}

enum HousekeeperAgentLoopService {
    private static let maxSameToolCall = 2
    private static let maxTraceLines = 40
    private static let maxTraceLineCharacters = 260
    private static let maxObservationCount = 12
    private static let defaultSearchLimit = 5
    private static let broadSearchLimit = 30
    private static let maxSearchLimit = 50

    static func plan(
        instruction: String,
        settings: AISettings,
        context: AgentPlannerContext,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member],
        maxSteps: Int = 6
    ) async throws -> HousekeeperAgentLoopResult {
        try await runLoop(
            instruction: instruction,
            settings: settings,
            context: context,
            items: items,
            locations: locations,
            events: events,
            members: members,
            maxSteps: maxSteps,
            mode: .planning
        )
    }

    static func repairPlan(
        originalInput: String,
        previousPlan: AgentPlan,
        failedEntries: [AgentExecutionEntry],
        settings: AISettings,
        context: AgentPlannerContext,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member],
        maxSteps: Int = 6
    ) async throws -> HousekeeperAgentLoopResult {
        guard !failedEntries.isEmpty else {
            throw plannerError("当前无失败项，无需自动修复。")
        }

        return try await runLoop(
            instruction: originalInput,
            settings: settings,
            context: context,
            items: items,
            locations: locations,
            events: events,
            members: members,
            maxSteps: maxSteps,
            mode: .repair(previousPlan: previousPlan, failedEntries: failedEntries)
        )
    }

    static func selfCheckReport() -> HousekeeperLoopSelfCheckReport {
        var entries: [HousekeeperLoopSelfCheckEntry] = []

        entries.append(checkDecisionDecodeDirectJSON())
        entries.append(checkDecisionDecodeFencedJSON())
        entries.append(checkDecisionDecodeEmbeddedJSONBlock())
        entries.append(checkDecisionDecodeRejectsInvalidPayload())
        entries.append(checkLoopGuardRepeatedToolBlocking())
        entries.append(checkLoopGuardMaxRoundsFallback())
        entries.append(checkLoopToolRegistryConsistency())

        return HousekeeperLoopSelfCheckReport(
            generatedAt: .now,
            entries: entries
        )
    }

    private static func runLoop(
        instruction: String,
        settings: AISettings,
        context: AgentPlannerContext,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member],
        maxSteps: Int,
        mode: FinalizationMode
    ) async throws -> HousekeeperAgentLoopResult {
        let cleanedInstruction = instruction.trimmedNonEmpty
        guard let cleanedInstruction else {
            throw plannerError("请输入要执行的自然语言指令。")
        }

        guard settings.autoFillEnabled else {
            throw plannerError("AI 自动填写未启用，请先在设置页开启后再使用。")
        }

        var observations: [String] = []
        var trace: [String] = []
        var repeatedCallCounter: [String: Int] = [:]
        var stats = HousekeeperAgentLoopStats(
            rounds: 0,
            toolCalls: 0,
            emptyToolResults: 0,
            invalidDecisionCount: 0,
            repairedDecisionCount: 0,
            repeatedToolBlocked: false,
            usedFallbackPlan: false
        )

        if let readOnlyPlan = buildReadOnlyPlanIfNeeded(
            instruction: cleanedInstruction,
            currentMemberName: context.currentMemberName,
            currentMemberUsername: context.currentMemberUsername,
            items: items,
            locations: locations,
            events: events,
            members: members
        ) {
            stats.rounds = 1
            appendTrace(&trace, "第1轮：检测到只读查询意图，直接返回检索结果。")
            return HousekeeperAgentLoopResult(plan: readOnlyPlan, trace: trace, stats: stats)
        }

        let boundedMaxSteps = max(1, maxSteps)

        for step in 1...boundedMaxSteps {
            stats.rounds = step
            let loopPrompt = buildLoopPrompt(
                instruction: cleanedInstruction,
                context: context,
                observations: observations,
                step: step,
                maxSteps: boundedMaxSteps
            )

            let rawReply = try await AIChatService.complete(
                prompt: loopPrompt,
                settings: settings,
                maxTokens: 700,
                systemPrompt: HousekeeperPromptGuide.dispatcherPlaybook
            )
            guard let decision = await decodeDecisionWithRepair(
                rawReply: rawReply,
                settings: settings,
                step: step,
                trace: &trace,
                stats: &stats
            ) else {
                let parseFailure = "decision_parse_failed(step=\(step))"
                observations.append(parseFailure)
                continue
            }

            switch decision.type {
            case .plan:
                let enrichedInstruction = enrichInstruction(cleanedInstruction, observations: observations)
                let plan = try await finalizePlan(
                    instruction: enrichedInstruction,
                    settings: settings,
                    context: context,
                    mode: mode
                )
                appendTrace(&trace, "第\(step)轮：决策=plan，进入\(phaseLabel(for: mode))。")
                return HousekeeperAgentLoopResult(plan: plan, trace: trace, stats: stats)

            case .clarification:
                let clarification = decision.clarification?.trimmedNonEmpty
                    ?? "当前信息不足，请补充更具体的对象、时间或范围。"
                let plan = AgentPlan(operations: [], clarification: clarification)
                appendTrace(&trace, "第\(step)轮：决策=clarification。")
                return HousekeeperAgentLoopResult(plan: plan, trace: trace, stats: stats)

            case .tool:
                guard let toolName = decision.tool?.trimmedNonEmpty else {
                    stats.invalidDecisionCount += 1
                    let reason = "tool_validation_error: 缺少 tool 字段"
                    observations.append(reason)
                    appendTrace(&trace, "第\(step)轮：\(reason)")
                    continue
                }
                guard let tool = LoopTool(rawValue: toolName) else {
                    stats.invalidDecisionCount += 1
                    let reason = "tool_validation_error: 不支持的 tool=\(toolName)"
                    observations.append(reason)
                    appendTrace(&trace, "第\(step)轮：\(reason)")
                    continue
                }

                if let validationError = validateToolDecision(tool: tool, decision: decision) {
                    stats.invalidDecisionCount += 1
                    let reason = "tool_validation_error(tool=\(tool.rawValue)): \(validationError)"
                    observations.append(reason)
                    appendTrace(&trace, "第\(step)轮：\(reason)")
                    continue
                }

                let signature = toolSignature(
                    name: tool.rawValue,
                    query: decision.query,
                    target: decision.target,
                    entity: decision.entity,
                    limit: decision.limit
                )
                let callCount = repeatedCallCounter[signature, default: 0] + 1
                repeatedCallCounter[signature] = callCount

                if callCount > maxSameToolCall {
                    if tool.isSearchTool,
                       shouldFastTrackCreatePlanning(for: cleanedInstruction) {
                        appendTrace(&trace, "第\(step)轮：重复检索被拦截，检测到新增意图，直接进入\(phaseLabel(for: mode))。")
                        let enrichedInstruction = enrichInstruction(cleanedInstruction, observations: observations)
                        let plan = try await finalizePlan(
                            instruction: enrichedInstruction,
                            settings: settings,
                            context: context,
                            mode: mode
                        )
                        return HousekeeperAgentLoopResult(plan: plan, trace: trace, stats: stats)
                    }
                    let clarification = "系统已多次尝试同一检索仍无进展，请补充更明确的信息（例如精确名称、用户名、时间）。"
                    stats.repeatedToolBlocked = true
                    appendTrace(&trace, "第\(step)轮：重复工具调用被拦截 -> \(signature)")
                    return HousekeeperAgentLoopResult(
                        plan: AgentPlan(operations: [], clarification: clarification),
                        trace: trace,
                        stats: stats
                    )
                }

                let outcome = executeTool(
                    tool: tool,
                    query: decision.query,
                    target: decision.target,
                    limit: decision.limit,
                    currentMemberName: context.currentMemberName,
                    currentMemberUsername: context.currentMemberUsername,
                    items: items,
                    locations: locations,
                    events: events,
                    members: members
                )
                stats.toolCalls += 1
                if outcome.isEmptyResult {
                    stats.emptyToolResults += 1
                }
                observations.append(outcome.observation)
                appendTrace(&trace, "第\(step)轮：\(outcome.brief)")

                if tool.isSearchTool,
                   outcome.isEmptyResult,
                   shouldFastTrackCreatePlanning(for: cleanedInstruction) {
                    appendTrace(&trace, "第\(step)轮：检索为空且输入是新增意图，直接进入\(phaseLabel(for: mode))。")
                    let enrichedInstruction = enrichInstruction(cleanedInstruction, observations: observations)
                    let plan = try await finalizePlan(
                        instruction: enrichedInstruction,
                        settings: settings,
                        context: context,
                        mode: mode
                    )
                    return HousekeeperAgentLoopResult(plan: plan, trace: trace, stats: stats)
                }
            }
        }

        stats.usedFallbackPlan = true
        appendTrace(&trace, "达到最大轮次（\(boundedMaxSteps)），转入兜底\(phaseLabel(for: mode))。")
        let fallbackInstruction = enrichInstruction(cleanedInstruction, observations: observations)
        let plan = try await finalizePlan(
            instruction: fallbackInstruction,
            settings: settings,
            context: context,
            mode: mode
        )
        return HousekeeperAgentLoopResult(plan: plan, trace: trace, stats: stats)
    }

    private static func finalizePlan(
        instruction: String,
        settings: AISettings,
        context: AgentPlannerContext,
        mode: FinalizationMode
    ) async throws -> AgentPlan {
        switch mode {
        case .planning:
            return try await AgentPlannerService.plan(
                input: instruction,
                settings: settings,
                context: context
            )
        case let .repair(previousPlan, failedEntries):
            return try await AgentPlannerService.repairPlan(
                originalInput: instruction,
                previousPlan: previousPlan,
                failedEntries: failedEntries,
                settings: settings,
                context: context
            )
        }
    }

    private static func phaseLabel(for mode: FinalizationMode) -> String {
        switch mode {
        case .planning:
            return "计划生成"
        case .repair:
            return "修复计划生成"
        }
    }

    private static func buildLoopPrompt(
        instruction: String,
        context: AgentPlannerContext,
        observations: [String],
        step: Int,
        maxSteps: Int
    ) -> String {
        let contextJSON = encodeJSONString(context)
        let toolSchemaTokenList = LoopTool.schemaTokenList
        let toolCatalogText = LoopTool.catalogPromptText
        let boundedObservations = Array(observations.suffix(maxObservationCount))
        let observationText: String
        if boundedObservations.isEmpty {
            observationText = "暂无工具结果。"
        } else {
            let prefix = observations.count > boundedObservations.count
                ? "（仅展示最近 \(boundedObservations.count) 条观察）\n"
                : ""
            observationText = prefix + boundedObservations.enumerated().map { index, value in
                "\(index + 1). \(value)"
            }
            .joined(separator: "\n")
        }

        return """
你是 Blab 的智能保姆调度器。你的职责是先判断是否需要检索，再决定是生成计划还是追问用户。

当前轮次：\(step)/\(maxSteps)
你本轮必须只输出一个 JSON 对象，不要 Markdown，不要解释。

可用动作：
1) tool：调用一个只读工具
2) plan：信息足够，进入计划生成
3) clarification：信息不足，向用户追问

JSON Schema：
{
  "type": "tool|plan|clarification",
  "tool": "\(toolSchemaTokenList)",
  "query": "字符串，可选（search_* 推荐填写关键词；全量查询可留空）",
  "target": "字符串，可选（get_* 必填）",
  "entity": "item|location|event|member，可选",
  "limit": 1-50 的整数，可选，默认 5,
  "clarification": "当 type=clarification 时必填"
}

工具目录（单一注册表）：
\(toolCatalogText)

决策规则：
- 如果目标对象不明确或可能重名，优先 tool。
- 如果已有信息足够生成可执行计划，输出 type=plan。
- 如果多次检索仍不足，输出 type=clarification。
- 如果上一轮给出参数错误或检索为空，优先改用其它工具/参数继续尝试。
- 对“所有/全部/有什么/有哪些/什么”这类范围查询，可先做范围检索，不要立即追问精确名称。
- 对明确的新增意图（已给出核心字段）优先直接 plan，不要反复检索是否已存在。
- 不要重复同一工具+参数组合。

当前数据上下文：
\(contextJSON)

用户输入：
\(instruction)

已有工具观察：
\(observationText)
"""
    }

    private static func executeTool(
        tool: LoopTool,
        query: String?,
        target: String?,
        limit: Int?,
        currentMemberName: String?,
        currentMemberUsername: String?,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member]
    ) -> ToolExecutionOutcome {
        let safeLimit = clampSearchLimit(limit)

        switch tool {
        case .searchItems:
            let q = query?.trimmed ?? ""
            let results = searchItems(
                query: q,
                items: items,
                limit: safeLimit,
                currentMemberName: currentMemberName,
                currentMemberUsername: currentMemberUsername
            )
            return ToolExecutionOutcome(
                observation: "search_items(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_items resultCount=\(results.count)",
                resultCount: results.count
            )

        case .searchLocations:
            let q = query?.trimmed ?? ""
            let results = searchLocations(query: q, locations: locations, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_locations(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_locations resultCount=\(results.count)",
                resultCount: results.count
            )

        case .searchEvents:
            let q = query?.trimmed ?? ""
            let results = searchEvents(query: q, events: events, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_events(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_events resultCount=\(results.count)",
                resultCount: results.count
            )

        case .searchMembers:
            let q = query?.trimmed ?? ""
            let results = searchMembers(query: q, members: members, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_members(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_members resultCount=\(results.count)",
                resultCount: results.count
            )

        case .getItem:
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getItem(token: token, items: items)
            return ToolExecutionOutcome(
                observation: "get_item(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_item found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        case .getLocation:
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getLocation(token: token, locations: locations)
            return ToolExecutionOutcome(
                observation: "get_location(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_location found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        case .getEvent:
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getEvent(token: token, events: events)
            return ToolExecutionOutcome(
                observation: "get_event(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_event found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        case .getMember:
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getMember(token: token, members: members)
            return ToolExecutionOutcome(
                observation: "get_member(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_member found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )
        }
    }

    private static func searchItems(
        query: String,
        items: [LabItem],
        limit: Int,
        currentMemberName: String?,
        currentMemberUsername: String?
    ) -> [ItemDigest] {
        let profile = parseItemSearchProfile(query)
        let effectiveLimit = effectiveSearchLimit(baseLimit: limit, prefersBroadResult: profile.prefersBroadResult)
        let filtered = items.filter { item in
            if profile.ownOnly,
               !matchesCurrentMember(
                item: item,
                currentMemberName: currentMemberName,
                currentMemberUsername: currentMemberUsername
               ) {
                return false
            }
            if let feature = profile.featureFilter, item.feature != feature {
                return false
            }
            return true
        }

        let ranked = filtered.map { item -> (Int, LabItem) in
            let relevance = relevanceScore(
                candidate: item.name.normalizedToken,
                fullToken: profile.combinedToken,
                terms: profile.terms
            )
            return (relevance, item)
        }
        .filter { profile.prefersBroadResult || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(effectiveLimit)

        return ranked.map { _, item in
            ItemDigest(
                id: item.id.uuidString,
                name: item.name,
                status: item.statusRaw,
                feature: item.featureRaw,
                responsibleMembers: item.responsibleMembers.map(\.displayName),
                locations: item.locations.map(\.name)
            )
        }
    }

    private static func searchLocations(query: String, locations: [LabLocation], limit: Int) -> [LocationDigest] {
        let profile = parseGenericSearchProfile(
            query: query,
            entityStopwords: ["位置", "地点", "区域", "房间", "空间", "场所"]
        )
        let effectiveLimit = effectiveSearchLimit(baseLimit: limit, prefersBroadResult: profile.prefersBroadResult)
        let ranked = locations.map { location -> (Int, LabLocation) in
            let relevance = relevanceScore(
                candidate: location.name.normalizedToken,
                fullToken: profile.combinedToken,
                terms: profile.terms
            )
            return (relevance, location)
        }
        .filter { profile.prefersBroadResult || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(effectiveLimit)

        return ranked.map { _, location in
            LocationDigest(
                id: location.id.uuidString,
                name: location.name,
                status: location.statusRaw,
                isPublic: location.isPublic,
                parentName: location.parent?.name,
                responsibleMembers: location.responsibleMembers.map(\.displayName)
            )
        }
    }

    private static func searchEvents(query: String, events: [LabEvent], limit: Int) -> [EventDigest] {
        let profile = parseGenericSearchProfile(
            query: query,
            entityStopwords: ["事项", "活动", "任务", "日程", "安排", "事件"]
        )
        let effectiveLimit = effectiveSearchLimit(baseLimit: limit, prefersBroadResult: profile.prefersBroadResult)
        let ranked = events.map { event -> (Int, LabEvent) in
            let relevance = relevanceScore(
                candidate: event.title.normalizedToken,
                fullToken: profile.combinedToken,
                terms: profile.terms
            )
            return (relevance, event)
        }
        .filter { profile.prefersBroadResult || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(effectiveLimit)

        return ranked.map { _, event in
            EventDigest(
                id: event.id.uuidString,
                title: event.title,
                ownerName: event.owner?.displayName,
                visibility: event.visibilityRaw,
                startTimeISO: event.startTime?.iso8601String,
                endTimeISO: event.endTime?.iso8601String
            )
        }
    }

    private static func searchMembers(query: String, members: [Member], limit: Int) -> [MemberDigest] {
        let profile = parseGenericSearchProfile(
            query: query,
            entityStopwords: ["成员", "人员", "用户", "同事", "账号"]
        )
        let effectiveLimit = effectiveSearchLimit(baseLimit: limit, prefersBroadResult: profile.prefersBroadResult)
        let ranked = members.map { member -> (Int, Member) in
            let displayName = member.displayName.normalizedToken
            let username = member.username.normalizedToken
            let relevance = max(
                relevanceScore(candidate: displayName, fullToken: profile.combinedToken, terms: profile.terms),
                relevanceScore(candidate: username, fullToken: profile.combinedToken, terms: profile.terms)
            )
            return (relevance, member)
        }
        .filter { profile.prefersBroadResult || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.displayName.localizedCaseInsensitiveCompare(rhs.1.displayName) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(effectiveLimit)

        return ranked.map { _, member in
            MemberDigest(
                id: member.id.uuidString,
                name: member.displayName,
                username: member.username,
                contact: member.contact
            )
        }
    }

    private static func getItem(token: String, items: [LabItem]) -> ItemDigest? {
        guard let item = resolveItem(token: token, items: items) else { return nil }
        return ItemDigest(
            id: item.id.uuidString,
            name: item.name,
            status: item.statusRaw,
            feature: item.featureRaw,
            responsibleMembers: item.responsibleMembers.map(\.displayName),
            locations: item.locations.map(\.name)
        )
    }

    private static func getLocation(token: String, locations: [LabLocation]) -> LocationDigest? {
        guard let location = resolveLocation(token: token, locations: locations) else { return nil }
        return LocationDigest(
            id: location.id.uuidString,
            name: location.name,
            status: location.statusRaw,
            isPublic: location.isPublic,
            parentName: location.parent?.name,
            responsibleMembers: location.responsibleMembers.map(\.displayName)
        )
    }

    private static func getEvent(token: String, events: [LabEvent]) -> EventDigest? {
        guard let event = resolveEvent(token: token, events: events) else { return nil }
        return EventDigest(
            id: event.id.uuidString,
            title: event.title,
            ownerName: event.owner?.displayName,
            visibility: event.visibilityRaw,
            startTimeISO: event.startTime?.iso8601String,
            endTimeISO: event.endTime?.iso8601String
        )
    }

    private static func getMember(token: String, members: [Member]) -> MemberDigest? {
        guard let member = resolveMember(token: token, members: members) else { return nil }
        return MemberDigest(
            id: member.id.uuidString,
            name: member.displayName,
            username: member.username,
            contact: member.contact
        )
    }

    private static func resolveItem(token: String, items: [LabItem]) -> LabItem? {
        let cleaned = token.trimmedNonEmpty
        guard let cleaned else { return nil }

        if let uuid = UUID(uuidString: cleaned),
           let matched = items.first(where: { $0.id == uuid }) {
            return matched
        }

        let normalized = cleaned.normalizedToken
        return items.first(where: { $0.name.normalizedToken == normalized })
            ?? items.first(where: { $0.name.normalizedToken.contains(normalized) })
    }

    private static func resolveLocation(token: String, locations: [LabLocation]) -> LabLocation? {
        let cleaned = token.trimmedNonEmpty
        guard let cleaned else { return nil }

        if let uuid = UUID(uuidString: cleaned),
           let matched = locations.first(where: { $0.id == uuid }) {
            return matched
        }

        let normalized = cleaned.normalizedToken
        return locations.first(where: { $0.name.normalizedToken == normalized })
            ?? locations.first(where: { $0.name.normalizedToken.contains(normalized) })
    }

    private static func resolveEvent(token: String, events: [LabEvent]) -> LabEvent? {
        let cleaned = token.trimmedNonEmpty
        guard let cleaned else { return nil }

        if let uuid = UUID(uuidString: cleaned),
           let matched = events.first(where: { $0.id == uuid }) {
            return matched
        }

        let normalized = cleaned.normalizedToken
        return events.first(where: { $0.title.normalizedToken == normalized })
            ?? events.first(where: { $0.title.normalizedToken.contains(normalized) })
    }

    private static func resolveMember(token: String, members: [Member]) -> Member? {
        let cleaned = token.trimmedNonEmpty
        guard let cleaned else { return nil }

        if let uuid = UUID(uuidString: cleaned),
           let matched = members.first(where: { $0.id == uuid }) {
            return matched
        }

        let normalized = cleaned.normalizedToken
        return members.first(where: { $0.username.normalizedToken == normalized || $0.displayName.normalizedToken == normalized })
            ?? members.first(where: {
                $0.username.normalizedToken.contains(normalized) || $0.displayName.normalizedToken.contains(normalized)
            })
    }

    private static func enrichInstruction(_ instruction: String, observations: [String]) -> String {
        guard !observations.isEmpty else { return instruction }
        let joined = observations.enumerated().map { index, value in
            "\(index + 1). \(value)"
        }
        .joined(separator: "\n")

        return """
用户原始输入：
\(instruction)

系统检索观察（仅供定位目标与消歧）：
\(joined)

请基于以上信息生成可执行计划。
"""
    }

    private static func toolSignature(
        name: String,
        query: String?,
        target: String?,
        entity: String?,
        limit: Int?
    ) -> String {
        [
            "tool=\(name)",
            "query=\(query?.trimmed ?? "")",
            "target=\(target?.trimmed ?? "")",
            "entity=\(entity?.trimmed ?? "")",
            "limit=\(limit ?? 0)"
        ]
        .joined(separator: "|")
    }

    private static func validateToolDecision(tool: LoopTool, decision: LoopDecision) -> String? {
        if tool.requiresTarget {
            guard decision.target?.trimmedNonEmpty != nil || decision.query?.trimmedNonEmpty != nil else {
                return "\(tool.rawValue) 缺少 target（或 query 兜底）。"
            }
        }
        return nil
    }

    private static func decodeDecisionWithRepair(
        rawReply: String,
        settings: AISettings,
        step: Int,
        trace: inout [String],
        stats: inout HousekeeperAgentLoopStats
    ) async -> LoopDecision? {
        if let direct = try? decodeDecision(from: rawReply) {
            return direct
        }

        let toolSchemaTokenList = LoopTool.schemaTokenList
        let toolCatalogText = LoopTool.catalogPromptText

        stats.invalidDecisionCount += 1
        appendTrace(&trace, "第\(step)轮：决策 JSON 解析失败，尝试自动修复。")

        let repairPrompt = """
你上一条输出不是合法 JSON。请修复为一个严格符合以下 schema 的 JSON，并且只输出 JSON：
{
  "type": "tool|plan|clarification",
  "tool": "\(toolSchemaTokenList)",
  "query": "字符串，可选（search_* 推荐填写关键词；全量查询可留空）",
  "target": "字符串，可选（get_* 必填）",
  "entity": "item|location|event|member，可选",
  "limit": 1-50 的整数，可选，默认 5,
  "clarification": "当 type=clarification 时必填"
}

工具目录（单一注册表）：
\(toolCatalogText)

原始输出：
\(rawReply)
"""

        guard let repairedReply = try? await AIChatService.complete(
            prompt: repairPrompt,
            settings: settings,
            maxTokens: 240,
            systemPrompt: HousekeeperPromptGuide.dispatcherPlaybook
        ),
        let repairedDecision = try? decodeDecision(from: repairedReply) else {
            appendTrace(&trace, "第\(step)轮：决策修复失败，跳过本轮并继续。")
            return nil
        }

        stats.repairedDecisionCount += 1
        appendTrace(&trace, "第\(step)轮：决策修复成功。")
        return repairedDecision
    }

    private static func decodeDecision(from raw: String) throws -> LoopDecision {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let direct = decodeDecisionJSON(cleaned) {
            return direct
        }

        for snippet in extractFencedJSONSnippets(from: cleaned) {
            if let decoded = decodeDecisionJSON(snippet) {
                return decoded
            }
        }

        if let block = extractFirstJSONObject(from: cleaned),
           let decoded = decodeDecisionJSON(block) {
            return decoded
        }

        throw plannerError("Agent 决策不是有效 JSON。")
    }

    private static func decodeDecisionJSON(_ text: String) -> LoopDecision? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LoopDecision.self, from: data)
    }

    private static func extractFencedJSONSnippets(from text: String) -> [String] {
        let patterns = [
            #"(?s)```json\s*(\{.*?\})\s*```"#,
            #"(?s)```\s*(\{.*?\})\s*```"#
        ]

        var snippets: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      match.numberOfRanges > 1,
                      let snippetRange = Range(match.range(at: 1), in: text) else {
                    return
                }
                snippets.append(String(text[snippetRange]))
            }
            if !snippets.isEmpty {
                return snippets
            }
        }

        return snippets
    }

    private static func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    private static func encodeJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func clampSearchLimit(_ limit: Int?) -> Int {
        max(1, min(limit ?? defaultSearchLimit, maxSearchLimit))
    }

    private static func effectiveSearchLimit(baseLimit: Int, prefersBroadResult: Bool) -> Int {
        guard prefersBroadResult else { return baseLimit }
        return min(max(baseLimit, broadSearchLimit), maxSearchLimit)
    }

    private static func parseItemSearchProfile(_ query: String) -> SearchQueryProfile {
        let normalized = query.normalizedToken
        let ownsOnlyByKeyword = containsAny(
            normalized,
            tokens: ["我的", "我负责", "我负责的", "由我负责", "归我", "属于我", "本人", "我名下", "我管理"]
        )
        let ownsOnlyByQuestion = normalized.contains("我")
            && containsAny(normalized, tokens: questionLikeTokens + broadQueryTokens + ["我有", "我现在有"])
        let hasPrivateSignal = containsAny(
            normalized,
            tokens: ["私有", "私人", "个人", "private", "personal"]
        )
        let hasPublicSignal = containsAny(
            normalized,
            tokens: ["公共", "公用", "公开", "共享", "public", "common"]
        )
        let featureFilter: ItemFeature? = {
            if hasPrivateSignal == hasPublicSignal {
                return nil
            }
            return hasPrivateSignal ? .private : .public
        }()

        let terms = normalizedQueryTerms(
            query,
            noiseTokens: commonNoiseTokens + itemEntityStopwords
        )
        let combined = terms.joined()
        let requestsAll = terms.isEmpty || containsAny(normalized, tokens: broadQueryTokens + questionLikeTokens)

        return SearchQueryProfile(
            combinedToken: combined,
            terms: terms,
            requestsAll: requestsAll,
            ownOnly: ownsOnlyByKeyword || ownsOnlyByQuestion,
            featureFilter: featureFilter
        )
    }

    private static func parseGenericSearchProfile(query: String, entityStopwords: [String]) -> SearchQueryProfile {
        let normalized = query.normalizedToken
        let terms = normalizedQueryTerms(
            query,
            noiseTokens: commonNoiseTokens + entityStopwords
        )
        let combined = terms.joined()
        let requestsAll = terms.isEmpty || containsAny(normalized, tokens: broadQueryTokens + questionLikeTokens)

        return SearchQueryProfile(
            combinedToken: combined,
            terms: terms,
            requestsAll: requestsAll,
            ownOnly: false,
            featureFilter: nil
        )
    }

    private static func buildReadOnlyPlanIfNeeded(
        instruction: String,
        currentMemberName: String?,
        currentMemberUsername: String?,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member]
    ) -> AgentPlan? {
        let normalized = instruction.normalizedToken
        guard isReadOnlyQueryIntent(normalizedInstruction: normalized),
              let entity = inferReadOnlyEntity(normalizedInstruction: normalized) else {
            return nil
        }

        switch entity {
        case .item:
            let results = searchItems(
                query: instruction,
                items: items,
                limit: maxSearchLimit,
                currentMemberName: currentMemberName,
                currentMemberUsername: currentMemberUsername
            )
            return AgentPlan(operations: [], clarification: formatItemReadResult(results))
        case .location:
            let results = searchLocations(query: instruction, locations: locations, limit: maxSearchLimit)
            return AgentPlan(operations: [], clarification: formatLocationReadResult(results))
        case .event:
            let results = searchEvents(query: instruction, events: events, limit: maxSearchLimit)
            return AgentPlan(operations: [], clarification: formatEventReadResult(results))
        case .member:
            let results = searchMembers(query: instruction, members: members, limit: maxSearchLimit)
            return AgentPlan(operations: [], clarification: formatMemberReadResult(results))
        }
    }

    private static func isReadOnlyQueryIntent(normalizedInstruction: String) -> Bool {
        let hasReadIntent = containsAny(
            normalizedInstruction,
            tokens: questionLikeTokens + ["查询", "查看", "列出", "清单", "列表", "检索"]
        )
        let hasWriteIntent = containsAny(
            normalizedInstruction,
            tokens: ["新增", "添加", "创建", "新建", "修改", "更新", "删除", "移除", "清空", "设为", "改成", "加上", "安排"]
        )
        return hasReadIntent && !hasWriteIntent
    }

    private static func inferReadOnlyEntity(normalizedInstruction: String) -> ReadOnlyEntity? {
        if containsAny(normalizedInstruction, tokens: ["物品", "东西", "设备", "资产", "道具"]) {
            return .item
        }
        if containsAny(normalizedInstruction, tokens: ["空间", "位置", "地点", "场所", "区域", "房间"]) {
            return .location
        }
        if containsAny(normalizedInstruction, tokens: ["事项", "活动", "任务", "日程", "安排", "事件"]) {
            return .event
        }
        if containsAny(normalizedInstruction, tokens: ["成员", "人员", "用户", "同事", "账号"]) {
            return .member
        }
        return nil
    }

    private static func formatItemReadResult(_ results: [ItemDigest]) -> String {
        guard !results.isEmpty else {
            return "查询结果：当前没有匹配的物品。"
        }
        let displayLimit = 12
        let lines = results.prefix(displayLimit).enumerated().map { index, item in
            "\(index + 1). \(item.name)（\(item.feature) / \(item.status)）"
        }
        let tail = results.count > displayLimit ? "\n…其余 \(results.count - displayLimit) 条未展示" : ""
        return "查询结果：共 \(results.count) 条物品。\n" + lines.joined(separator: "\n") + tail
    }

    private static func formatLocationReadResult(_ results: [LocationDigest]) -> String {
        guard !results.isEmpty else {
            return "查询结果：当前没有匹配的空间。"
        }
        let displayLimit = 12
        let lines = results.prefix(displayLimit).enumerated().map { index, location in
            let visibility = location.isPublic ? "公共" : "私有"
            return "\(index + 1). \(location.name)（\(visibility) / \(location.status)）"
        }
        let tail = results.count > displayLimit ? "\n…其余 \(results.count - displayLimit) 条未展示" : ""
        return "查询结果：共 \(results.count) 条空间。\n" + lines.joined(separator: "\n") + tail
    }

    private static func formatEventReadResult(_ results: [EventDigest]) -> String {
        guard !results.isEmpty else {
            return "查询结果：当前没有匹配的事项。"
        }
        let displayLimit = 12
        let lines = results.prefix(displayLimit).enumerated().map { index, event in
            let owner = event.ownerName ?? "未指定负责人"
            return "\(index + 1). \(event.title)（\(event.visibility) / \(owner)）"
        }
        let tail = results.count > displayLimit ? "\n…其余 \(results.count - displayLimit) 条未展示" : ""
        return "查询结果：共 \(results.count) 条事项。\n" + lines.joined(separator: "\n") + tail
    }

    private static func formatMemberReadResult(_ results: [MemberDigest]) -> String {
        guard !results.isEmpty else {
            return "查询结果：当前没有匹配的成员。"
        }
        let displayLimit = 12
        let lines = results.prefix(displayLimit).enumerated().map { index, member in
            "\(index + 1). \(member.name)（@\(member.username)）"
        }
        let tail = results.count > displayLimit ? "\n…其余 \(results.count - displayLimit) 条未展示" : ""
        return "查询结果：共 \(results.count) 条成员。\n" + lines.joined(separator: "\n") + tail
    }

    private static func normalizedQueryTerms(_ query: String, noiseTokens: [String]) -> [String] {
        var folded = query.folded()
        folded = folded.replacingOccurrences(
            of: #"[，。！？、；：,.!?;:/\\|]+"#,
            with: " ",
            options: .regularExpression
        )

        for token in noiseTokens.sorted(by: { $0.count > $1.count }) {
            let normalized = token.folded()
            guard !normalized.isEmpty else { continue }
            folded = folded.replacingOccurrences(of: normalized, with: " ")
        }

        let parts = folded
            .split(whereSeparator: { $0.isWhitespace })
            .map { part in
                String(part).replacingOccurrences(
                    of: #"[^a-z0-9一-龥]+"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .filter { !$0.isEmpty }

        var unique: [String] = []
        var seen = Set<String>()
        for part in parts {
            if seen.insert(part).inserted {
                unique.append(part)
            }
        }
        return unique
    }

    private static func relevanceScore(candidate: String, fullToken: String, terms: [String]) -> Int {
        if fullToken.isEmpty && terms.isEmpty {
            return 0
        }

        if !fullToken.isEmpty {
            if candidate == fullToken {
                return 120
            }
            if candidate.contains(fullToken) {
                return 90
            }
        }

        let hitCount = terms.filter { candidate.contains($0) }.count
        if hitCount == terms.count, hitCount > 0 {
            return 70 + hitCount
        }
        if hitCount > 0 {
            return 40 + hitCount
        }
        return -1
    }

    private static func matchesCurrentMember(
        item: LabItem,
        currentMemberName: String?,
        currentMemberUsername: String?
    ) -> Bool {
        let nameToken = currentMemberName?.normalizedToken ?? ""
        let usernameToken = currentMemberUsername?.normalizedToken ?? ""
        if nameToken.isEmpty && usernameToken.isEmpty {
            return true
        }
        return item.responsibleMembers.contains { member in
            memberMatchesCurrent(
                member: member,
                currentMemberName: currentMemberName,
                currentMemberUsername: currentMemberUsername
            )
        }
    }

    private static func memberMatchesCurrent(
        member: Member,
        currentMemberName: String?,
        currentMemberUsername: String?
    ) -> Bool {
        let nameToken = currentMemberName?.normalizedToken ?? ""
        let usernameToken = currentMemberUsername?.normalizedToken ?? ""
        let memberName = member.displayName.normalizedToken
        let memberUsername = member.username.normalizedToken

        if !usernameToken.isEmpty {
            if memberUsername == usernameToken
                || memberUsername.contains(usernameToken)
                || usernameToken.contains(memberUsername) {
                return true
            }
        }

        if !nameToken.isEmpty {
            if memberName == nameToken
                || memberName.contains(nameToken)
                || nameToken.contains(memberName) {
                return true
            }
        }

        return false
    }

    private static func shouldFastTrackCreatePlanning(for instruction: String) -> Bool {
        let normalized = instruction.normalizedToken
        let hasCreateIntent = containsAny(
            normalized,
            tokens: ["新增", "添加", "创建", "新建", "安排", "有个", "建立", "录入", "加上", "创建一个", "新增一个"]
        )
        let hasUpdateOrDeleteIntent = containsAny(
            normalized,
            tokens: ["修改", "更新", "删除", "移除", "清空", "移到", "调整", "改成"]
        )
        return hasCreateIntent && !hasUpdateOrDeleteIntent
    }

    private static func containsAny(_ text: String, tokens: [String]) -> Bool {
        tokens.contains { token in
            let normalized = token.normalizedToken
            guard !normalized.isEmpty else { return false }
            return text.contains(normalized)
        }
    }

    private static let broadQueryTokens: [String] = [
        "__all__", "*", "all", "everything", "所有", "全部", "全体", "全都", "一切"
    ]

    private static let questionLikeTokens: [String] = [
        "有什么", "有哪些", "什么", "哪些", "多少", "列表", "清单", "list"
    ]

    private static let commonNoiseTokens: [String] = [
        "请", "帮我", "麻烦", "一下", "现在", "目前", "当前",
        "查看", "查询", "搜索", "列出", "给我"
    ]

    private static let itemEntityStopwords: [String] = [
        "物品", "东西", "设备", "资产", "道具",
        "我",
        "我的", "我负责", "我负责的", "由我负责", "归我", "属于我",
        "私有", "私人", "个人", "公共", "公用", "公开", "共享",
        "item", "items"
    ]

    private static func plannerError(_ message: String) -> NSError {
        NSError(
            domain: "HousekeeperAgentLoopService",
            code: 4201,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func appendTrace(_ trace: inout [String], _ line: String) {
        let sanitized = sanitizeTraceLine(line)
        guard !sanitized.isEmpty else { return }
        guard trace.count < maxTraceLines else {
            if trace.last != "…(agentTrace 已截断)" {
                trace[trace.count - 1] = "…(agentTrace 已截断)"
            }
            return
        }
        trace.append(sanitized)
    }

    private static func sanitizeTraceLine(_ raw: String) -> String {
        var line = raw.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<email>",
            options: .regularExpression
        )
        line = line.replacingOccurrences(
            of: #"\b[A-Za-z0-9_\-]{28,}\b"#,
            with: "<token>",
            options: .regularExpression
        )
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty else { return "" }
        if line.count <= maxTraceLineCharacters {
            return line
        }
        return String(line.prefix(maxTraceLineCharacters)) + "..."
    }

    private static func checkDecisionDecodeDirectJSON() -> HousekeeperLoopSelfCheckEntry {
        let payload = #"{"type":"tool","tool":"search_items","query":"示波器","limit":3}"#
        do {
            let decoded = try decodeDecision(from: payload)
            let passed = decoded.type == .tool
                && decoded.tool == LoopTool.searchItems.rawValue
                && decoded.query == "示波器"
                && decoded.limit == 3
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_direct_json",
                passed: passed,
                detail: passed ? "ok" : "字段解析结果与预期不一致。"
            )
        } catch {
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_direct_json",
                passed: false,
                detail: "解析失败：\(error.localizedDescription)"
            )
        }
    }

    private static func checkDecisionDecodeFencedJSON() -> HousekeeperLoopSelfCheckEntry {
        let payload = """
```json
{"type":"plan"}
```
"""
        do {
            let decoded = try decodeDecision(from: payload)
            let passed = decoded.type == .plan
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_fenced_json",
                passed: passed,
                detail: passed ? "ok" : "fenced JSON 未被正确提取。"
            )
        } catch {
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_fenced_json",
                passed: false,
                detail: "解析失败：\(error.localizedDescription)"
            )
        }
    }

    private static func checkDecisionDecodeEmbeddedJSONBlock() -> HousekeeperLoopSelfCheckEntry {
        let payload = """
输出如下：
{
  "type": "clarification",
  "clarification": "请补充目标名称"
}
谢谢。
"""
        do {
            let decoded = try decodeDecision(from: payload)
            let passed = decoded.type == .clarification
                && decoded.clarification == "请补充目标名称"
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_embedded_block",
                passed: passed,
                detail: passed ? "ok" : "嵌入 JSON 块提取结果不正确。"
            )
        } catch {
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_embedded_block",
                passed: false,
                detail: "解析失败：\(error.localizedDescription)"
            )
        }
    }

    private static func checkDecisionDecodeRejectsInvalidPayload() -> HousekeeperLoopSelfCheckEntry {
        let invalidPayload = #"{"type":"unknown","tool":"search_items"}"#
        do {
            _ = try decodeDecision(from: invalidPayload)
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_reject_invalid",
                passed: false,
                detail: "非法 payload 被错误接受。"
            )
        } catch {
            return HousekeeperLoopSelfCheckEntry(
                name: "decision_decode_reject_invalid",
                passed: true,
                detail: "ok"
            )
        }
    }

    private static func checkLoopGuardRepeatedToolBlocking() -> HousekeeperLoopSelfCheckEntry {
        let decisions = [
            LoopDecision(type: .tool, tool: LoopTool.searchItems.rawValue, query: "示波器", target: nil, entity: .none, limit: 5, clarification: nil),
            LoopDecision(type: .tool, tool: LoopTool.searchItems.rawValue, query: "示波器", target: nil, entity: .none, limit: 5, clarification: nil),
            LoopDecision(type: .tool, tool: LoopTool.searchItems.rawValue, query: "示波器", target: nil, entity: .none, limit: 5, clarification: nil)
        ]
        let outcome = simulateLoopGuards(
            instruction: "查询示波器信息",
            decisions: decisions,
            maxSteps: 6
        )

        let passed = outcome.repeatedToolBlocked
            && !outcome.usedFallbackPlan
            && outcome.rounds == 3
        return HousekeeperLoopSelfCheckEntry(
            name: "loop_guard_repeated_tool_blocking",
            passed: passed,
            detail: passed
                ? "ok"
                : "expected repeated block at round=3, got blocked=\(outcome.repeatedToolBlocked), fallback=\(outcome.usedFallbackPlan), rounds=\(outcome.rounds)"
        )
    }

    private static func checkLoopGuardMaxRoundsFallback() -> HousekeeperLoopSelfCheckEntry {
        let decisions = [
            LoopDecision(type: .tool, tool: LoopTool.searchItems.rawValue, query: "A", target: nil, entity: .none, limit: 5, clarification: nil),
            LoopDecision(type: .tool, tool: LoopTool.searchLocations.rawValue, query: "A", target: nil, entity: .none, limit: 5, clarification: nil)
        ]
        let outcome = simulateLoopGuards(
            instruction: "查询相关信息",
            decisions: decisions,
            maxSteps: 2
        )

        let passed = !outcome.repeatedToolBlocked
            && outcome.usedFallbackPlan
            && outcome.rounds == 2
        return HousekeeperLoopSelfCheckEntry(
            name: "loop_guard_max_rounds_fallback",
            passed: passed,
            detail: passed
                ? "ok"
                : "expected fallback at round=2, got blocked=\(outcome.repeatedToolBlocked), fallback=\(outcome.usedFallbackPlan), rounds=\(outcome.rounds)"
        )
    }

    private static func checkLoopToolRegistryConsistency() -> HousekeeperLoopSelfCheckEntry {
        let schemaTokens = LoopTool.schemaTokenList
            .split(separator: "|")
            .map(String.init)
        let schemaSet = Set(schemaTokens)
        let caseSet = Set(LoopTool.allCases.map(\.rawValue))

        let hasDuplicateSchemaToken = schemaTokens.count != schemaSet.count
        let missingInSchema = caseSet.subtracting(schemaSet)
        let extraInSchema = schemaSet.subtracting(caseSet)
        let invalidToolMeta = LoopTool.allCases.filter { tool in
            let expectedIsSearch = tool.rawValue.hasPrefix("search_")
            let expectedRequiresTarget = tool.rawValue.hasPrefix("get_")
            let hasDescription = tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return tool.isSearchTool != expectedIsSearch
                || tool.requiresTarget != expectedRequiresTarget
                || !hasDescription
        }

        let passed = !hasDuplicateSchemaToken
            && missingInSchema.isEmpty
            && extraInSchema.isEmpty
            && invalidToolMeta.isEmpty

        var detailParts: [String] = []
        if hasDuplicateSchemaToken {
            detailParts.append("schema 中存在重复 tool token")
        }
        if !missingInSchema.isEmpty {
            detailParts.append("schema 缺少：\(missingInSchema.sorted().joined(separator: ","))")
        }
        if !extraInSchema.isEmpty {
            detailParts.append("schema 多余：\(extraInSchema.sorted().joined(separator: ","))")
        }
        if !invalidToolMeta.isEmpty {
            detailParts.append("tool 元信息不一致：\(invalidToolMeta.map(\.rawValue).joined(separator: ","))")
        }

        return HousekeeperLoopSelfCheckEntry(
            name: "loop_tool_registry_consistency",
            passed: passed,
            detail: passed ? "ok" : detailParts.joined(separator: "；")
        )
    }

    private static func simulateLoopGuards(
        instruction: String,
        decisions: [LoopDecision],
        maxSteps: Int
    ) -> LoopGuardSimulationOutcome {
        let boundedSteps = max(1, maxSteps)
        var repeatedCallCounter: [String: Int] = [:]

        for step in 1...boundedSteps {
            guard step <= decisions.count else {
                continue
            }

            let decision = decisions[step - 1]
            switch decision.type {
            case .plan, .clarification:
                return LoopGuardSimulationOutcome(
                    repeatedToolBlocked: false,
                    usedFallbackPlan: false,
                    rounds: step
                )
            case .tool:
                guard let toolName = decision.tool?.trimmedNonEmpty,
                      let tool = LoopTool(rawValue: toolName) else {
                    continue
                }
                if validateToolDecision(tool: tool, decision: decision) != nil {
                    continue
                }

                let signature = toolSignature(
                    name: tool.rawValue,
                    query: decision.query,
                    target: decision.target,
                    entity: decision.entity,
                    limit: decision.limit
                )
                let callCount = repeatedCallCounter[signature, default: 0] + 1
                repeatedCallCounter[signature] = callCount

                if callCount > maxSameToolCall {
                    if tool.isSearchTool && shouldFastTrackCreatePlanning(for: instruction) {
                        return LoopGuardSimulationOutcome(
                            repeatedToolBlocked: false,
                            usedFallbackPlan: false,
                            rounds: step
                        )
                    }
                    return LoopGuardSimulationOutcome(
                        repeatedToolBlocked: true,
                        usedFallbackPlan: false,
                        rounds: step
                    )
                }
            }
        }

        return LoopGuardSimulationOutcome(
            repeatedToolBlocked: false,
            usedFallbackPlan: true,
            rounds: boundedSteps
        )
    }
}

private struct LoopDecision: Codable {
    enum DecisionType: String, Codable {
        case tool
        case plan
        case clarification
    }

    var type: DecisionType
    var tool: String?
    var query: String?
    var target: String?
    var entity: String?
    var limit: Int?
    var clarification: String?
}

private struct ItemDigest: Codable {
    var id: String
    var name: String
    var status: String
    var feature: String
    var responsibleMembers: [String]
    var locations: [String]
}

private struct LocationDigest: Codable {
    var id: String
    var name: String
    var status: String
    var isPublic: Bool
    var parentName: String?
    var responsibleMembers: [String]
}

private struct EventDigest: Codable {
    var id: String
    var title: String
    var ownerName: String?
    var visibility: String
    var startTimeISO: String?
    var endTimeISO: String?
}

private struct MemberDigest: Codable {
    var id: String
    var name: String
    var username: String
    var contact: String
}

private struct ToolExecutionOutcome {
    var observation: String
    var brief: String
    var resultCount: Int

    var isEmptyResult: Bool {
        resultCount == 0
    }
}

private struct LoopGuardSimulationOutcome {
    var repeatedToolBlocked: Bool
    var usedFallbackPlan: Bool
    var rounds: Int
}

private struct SearchQueryProfile {
    var combinedToken: String
    var terms: [String]
    var requestsAll: Bool
    var ownOnly: Bool
    var featureFilter: ItemFeature?

    var prefersBroadResult: Bool {
        requestsAll || (combinedToken.isEmpty && terms.isEmpty)
    }
}

private enum ReadOnlyEntity {
    case item
    case location
    case event
    case member
}

private enum FinalizationMode {
    case planning
    case repair(previousPlan: AgentPlan, failedEntries: [AgentExecutionEntry])
}

private enum LoopTool: String, CaseIterable {
    case searchItems = "search_items"
    case searchLocations = "search_locations"
    case searchEvents = "search_events"
    case searchMembers = "search_members"
    case getItem = "get_item"
    case getLocation = "get_location"
    case getEvent = "get_event"
    case getMember = "get_member"

    static var schemaTokenList: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }

    static var catalogPromptText: String {
        allCases.map { "- \($0.rawValue): \($0.description)" }.joined(separator: "\n")
    }

    var isSearchTool: Bool {
        switch self {
        case .searchItems, .searchLocations, .searchEvents, .searchMembers:
            return true
        case .getItem, .getLocation, .getEvent, .getMember:
            return false
        }
    }

    var requiresTarget: Bool {
        !isSearchTool
    }

    var description: String {
        switch self {
        case .searchItems:
            return "按关键词检索物品列表"
        case .searchLocations:
            return "按关键词检索空间列表"
        case .searchEvents:
            return "按关键词检索事项列表"
        case .searchMembers:
            return "按关键词检索成员列表"
        case .getItem:
            return "按 id 或名称精确获取单个物品"
        case .getLocation:
            return "按 id 或名称精确获取单个空间"
        case .getEvent:
            return "按 id 或标题精确获取单个事项"
        case .getMember:
            return "按 id、用户名或姓名精确获取单个成员"
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNonEmpty: String? {
        let token = trimmed
        return token.isEmpty ? nil : token
    }

    var normalizedToken: String {
        folded()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    func folded() -> String {
        folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }
}

private extension Date {
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }
}
