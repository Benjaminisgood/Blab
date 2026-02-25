import Foundation

struct AgentPlannerMemberContext: Codable {
    var name: String
    var username: String
}

struct AgentPlannerContext: Codable {
    var now: Date
    var currentMemberName: String?
    var itemNames: [String]
    var locationNames: [String]
    var eventTitles: [String]
    var members: [AgentPlannerMemberContext]
}

enum AgentAction: String, Codable {
    case create
    case update
    case delete
}

enum AgentEntity: String, Codable {
    case item
    case location
    case event
    case member
}

struct AgentTarget: Codable, Hashable {
    var id: String?
    var name: String?
    var username: String?
}

struct AgentDetailRef: Codable, Hashable {
    var label: String?
    var value: String
}

struct AgentItemFields: Codable, Hashable {
    var name: String?
    var category: String?
    var status: String?
    var feature: String?
    var value: Double?
    var quantityDesc: String?
    var purchaseDateISO: String?
    var notes: String?
    var purchaseLink: String?
    var responsibleMemberNames: [String]?
    var locationNames: [String]?
    var detailRefs: [AgentDetailRef]?
}

struct AgentLocationFields: Codable, Hashable {
    var name: String?
    var status: String?
    var isPublic: Bool?
    var latitude: Double?
    var longitude: Double?
    var coordinateSource: String?
    var notes: String?
    var detailLink: String?
    var responsibleMemberNames: [String]?
    var parentName: String?
    var usageTags: [String]?
    var detailRefs: [AgentDetailRef]?
}

struct AgentEventFields: Codable, Hashable {
    var title: String?
    var summaryText: String?
    var visibility: String?
    var startTimeISO: String?
    var endTimeISO: String?
    var detailLink: String?
    var allowParticipantEdit: Bool?
    var ownerName: String?
    var participantNames: [String]?
    var itemNames: [String]?
    var locationNames: [String]?
}

struct AgentMemberFields: Codable, Hashable {
    var name: String?
    var username: String?
    var contact: String?
    var password: String?
    var bio: String?
}

struct AgentOperation: Codable, Hashable, Identifiable {
    var id: String
    var action: AgentAction
    var entity: AgentEntity
    var target: AgentTarget?
    var item: AgentItemFields?
    var location: AgentLocationFields?
    var event: AgentEventFields?
    var member: AgentMemberFields?
    var note: String?

