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

    static func complete(prompt: String, settings: AISettings, maxTokens: Int = 600) async throws -> String {
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
        let requestPayload = ChatRequest(
            model: modelName,
            messages: [
                ChatMessage(role: "system", content: "你是 Benlab 的表单助手。请简洁回答。"),
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
