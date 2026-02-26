import Foundation

struct AIChatService {
    struct ChatMessage: Codable {
        var role: String
        var content: String
    }

    struct ChatRequest: Codable {
        var model: String
        var messages: [ChatMessage]
        var temperature: Double
        var max_tokens: Int
    }

    struct ChatResponse: Codable {
        struct Choice: Codable {
            struct ChoiceMessage: Codable {
                var content: String?
            }
            var message: ChoiceMessage
        }
        var choices: [Choice]
    }

    static func normalizeProvider(_ raw: String) -> AIAutofillProvider {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["chatanywhere", "chat-anywhere", "chat_anywhere", "chat"].contains(token) {
            return .chatanywhere
        }
        if ["deepseek", "deep-seek", "deep_seek"].contains(token) {
            return .deepseek
        }
        if ["aliyun", "alibaba", "alicloud", "dashscope", "bailian", "qwen"].contains(token) {
            return .aliyun
        }
        return AIAutofillProvider(rawValue: token) ?? .chatanywhere
    }

    static func complete(
        prompt: String,
        settings: AISettings,
        maxTokens: Int = 600,
        systemPrompt: String? = nil
    ) async throws -> String {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "AIChatService", code: 1001, userInfo: [NSLocalizedDescriptionKey: "API Key 未配置。"])
        }

        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw NSError(domain: "AIChatService", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Base URL 未配置。"])
        }

        let endpoint = base.hasSuffix("/") ? "\(base)chat/completions" : "\(base)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "AIChatService", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Base URL 非法：\(endpoint)"])
        }

        let modelName = settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settings.provider.defaultModel : settings.model
        let normalizedSystemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveSystemPrompt = normalizedSystemPrompt.isEmpty
            ? "你是 Blab 的保姆。你会把自然语言任务转成可执行计划并谨慎执行。回答请简洁。"
            : normalizedSystemPrompt

        let requestPayload = ChatRequest(
            model: modelName,
            messages: [
                ChatMessage(role: "system", content: effectiveSystemPrompt),
                ChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            max_tokens: maxTokens
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(max(10, settings.timeoutSeconds))
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AIChatService", code: 1004, userInfo: [NSLocalizedDescriptionKey: "服务无响应。"])
        }

        guard (200...299).contains(http.statusCode) else {
            let serverText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AIChatService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "服务错误（HTTP \(http.statusCode)）：\(serverText)"]
            )
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let first = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            throw NSError(domain: "AIChatService", code: 1005, userInfo: [NSLocalizedDescriptionKey: "服务未返回有效内容。"])
        }
        return first
    }
}

enum HousekeeperPromptGuide {
    static let dispatcherPlaybook = """
[Blab Housekeeper Playbook v1]
- 先判断信息充分性：不足先检索或追问，充足再规划。
- 对象不明确或可能重名时，先用只读工具做定位和消歧。
- 工具调用要有进展：若结果为空或参数错误，必须调整参数或改用其它工具，不重复同参调用。
- 对新增意图，字段已充分时优先进入计划，不为“是否已存在”做无意义反复检索。
- 只输出约定 JSON，不输出解释性文本或 Markdown。
- 不编造工具结果：只能基于给定上下文和工具观察做决策。
"""

    static let plannerPlaybook = """
[Blab Housekeeper Playbook v1]
- 目标是“可执行计划”，不是泛化建议；输出必须严格符合 schema。
- update/delete 必须可定位目标；create 必须包含基础名称字段。
- 信息不足时不要猜测，返回空 operations 并在 clarification 写清缺失字段。
- 时间表达一律转成绝对 ISO8601，禁止保留“今天/明天/下周一”。
- 只使用当前上下文与观察事实，不臆造不存在的实体、成员或关系。
"""
}