    init(
        id: String = UUID().uuidString,
        action: AgentAction,
        entity: AgentEntity,
        target: AgentTarget? = nil,
        item: AgentItemFields? = nil,
        location: AgentLocationFields? = nil,
        event: AgentEventFields? = nil,
        member: AgentMemberFields? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.action = action
        self.entity = entity
        self.target = target
        self.item = item
        self.location = location
        self.event = event
        self.member = member
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case entity
        case target
        case item
        case location
        case event
        case member
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
        id = decodedID?.trimmedNonEmpty ?? UUID().uuidString
        action = try container.decode(AgentAction.self, forKey: .action)
        entity = try container.decode(AgentEntity.self, forKey: .entity)
        target = try container.decodeIfPresent(AgentTarget.self, forKey: .target)
        item = try container.decodeIfPresent(AgentItemFields.self, forKey: .item)
        location = try container.decodeIfPresent(AgentLocationFields.self, forKey: .location)
        event = try container.decodeIfPresent(AgentEventFields.self, forKey: .event)
        member = try container.decodeIfPresent(AgentMemberFields.self, forKey: .member)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    var previewText: String {
        switch entity {
        case .item:
            return "\(actionDisplayText)物品：\(item?.name?.trimmedNonEmpty ?? target?.name?.trimmedNonEmpty ?? target?.id?.trimmedNonEmpty ?? "未指定目标")"
        case .location:
            return "\(actionDisplayText)空间：\(location?.name?.trimmedNonEmpty ?? target?.name?.trimmedNonEmpty ?? target?.id?.trimmedNonEmpty ?? "未指定目标")"
        case .event:
            return "\(actionDisplayText)事项：\(event?.title?.trimmedNonEmpty ?? target?.name?.trimmedNonEmpty ?? target?.id?.trimmedNonEmpty ?? "未指定目标")"
        case .member:
            let memberLabel = member?.name?.trimmedNonEmpty
                ?? member?.username?.trimmedNonEmpty
                ?? target?.username?.trimmedNonEmpty
                ?? target?.name?.trimmedNonEmpty
                ?? target?.id?.trimmedNonEmpty
                ?? "未指定目标"
            return "\(actionDisplayText)成员：\(memberLabel)"
        }
    }

    var actionDisplayText: String {
        switch action {
        case .create:
            return "新增"
        case .update:
            return "修改"
        case .delete:
            return "删除"
        }
    }

    var entityDisplayText: String {
        switch entity {
        case .item:
            return "物品"
        case .location:
            return "空间"
        case .event:
            return "事项"
        case .member:
            return "成员"
        }
    }

    var targetPreviewText: String? {
        guard action != .create else { return nil }

        var fragments: [String] = []
        if let id = target?.id?.trimmedNonEmpty {
            fragments.append("id=\(id)")
        }
        if let name = target?.name?.trimmedNonEmpty {
            fragments.append("name=\(name)")
        }
        if let username = target?.username?.trimmedNonEmpty {
            fragments.append("username=\(username)")
        }

        if fragments.isEmpty {
            switch entity {
            case .item:
                if let name = item?.name?.trimmedNonEmpty { fragments.append("name=\(name)") }
            case .location:
                if let name = location?.name?.trimmedNonEmpty { fragments.append("name=\(name)") }
            case .event:
                if let title = event?.title?.trimmedNonEmpty { fragments.append("title=\(title)") }
            case .member:
                if let username = member?.username?.trimmedNonEmpty {
                    fragments.append("username=\(username)")
                } else if let name = member?.name?.trimmedNonEmpty {
                    fragments.append("name=\(name)")
                }
            }
        }

        guard !fragments.isEmpty else { return nil }
        return "匹配条件：\(fragments.joined(separator: "，"))"
    }

    var fieldPreviewLines: [String] {
        switch entity {
        case .item:
            return item?.fieldPreviewLines ?? []
        case .location:
            return location?.fieldPreviewLines ?? []
        case .event:
            return event?.fieldPreviewLines ?? []
        case .member:
            return member?.fieldPreviewLines ?? []
        }
    }
}

struct AgentPlan: Codable {
    var operations: [AgentOperation]
    var clarification: String?

