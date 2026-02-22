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
        guard action == .update else { return nil }

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

        if normalized.operations.isEmpty,
           normalized.clarification?.trimmedNonEmpty == nil {
            throw plannerError("AI 未生成可执行计划，请补充更具体的指令后重试。")
        }

        return normalized
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
      "action": "create|update",
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
5) create 必须给出基础名称字段：item.name / location.name / event.title / member.name。
   - member.username 可选，若缺失请自动生成可用的小写英文用户名（尽量基于姓名拼音）。
6) 不要输出删除动作，只能 create 或 update。
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

    private static func contextJSONString(_ context: AgentPlannerContext) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(context),
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
            return updated
        }

        return AgentPlan(
            operations: normalizedOperations,
            clarification: plan.clarification?.trimmedNonEmpty
        )
    }

    private static func plannerError(_ message: String) -> NSError {
        NSError(
            domain: "AgentPlannerService",
            code: 4001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let token = trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
