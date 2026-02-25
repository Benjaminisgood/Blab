import Foundation
import Network
import SwiftData

@MainActor
final class HousekeeperRuntimeService {
    static let shared = HousekeeperRuntimeService()
    static let defaultPort: UInt16 = 48765

    private static let maxRequestBytes = 1_048_576
    private static let headerBodyDelimiter = Data("\r\n\r\n".utf8)

    private var listener: NWListener?
    private var modelContainer: ModelContainer?
    private var startedAt: Date?

    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private init() {}

    func startIfNeeded(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        guard listener == nil else { return }

        do {
            guard let port = NWEndpoint.Port(rawValue: Self.defaultPort) else {
                print("[HousekeeperRuntime] 无法创建端口：\(Self.defaultPort)")
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }
            listener.start(queue: .main)

            self.listener = listener
            self.startedAt = .now
            print("[HousekeeperRuntime] 已启动：127.0.0.1:\(Self.defaultPort)")
        } catch {
            print("[HousekeeperRuntime] 启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        startedAt = nil
        print("[HousekeeperRuntime] 已停止")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            break
        case .failed(let error):
            print("[HousekeeperRuntime] 监听失败：\(error.localizedDescription)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            listener = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard isLoopbackConnection(connection.endpoint) else {
            connection.cancel()
            return
        }

        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    print("[HousekeeperRuntime] 连接异常：\(error.localizedDescription)")
                    connection.cancel()
                    return
                }

                var merged = buffer
                if let data, !data.isEmpty {
                    merged.append(data)
                }

                if merged.count > Self.maxRequestBytes {
                    self.send(
                        self.errorResponse(statusCode: 413, message: "请求体过大。"),
                        on: connection
                    )
                    return
                }

                switch self.parseRequest(from: merged) {
                case .incomplete:
                    if isComplete {
                        self.send(
                            self.errorResponse(statusCode: 400, message: "请求格式不完整。"),
                            on: connection
                        )
                    } else {
                        self.receive(on: connection, buffer: merged)
                    }
                case .invalid(let message):
                    self.send(
                        self.errorResponse(statusCode: 400, message: message),
                        on: connection
                    )
                case .ready(let parsed):
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let response = await self.route(request: parsed.request)
                        self.send(response, on: connection)
                    }
                }
            }
        }
    }

    private func route(request: HTTPRequest) async -> HTTPResponse {
        if let unauthorized = validateAuthorization(for: request) {
            return unauthorized
        }

        switch (request.method, request.path) {
        case ("GET", "/housekeeper/health"):
            return healthResponse()
        case ("POST", "/housekeeper/execute"):
            return await executeResponse(for: request)
        default:
            return errorResponse(statusCode: 404, message: "接口不存在。")
        }
    }

    private func validateAuthorization(for request: HTTPRequest) -> HTTPResponse? {
        guard let expected = ProcessInfo.processInfo.environment["BLAB_HOUSEKEEPER_TOKEN"]?.trimmedNonEmpty else {
            return nil
        }

        let provided = bearerToken(from: request.headers["authorization"])
            ?? request.headers["x-blab-token"]?.trimmedNonEmpty

        guard provided == expected else {
            return errorResponse(statusCode: 401, message: "鉴权失败。")
        }
        return nil
    }

    private func healthResponse() -> HTTPResponse {
        let payload = HousekeeperHealthPayload(
            ok: true,
            service: "blab-housekeeper-runtime",
            role: "保姆",
            port: Int(Self.defaultPort),
            startedAt: startedAt
        )
        return jsonResponse(statusCode: 200, payload: payload)
    }

    private func executeResponse(for request: HTTPRequest) async -> HTTPResponse {
        let payload: HousekeeperExecuteRequest
        do {
            payload = try jsonDecoder.decode(HousekeeperExecuteRequest.self, from: request.body)
        } catch {
            return errorResponse(statusCode: 400, message: "请求体不是合法 JSON。")
        }

        guard let instruction = payload.instruction.trimmedNonEmpty else {
            return errorResponse(statusCode: 400, message: "instruction 不能为空。")
        }

        guard let modelContainer else {
            return errorResponse(statusCode: 503, message: "保姆 Runtime 尚未就绪。")
        }

        do {
            let modelContext = ModelContext(modelContainer)
            let settings = try fetchDefaultSettings(from: modelContext)

            guard let settings else {
                return errorResponse(statusCode: 409, message: "未找到默认 AI 配置。")
            }
            guard settings.autoFillEnabled else {
                return errorResponse(statusCode: 409, message: "AI 自动填写未启用。")
            }
            guard settings.apiKey.trimmedNonEmpty != nil else {
                return errorResponse(statusCode: 409, message: "API Key 未配置。")
            }

            let members = try modelContext.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\Member.name)]))
            let items = try modelContext.fetch(FetchDescriptor<LabItem>(sortBy: [SortDescriptor(\LabItem.name)]))
            let locations = try modelContext.fetch(FetchDescriptor<LabLocation>(sortBy: [SortDescriptor(\LabLocation.name)]))
            let events = try modelContext.fetch(
                FetchDescriptor<LabEvent>(
                    sortBy: [
                        SortDescriptor(\LabEvent.startTime, order: .forward),
                        SortDescriptor(\LabEvent.createdAt, order: .reverse)
                    ]
                )
            )

            let currentMember = resolveCurrentMember(
                actorUsername: payload.actorUsername,
                members: members
            )

            let plannerContext = AgentPlannerContext(
                now: .now,
                currentMemberName: currentMember?.displayName,
                itemNames: items.map(\.name),
                locationNames: locations.map(\.name),
                eventTitles: events.map(\.title),
                members: members.map {
                    AgentPlannerMemberContext(name: $0.displayName, username: $0.username)
                }
            )

            let plan = try await AgentPlannerService.plan(
                input: instruction,
                settings: settings,
                context: plannerContext
            )

            if let clarification = plan.clarification?.trimmedNonEmpty {
                let response = HousekeeperExecuteResponse(
                    ok: true,
                    status: "clarification_required",
                    message: "需要补充说明后再执行。",
                    clarification: clarification,
                    plan: plan,
                    execution: nil
                )
                return jsonResponse(statusCode: 200, payload: response)
            }

            let shouldExecute = payload.autoExecute ?? true
            guard shouldExecute else {
                let response = HousekeeperExecuteResponse(
                    ok: true,
                    status: "planned",
                    message: "计划生成完成，未执行。",
                    clarification: nil,
                    plan: plan,
                    execution: nil
                )
                return jsonResponse(statusCode: 200, payload: response)
            }

            let execution = AgentExecutorService.execute(
                plan: plan,
                modelContext: modelContext,
                currentMember: currentMember,
                items: items,
                locations: locations,
                events: events,
                members: members
            )

            let executionPayload = HousekeeperExecutionPayload(result: execution)
            let response = HousekeeperExecuteResponse(
                ok: execution.failureCount == 0,
                status: "executed",
                message: execution.failureCount == 0
                    ? execution.summary
                    : "计划已执行，但存在失败项。\(execution.summary)",
                clarification: nil,
                plan: plan,
                execution: executionPayload
            )
            return jsonResponse(statusCode: 200, payload: response)
        } catch {
            return errorResponse(statusCode: 500, message: "执行失败：\(error.localizedDescription)")
        }
    }

    private func fetchDefaultSettings(from modelContext: ModelContext) throws -> AISettings? {
        let descriptor = FetchDescriptor<AISettings>(
            predicate: #Predicate<AISettings> { $0.key == "default" },
            sortBy: [SortDescriptor(\AISettings.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).first
    }

    private func resolveCurrentMember(actorUsername: String?, members: [Member]) -> Member? {
        guard let actorToken = actorUsername?.trimmedNonEmpty else {
            return nil
        }

        return members.first {
            $0.username.compare(
                actorToken,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let payload = encodeHTTPResponse(response)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func encodeHTTPResponse(_ response: HTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json; charset=utf-8"

        var text = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                text += "\(key): \(value)\r\n"
            }
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(response.body)
        return data
    }

    private func jsonResponse<T: Encodable>(statusCode: Int, payload: T) -> HTTPResponse {
        do {
            let body = try jsonEncoder.encode(payload)
            return HTTPResponse(statusCode: statusCode, headers: [:], body: body)
        } catch {
            let fallback = #"{"ok":false,"message":"响应编码失败。"}"#
            return HTTPResponse(statusCode: 500, headers: [:], body: Data(fallback.utf8))
        }
    }

    private func errorResponse(statusCode: Int, message: String) -> HTTPResponse {
        jsonResponse(
            statusCode: statusCode,
            payload: ErrorPayload(ok: false, statusCode: statusCode, message: message)
        )
    }

    private func bearerToken(from raw: String?) -> String? {
        guard let raw = raw?.trimmedNonEmpty else { return nil }
        let segments = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard segments.count == 2 else { return nil }
        guard segments[0].lowercased() == "bearer" else { return nil }
        let token = String(segments[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func parseRequest(from data: Data) -> ParseResult {
        guard let headerRange = data.range(of: Self.headerBodyDelimiter) else {
            return .incomplete
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid("请求头编码非法。")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("请求行缺失。")
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return .invalid("请求行格式非法。")
        }

        let method = String(requestParts[0]).uppercased()
        let path = normalizePath(String(requestParts[1]))

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLengthToken = headers["content-length"] ?? "0"
        guard let contentLength = Int(contentLengthToken), contentLength >= 0 else {
            return .invalid("Content-Length 非法。")
        }

        let bodyStartIndex = headerRange.upperBound
        let expectedTotalCount = bodyStartIndex + contentLength
        guard data.count >= expectedTotalCount else {
            return .incomplete
        }

        let body = Data(data[bodyStartIndex..<expectedTotalCount])
        return .ready(
            ParsedRequest(
                request: HTTPRequest(
                    method: method,
                    path: path,
                    headers: headers,
                    body: body
                )
            )
        )
    }

    private func normalizePath(_ raw: String) -> String {
        if let idx = raw.firstIndex(of: "?") {
            return String(raw[..<idx])
        }
        return raw
    }

    private func isLoopbackConnection(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let token = "\(host)"
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        return token == "127.0.0.1"
            || token == "::1"
            || token == "localhost"
            || token == "::ffff:127.0.0.1"
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

private struct ParsedRequest {
    var request: HTTPRequest
}

private enum ParseResult {
    case incomplete
    case invalid(String)
    case ready(ParsedRequest)
}

private struct HTTPResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

private struct HousekeeperExecuteRequest: Codable {
    var instruction: String
    var autoExecute: Bool?
    var actorUsername: String?
}

private struct HousekeeperExecuteResponse: Codable {
    var ok: Bool
    var status: String
    var message: String
    var clarification: String?
    var plan: AgentPlan?
    var execution: HousekeeperExecutionPayload?
}

private struct HousekeeperExecutionPayload: Codable {
    struct Entry: Codable {
        var operationID: String
        var success: Bool
        var message: String
    }

    var successCount: Int
    var failureCount: Int
    var summary: String
    var entries: [Entry]

    init(result: AgentExecutionResult) {
        successCount = result.successCount
        failureCount = result.failureCount
        summary = result.summary
        entries = result.entries.map {
            Entry(operationID: $0.operationID, success: $0.success, message: $0.message)
        }
    }
}

private struct HousekeeperHealthPayload: Codable {
    var ok: Bool
    var service: String
    var role: String
    var port: Int
    var startedAt: Date?
}

private struct ErrorPayload: Codable {
    var ok: Bool
    var statusCode: Int
    var message: String
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