    init(operations: [AgentOperation] = [], clarification: String? = nil) {
        self.operations = operations
        self.clarification = clarification
    }
}

extension AgentItemFields {
    var fieldPreviewLines: [String] {
        var lines: [String] = []
        lines.append(contentsOf: previewLine(key: "name", value: name))
        lines.append(contentsOf: previewLine(key: "category", value: category))
        lines.append(contentsOf: previewLine(key: "status", value: status))
        lines.append(contentsOf: previewLine(key: "feature", value: feature))
        lines.append(contentsOf: previewLine(key: "value", value: value))
        lines.append(contentsOf: previewLine(key: "quantityDesc", value: quantityDesc))
        lines.append(contentsOf: previewLine(key: "purchaseDateISO", value: purchaseDateISO))
        lines.append(contentsOf: previewLine(key: "notes", value: notes))
        lines.append(contentsOf: previewLine(key: "purchaseLink", value: purchaseLink))
        lines.append(contentsOf: previewLine(key: "responsibleMemberNames", values: responsibleMemberNames))
        lines.append(contentsOf: previewLine(key: "locationNames", values: locationNames))
        if let detailRefs {
            lines.append("detailRefs = \(detailRefs.count) 条")
        }
        return lines
    }
}

extension AgentLocationFields {
    var fieldPreviewLines: [String] {
        var lines: [String] = []
        lines.append(contentsOf: previewLine(key: "name", value: name))
        lines.append(contentsOf: previewLine(key: "status", value: status))
        lines.append(contentsOf: previewLine(key: "isPublic", value: isPublic))
        lines.append(contentsOf: previewLine(key: "latitude", value: latitude))
        lines.append(contentsOf: previewLine(key: "longitude", value: longitude))
        lines.append(contentsOf: previewLine(key: "coordinateSource", value: coordinateSource))
        lines.append(contentsOf: previewLine(key: "notes", value: notes))
        lines.append(contentsOf: previewLine(key: "detailLink", value: detailLink))
        lines.append(contentsOf: previewLine(key: "responsibleMemberNames", values: responsibleMemberNames))
        lines.append(contentsOf: previewLine(key: "parentName", value: parentName))
        lines.append(contentsOf: previewLine(key: "usageTags", values: usageTags))
        if let detailRefs {
            lines.append("detailRefs = \(detailRefs.count) 条")
        }
        return lines
    }
}

extension AgentEventFields {
    var fieldPreviewLines: [String] {
        var lines: [String] = []
        lines.append(contentsOf: previewLine(key: "title", value: title))
        lines.append(contentsOf: previewLine(key: "summaryText", value: summaryText))
        lines.append(contentsOf: previewLine(key: "visibility", value: visibility))
        lines.append(contentsOf: previewLine(key: "startTimeISO", value: startTimeISO))
        lines.append(contentsOf: previewLine(key: "endTimeISO", value: endTimeISO))
        lines.append(contentsOf: previewLine(key: "detailLink", value: detailLink))
        lines.append(contentsOf: previewLine(key: "allowParticipantEdit", value: allowParticipantEdit))
        lines.append(contentsOf: previewLine(key: "ownerName", value: ownerName))
        lines.append(contentsOf: previewLine(key: "participantNames", values: participantNames))
        lines.append(contentsOf: previewLine(key: "itemNames", values: itemNames))
        lines.append(contentsOf: previewLine(key: "locationNames", values: locationNames))
        return lines
    }
}

extension AgentMemberFields {
    var fieldPreviewLines: [String] {
        var lines: [String] = []
        lines.append(contentsOf: previewLine(key: "name", value: name))
        lines.append(contentsOf: previewLine(key: "username", value: username))
        lines.append(contentsOf: previewLine(key: "contact", value: contact))
        lines.append(contentsOf: previewLine(key: "password", value: password))
        lines.append(contentsOf: previewLine(key: "bio", value: bio))
        return lines
    }
}

private func previewLine(key: String, value: String?) -> [String] {
    guard let value else { return [] }
    return ["\(key) = \(value)"]
}

private func previewLine(key: String, value: Bool?) -> [String] {
    guard let value else { return [] }
    return ["\(key) = \(value ? "true" : "false")"]
}

private func previewLine(key: String, value: Double?) -> [String] {
    guard let value else { return [] }
    return ["\(key) = \(value)"]
}

private func previewLine(key: String, value: Int?) -> [String] {
    guard let value else { return [] }
    return ["\(key) = \(value)"]
}

private func previewLine(key: String, values: [String]?) -> [String] {
    guard let values else { return [] }
    return ["\(key) = [\(values.joined(separator: ", "))]"]
}

enum AgentPlannerService {
    static func plan(input: String, settings: AISettings, context: AgentPlannerContext) async throws -> AgentPlan {
        let cleanedInput = input.trimmedNonEmpty
        guard let cleanedInput else {
            throw plannerError("请输入要执行的自然语言指令。")
        }

        guard settings.autoFillEnabled else {
            throw plannerError("AI 自动填写未启用，请先在设置页开启后再使用。")
        }

        let prompt = buildPrompt(input: cleanedInput, context: context)
        let rawReply = try await AIChatService.complete(prompt: prompt, settings: settings, maxTokens: 1400)
        let plan = try decodePlan(from: rawReply)
        let normalized = normalizePlan(plan)
        let guarded = applyPlanGuard(normalized)

        if guarded.operations.isEmpty,
           guarded.clarification?.trimmedNonEmpty == nil {
            throw plannerError("AI 未生成可执行计划，请补充更具体的指令后重试。")
        }

        return guarded
    }

