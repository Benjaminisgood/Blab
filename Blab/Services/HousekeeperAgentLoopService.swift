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

enum HousekeeperAgentLoopService {
    private static let maxSameToolCall = 2
    private static let maxTraceLines = 40
    private static let maxTraceLineCharacters = 260
    private static let maxObservationCount = 12

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

            let rawReply = try await AIChatService.complete(prompt: loopPrompt, settings: settings, maxTokens: 700)
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

                if let validationError = validateToolDecision(toolName: toolName, decision: decision) {
                    stats.invalidDecisionCount += 1
                    let reason = "tool_validation_error(tool=\(toolName)): \(validationError)"
                    observations.append(reason)
                    appendTrace(&trace, "第\(step)轮：\(reason)")
                    continue
                }

                let signature = toolSignature(
                    name: toolName,
                    query: decision.query,
                    target: decision.target,
                    entity: decision.entity,
                    limit: decision.limit
                )
                let callCount = repeatedCallCounter[signature, default: 0] + 1
                repeatedCallCounter[signature] = callCount

                if callCount > maxSameToolCall {
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
                    name: toolName,
                    query: decision.query,
                    target: decision.target,
                    entity: decision.entity,
                    limit: decision.limit,
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
  "tool": "search_items|search_locations|search_events|search_members|get_item|get_location|get_event|get_member",
  "query": "字符串，可选（search_* 必填）",
  "target": "字符串，可选（get_* 必填）",
  "entity": "item|location|event|member，可选",
  "limit": 1-10 的整数，可选，默认 5,
  "clarification": "当 type=clarification 时必填"
}

决策规则：
- 如果目标对象不明确或可能重名，优先 tool。
- 如果已有信息足够生成可执行计划，输出 type=plan。
- 如果多次检索仍不足，输出 type=clarification。
- 如果上一轮给出参数错误或检索为空，优先改用其它工具/参数继续尝试。
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
        name: String,
        query: String?,
        target: String?,
        entity: String?,
        limit: Int?,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member]
    ) -> ToolExecutionOutcome {
        let safeLimit = max(1, min(limit ?? 5, 10))

        switch name {
        case "search_items":
            let q = query?.trimmedNonEmpty ?? ""
            let results = searchItems(query: q, items: items, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_items(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_items resultCount=\(results.count)",
                resultCount: results.count
            )

        case "search_locations":
            let q = query?.trimmedNonEmpty ?? ""
            let results = searchLocations(query: q, locations: locations, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_locations(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_locations resultCount=\(results.count)",
                resultCount: results.count
            )

        case "search_events":
            let q = query?.trimmedNonEmpty ?? ""
            let results = searchEvents(query: q, events: events, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_events(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_events resultCount=\(results.count)",
                resultCount: results.count
            )

        case "search_members":
            let q = query?.trimmedNonEmpty ?? ""
            let results = searchMembers(query: q, members: members, limit: safeLimit)
            return ToolExecutionOutcome(
                observation: "search_members(query=\(q), limit=\(safeLimit)) => \(encodeJSONString(results))",
                brief: "tool=search_members resultCount=\(results.count)",
                resultCount: results.count
            )

        case "get_item":
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getItem(token: token, items: items)
            return ToolExecutionOutcome(
                observation: "get_item(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_item found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        case "get_location":
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getLocation(token: token, locations: locations)
            return ToolExecutionOutcome(
                observation: "get_location(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_location found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        case "get_event":
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getEvent(token: token, events: events)
            return ToolExecutionOutcome(
                observation: "get_event(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_event found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        case "get_member":
            let token = target?.trimmedNonEmpty ?? query?.trimmedNonEmpty ?? ""
            let result = getMember(token: token, members: members)
            return ToolExecutionOutcome(
                observation: "get_member(target=\(token)) => \(encodeJSONString(result))",
                brief: "tool=get_member found=\(result == nil ? 0 : 1)",
                resultCount: result == nil ? 0 : 1
            )

        default:
            let fallbackEntity = entity ?? "unknown"
            return ToolExecutionOutcome(
                observation: "unsupported_tool(name=\(name), entity=\(fallbackEntity)) => []",
                brief: "tool=\(name) unsupported",
                resultCount: 0
            )
        }
    }

    private static func searchItems(query: String, items: [LabItem], limit: Int) -> [ItemDigest] {
        let token = query.normalizedToken
        let ranked = items.map { item -> (Int, LabItem) in
            let name = item.name.normalizedToken
            if token.isEmpty { return (0, item) }
            if name == token { return (100, item) }
            if name.contains(token) { return (70, item) }
            return (-1, item)
        }
        .filter { token.isEmpty || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(limit)

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
        let token = query.normalizedToken
        let ranked = locations.map { location -> (Int, LabLocation) in
            let name = location.name.normalizedToken
            if token.isEmpty { return (0, location) }
            if name == token { return (100, location) }
            if name.contains(token) { return (70, location) }
            return (-1, location)
        }
        .filter { token.isEmpty || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(limit)

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
        let token = query.normalizedToken
        let ranked = events.map { event -> (Int, LabEvent) in
            let title = event.title.normalizedToken
            if token.isEmpty { return (0, event) }
            if title == token { return (100, event) }
            if title.contains(token) { return (70, event) }
            return (-1, event)
        }
        .filter { token.isEmpty || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(limit)

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
        let token = query.normalizedToken
        let ranked = members.map { member -> (Int, Member) in
            let displayName = member.displayName.normalizedToken
            let username = member.username.normalizedToken
            if token.isEmpty { return (0, member) }
            if displayName == token || username == token { return (100, member) }
            if displayName.contains(token) || username.contains(token) { return (70, member) }
            return (-1, member)
        }
        .filter { token.isEmpty || $0.0 >= 0 }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.displayName.localizedCaseInsensitiveCompare(rhs.1.displayName) == .orderedAscending
            }
            return lhs.0 > rhs.0
        }
        .prefix(limit)

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

    private static func validateToolDecision(toolName: String, decision: LoopDecision) -> String? {
        switch toolName {
        case "search_items", "search_locations", "search_events", "search_members":
            guard decision.query?.trimmedNonEmpty != nil else {
                return "\(toolName) 缺少 query。"
            }
            return nil
        case "get_item", "get_location", "get_event", "get_member":
            guard decision.target?.trimmedNonEmpty != nil || decision.query?.trimmedNonEmpty != nil else {
                return "\(toolName) 缺少 target（或 query 兜底）。"
            }
            return nil
        default:
            return nil
        }
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

        stats.invalidDecisionCount += 1
        appendTrace(&trace, "第\(step)轮：决策 JSON 解析失败，尝试自动修复。")

        let repairPrompt = """
你上一条输出不是合法 JSON。请修复为一个严格符合以下 schema 的 JSON，并且只输出 JSON：
{
  "type": "tool|plan|clarification",
  "tool": "search_items|search_locations|search_events|search_members|get_item|get_location|get_event|get_member",
  "query": "字符串，可选（search_* 必填）",
  "target": "字符串，可选（get_* 必填）",
  "entity": "item|location|event|member，可选",
  "limit": 1-10 的整数，可选，默认 5,
  "clarification": "当 type=clarification 时必填"
}

原始输出：
\(rawReply)
"""

        guard let repairedReply = try? await AIChatService.complete(
            prompt: repairPrompt,
            settings: settings,
            maxTokens: 240
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

private enum FinalizationMode {
    case planning
    case repair(previousPlan: AgentPlan, failedEntries: [AgentExecutionEntry])
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