    static func repairPlan(
        originalInput: String,
        previousPlan: AgentPlan,
        failedEntries: [AgentExecutionEntry],
        settings: AISettings,
        context: AgentPlannerContext
    ) async throws -> AgentPlan {
        let cleanedInput = originalInput.trimmedNonEmpty
        guard let cleanedInput else {
            throw plannerError("原始输入为空，无法自动修复计划。")
        }
        guard !failedEntries.isEmpty else {
            throw plannerError("当前无失败项，无需自动修复。")
        }

        guard settings.autoFillEnabled else {
            throw plannerError("AI 自动填写未启用，无法自动修复。")
        }

        let prompt = buildRepairPrompt(
            originalInput: cleanedInput,
            previousPlan: previousPlan,
            failedEntries: failedEntries,
            context: context
        )
        let rawReply = try await AIChatService.complete(prompt: prompt, settings: settings, maxTokens: 1400)
        let repaired = try decodePlan(from: rawReply)
        let normalized = normalizePlan(repaired)
        let guarded = applyPlanGuard(normalized)

        if guarded.operations.isEmpty,
           guarded.clarification?.trimmedNonEmpty == nil {
            throw plannerError("自动修复未生成可执行计划。")
        }

        return guarded
    }

    private static func buildPrompt(input: String, context: AgentPlannerContext) -> String {
        let nowToken = ISO8601DateFormatter().string(from: context.now)
        let itemStatuses = ItemStockStatus.allCases.map(\.rawValue).joined(separator: "、")
        let itemFeatures = ItemFeature.allCases.map(\.rawValue).joined(separator: "、")
        let locationStatuses = LocationStatus.allCases.map(\.rawValue).joined(separator: "、")
        let locationUsageTags = LocationUsageTag.allCases.map(\.displayName).joined(separator: "、")
        let visibilityValues = EventVisibility.allCases.map(\.rawValue).joined(separator: "、")
        let contextJSON = contextJSONString(context)

        return """
你是 Blab 的数据录入 Agent，负责把用户自然语言转换为结构化执行计划。
当前时间：\(nowToken)

输出要求（必须遵守）：
1) 只输出一个 JSON 对象，不要 markdown，不要解释文本。
2) JSON 顶层结构：
{
  "operations": [
    {
      "id": "字符串，可选",
      "action": "create|update|delete",
      "entity": "item|location|event|member",
      "target": { "id": "可选", "name": "可选", "username": "可选" },
      "item": {...},
      "location": {...},
      "event": {...},
      "member": {...},
      "note": "可选"
    }
  ],
  "clarification": "如需向用户追问则写在这里；无需追问可为空字符串"
}
3) 每个 operation 只填写与 entity 对应的字段，其他对象省略。
4) update 必须给出可定位目标（target.id 或 target.name 或 target.username）。
   - delete 可给出可定位目标；若用户明确说“删除全部/所有/清空”，可使用 target.name="__ALL__"（或 "所有" / "全部" / "all" / "*"）。
5) create 必须给出基础名称字段：item.name / location.name / event.title / member.name。
   - member.username 可选，若缺失请自动生成可用的小写英文用户名（尽量基于姓名拼音）。
6) delete 优先仅填写 target；对应实体对象可省略。批量删除建议只保留 target.name="__ALL__"。
7) 枚举值请使用以下规范：
   - item.status：\(itemStatuses)
   - item.feature：\(itemFeatures)
   - location.status：\(locationStatuses)
   - location.usageTags：\(locationUsageTags)
   - event.visibility：\(visibilityValues)
8) 日期时间字段请用 ISO8601（例如 2026-02-22T15:00:00+08:00）。
   - 如用户说“今天/明天/后天/下周一”等相对时间，请先换算为绝对日期时间再输出。
9) 若用户描述不足以安全执行，operations 可以为空，并在 clarification 给出一句追问。

当前数据上下文（供匹配已有记录）：
\(contextJSON)

用户输入：
\(input)
"""
    }

    private static func buildRepairPrompt(
        originalInput: String,
        previousPlan: AgentPlan,
        failedEntries: [AgentExecutionEntry],
        context: AgentPlannerContext
    ) -> String {
        let previousPlanJSON = encodeJSONString(previousPlan)
        let failureSummary = failedEntries.map {
            RepairFailureDigest(
                operationID: $0.operationID,
                message: $0.message
            )
        }
        let failureJSON = encodeJSONString(failureSummary)
        let contextJSON = contextJSONString(context)

        return """
你是 Blab 的计划修复 Agent。请根据失败原因，重写“失败的操作”，不要重复已成功的操作。

输出要求（必须遵守）：
1) 只输出一个 JSON 对象：{ "operations": [...], "clarification": "..." }。
2) 每个 operation 必须满足实体字段一致性：
   - entity=item 仅用 item
   - entity=location 仅用 location
   - entity=event 仅用 event
   - entity=member 仅用 member
   - 若 action=delete，可仅提供 target 并省略对应实体对象。
3) create 必须提供基础名称字段；update 必须能定位目标。
   - delete 若为批量删除，可用 target.name="__ALL__"（或同义词“所有/全部/all/*”）。
4) 若信息仍不足，operations 置空，并在 clarification 明确指出缺什么。
5) 请优先修复 failedEntries 对应问题，不要重复已经成功的写入动作。

原始用户输入：
\(originalInput)

上一轮计划：
\(previousPlanJSON)

失败项：
\(failureJSON)

当前数据上下文：
\(contextJSON)
"""
    }

    private static func contextJSONString(_ context: AgentPlannerContext) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(context),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func encodeJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func decodePlan(from raw: String) throws -> AgentPlan {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let direct = decodePlanJSON(cleaned) {
            return direct
        }

        for snippet in extractFencedJSONSnippets(from: cleaned) {
            if let decoded = decodePlanJSON(snippet) {
                return decoded
            }
        }

        if let block = extractFirstJSONObject(from: cleaned),
           let decoded = decodePlanJSON(block) {
            return decoded
        }

        throw plannerError("AI 返回的计划不是有效 JSON。")
    }

    private static func decodePlanJSON(_ text: String) -> AgentPlan? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentPlan.self, from: data)
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

    private static func normalizePlan(_ plan: AgentPlan) -> AgentPlan {
        let normalizedOperations = plan.operations.map { op in
            var updated = op
            if updated.id.trimmedNonEmpty == nil {
                updated.id = UUID().uuidString
            }
            updated.note = updated.note?.trimmedNonEmpty
            updated = normalizeBulkDeleteTargetIfNeeded(updated)
            return updated
        }

        return AgentPlan(
            operations: normalizedOperations,
            clarification: plan.clarification?.trimmedNonEmpty
        )
    }

    private static func normalizeBulkDeleteTargetIfNeeded(_ operation: AgentOperation) -> AgentOperation {
        guard operation.action == .delete else { return operation }

        let payloadToken: String? = {
            switch operation.entity {
            case .item:
                return operation.item?.name
            case .location:
                return operation.location?.name
            case .event:
                return operation.event?.title
            case .member:
                return operation.member?.username ?? operation.member?.name
            }
        }()

        let shouldMarkAll = isBulkDeleteToken(operation.target?.name)
            || isBulkDeleteToken(payloadToken)
            || isBulkDeleteToken(operation.note)
        guard shouldMarkAll else { return operation }

        var updated = operation
        updated.target = AgentTarget(
            id: nil,
            name: "__ALL__",
            username: updated.target?.username
        )
        return updated
    }

    private static func applyPlanGuard(_ plan: AgentPlan) -> AgentPlan {
        let issues = validateOperations(plan.operations)
        guard !issues.isEmpty else { return plan }

        let issueLines = issues
            .enumerated()
            .map { index, issue in "\(index + 1). \(issue)" }
            .joined(separator: " ")
        let guardClarification = "系统校验发现计划不完整，暂不执行。\(issueLines) 请补充信息后重新生成计划。"
        let mergedClarification = mergeClarification(
            existing: plan.clarification?.trimmedNonEmpty,
            guardClarification: guardClarification
        )

        return AgentPlan(
            operations: plan.operations,
            clarification: mergedClarification
        )
    }

    private static func validateOperations(_ operations: [AgentOperation]) -> [String] {
        operations.enumerated().compactMap { index, operation in
            let prefix = "第\(index + 1)条（\(operation.actionDisplayText)\(operation.entityDisplayText)）"

            let hasItemPayload = operation.item?.hasMeaningfulValue ?? false
            let hasLocationPayload = operation.location?.hasMeaningfulValue ?? false
            let hasEventPayload = operation.event?.hasMeaningfulValue ?? false
            let hasMemberPayload = operation.member?.hasMeaningfulValue ?? false

            let unrelatedPayloadExists: Bool = {
                switch operation.entity {
                case .item:
                    return hasLocationPayload || hasEventPayload || hasMemberPayload
                case .location:
                    return hasItemPayload || hasEventPayload || hasMemberPayload
                case .event:
                    return hasItemPayload || hasLocationPayload || hasMemberPayload
                case .member:
                    return hasItemPayload || hasLocationPayload || hasEventPayload
                }
            }()

            if unrelatedPayloadExists {
                return "\(prefix)包含非目标实体字段。"
            }

            switch operation.entity {
            case .item:
                if operation.action != .delete, !hasItemPayload {
                    return "\(prefix)缺少 item 字段。"
                }
                switch operation.action {
                case .create:
                    if operation.item?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少 item.name。"
                    }
                case .update:
                    if !operation.target.hasLocator,
                       operation.item?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 item.name）。"
                    }
                case .delete:
                    if !operation.target.hasLocator,
                       operation.item?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 item.name）。"
                    }
                }
            case .location:
                if operation.action != .delete, !hasLocationPayload {
                    return "\(prefix)缺少 location 字段。"
                }
                switch operation.action {
                case .create:
                    if operation.location?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少 location.name。"
                    }
                case .update:
                    if !operation.target.hasLocator,
                       operation.location?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 location.name）。"
                    }
                case .delete:
                    if !operation.target.hasLocator,
                       operation.location?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 location.name）。"
                    }
                }
            case .event:
                if operation.action != .delete, !hasEventPayload {
                    return "\(prefix)缺少 event 字段。"
                }
                switch operation.action {
                case .create:
                    if operation.event?.title?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少 event.title。"
                    }
                case .update:
                    if !operation.target.hasLocator,
                       operation.event?.title?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 event.title）。"
                    }
                case .delete:
                    if !operation.target.hasLocator,
                       operation.event?.title?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 event.title）。"
                    }
                }
            case .member:
                if operation.action != .delete, !hasMemberPayload {
                    return "\(prefix)缺少 member 字段。"
                }
                switch operation.action {
                case .create:
                    if operation.member?.name?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少 member.name。"
                    }
                case .update:
                    if !operation.target.hasLocator,
                       operation.member?.name?.trimmedNonEmpty == nil,
                       operation.member?.username?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 member.name/member.username）。"
                    }
                case .delete:
                    if !operation.target.hasLocator,
                       operation.member?.name?.trimmedNonEmpty == nil,
                       operation.member?.username?.trimmedNonEmpty == nil {
                        return "\(prefix)缺少可定位目标（target 或 member.name/member.username）。"
                    }
                }
            }

            return nil
        }
    }

    private static func mergeClarification(existing: String?, guardClarification: String) -> String {
        guard let existing else { return guardClarification }
        if existing.contains(guardClarification) {
            return existing
        }
        return "\(existing)\n\(guardClarification)"
    }

    private static func isBulkDeleteToken(_ token: String?) -> Bool {
        guard let token = token?.trimmedNonEmpty else { return false }
        let normalized = token
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        if normalized.isEmpty { return false }
        return bulkDeleteTokens.contains { marker in
            normalized == marker || normalized.contains(marker)
        }
    }

    private static let bulkDeleteTokens: [String] = [
        "__all__", "*", "all", "everything", "所有", "全部", "全体", "全都", "清空"
    ]

    private static func plannerError(_ message: String) -> NSError {
        NSError(
            domain: "AgentPlannerService",
            code: 4001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct RepairFailureDigest: Codable {
    var operationID: String
    var message: String
}

private extension String {
    var trimmedNonEmpty: String? {
        let token = trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

private extension AgentTarget? {
    var hasLocator: Bool {
        guard let target = self else { return false }
        return target.id?.trimmedNonEmpty != nil
            || target.name?.trimmedNonEmpty != nil
            || target.username?.trimmedNonEmpty != nil
    }
}

private extension AgentItemFields {
    var hasMeaningfulValue: Bool {
        !fieldPreviewLines.isEmpty
    }
}

private extension AgentLocationFields {
    var hasMeaningfulValue: Bool {
        !fieldPreviewLines.isEmpty
    }
}

private extension AgentEventFields {
    var hasMeaningfulValue: Bool {
        !fieldPreviewLines.isEmpty
    }
}

private extension AgentMemberFields {
    var hasMeaningfulValue: Bool {
        !fieldPreviewLines.isEmpty
    }
}
