import Foundation
import Network
import SwiftData
import CryptoKit

@MainActor
final class HousekeeperRuntimeService {
    static let shared = HousekeeperRuntimeService()
    static let defaultPort: UInt16 = 48765

    private static let maxRequestBytes = 1_048_576
    private static let headerBodyDelimiter = Data("\r\n\r\n".utf8)
    private static let idempotencyTTL: TimeInterval = 24 * 60 * 60
    private static let idempotencyMaxEntries: Int = 512
    private static let runtimeFolder = "runtime"
    private static let idempotencyStoreFilename = "idempotency_store_v1.json"

    private var listener: NWListener?
    private var modelContainer: ModelContainer?
    private var startedAt: Date?
    private var isListenerReady = false
    private var listenerStateText = "未启动"
    private var lastListenerError: String?
    private var requestCount: Int = 0
    private var lastRequestAt: Date?
    private var lastRequestPath: String?
    private var lastRequestID: String?
    private var lastResponseStatusCode: Int?
    private var idempotencyStore: [String: IdempotencyCacheEntry] = [:]

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
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
            self.isListenerReady = false
            self.listenerStateText = "启动中"
            self.lastListenerError = nil
            loadIdempotencyStoreFromDisk()
            print("[HousekeeperRuntime] 已启动：127.0.0.1:\(Self.defaultPort)")
        } catch {
            self.listenerStateText = "启动失败"
            self.lastListenerError = error.localizedDescription
            print("[HousekeeperRuntime] 启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        startedAt = nil
        isListenerReady = false
        listenerStateText = "已停止"
        print("[HousekeeperRuntime] 已停止")
    }

    func snapshot() -> HousekeeperRuntimeSnapshot {
        HousekeeperRuntimeSnapshot(
            port: Int(Self.defaultPort),
            endpoint: "http://127.0.0.1:\(Self.defaultPort)",
            isRunning: listener != nil,
            isReady: isListenerReady,
            stateText: listenerStateText,
            startedAt: startedAt,
            requestCount: requestCount,
            lastRequestAt: lastRequestAt,
            lastRequestPath: lastRequestPath,
            lastRequestID: lastRequestID,
            lastResponseStatusCode: lastResponseStatusCode,
            idempotencyEntryCount: idempotencyStore.count,
            tokenRequired: ProcessInfo.processInfo.environment["BLAB_HOUSEKEEPER_TOKEN"]?.trimmedNonEmpty != nil,
            lastError: lastListenerError
        )
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListenerReady = true
            listenerStateText = "监听中"
            lastListenerError = nil
        case .failed(let error):
            isListenerReady = false
            listenerStateText = "监听失败"
            lastListenerError = error.localizedDescription
            print("[HousekeeperRuntime] 监听失败：\(error.localizedDescription)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            isListenerReady = false
            if listenerStateText != "已停止" {
                listenerStateText = "已取消"
            }
            listener = nil
        case .setup:
            isListenerReady = false
            listenerStateText = "初始化"
        case .waiting(let error):
            isListenerReady = false
            listenerStateText = "等待网络"
            lastListenerError = error.localizedDescription
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
                        self.requestCount += 1
                        self.lastRequestAt = .now
                        self.lastRequestPath = parsed.request.path
                        let response = await self.route(request: parsed.request)
                        self.lastRequestID = response.headers["X-Request-ID"]
                            ?? parsed.request.headers["x-request-id"]
                            ?? self.lastRequestID
                        self.lastResponseStatusCode = response.statusCode
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
            return errorResponse(
                statusCode: 404,
                message: "接口不存在。",
                requestID: request.headers["x-request-id"]?.trimmedNonEmpty
            )
        }
    }

    private func validateAuthorization(for request: HTTPRequest) -> HTTPResponse? {
        guard let expected = ProcessInfo.processInfo.environment["BLAB_HOUSEKEEPER_TOKEN"]?.trimmedNonEmpty else {
            return nil
        }

        let provided = bearerToken(from: request.headers["authorization"])
            ?? request.headers["x-blab-token"]?.trimmedNonEmpty

        guard provided == expected else {
            return errorResponse(
                statusCode: 401,
                message: "鉴权失败。",
                requestID: request.headers["x-request-id"]?.trimmedNonEmpty
            )
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
        let requestID = resolveRequestID(from: request)
        let idempotencyKey = request.headers["idempotency-key"]?.trimmedNonEmpty
        let requestHash = sha256Hex(request.body)

        if let replay = replayedIdempotentResponse(
            idempotencyKey: idempotencyKey,
            requestHash: requestHash,
            requestID: requestID
        ) {
            return replay
        }

        func finish(_ response: HTTPResponse) -> HTTPResponse {
            finalizeExecuteResponse(
                idempotencyKey: idempotencyKey,
                requestHash: requestHash,
                response: response,
                requestID: requestID
            )
        }

        let payload: HousekeeperExecuteRequest
        do {
            payload = try jsonDecoder.decode(HousekeeperExecuteRequest.self, from: request.body)
        } catch {
            return finish(errorResponse(statusCode: 400, message: "请求体不是合法 JSON。", requestID: requestID))
        }

        guard let instruction = payload.instruction.trimmedNonEmpty else {
            return finish(errorResponse(statusCode: 400, message: "instruction 不能为空。", requestID: requestID))
        }

        guard let modelContainer else {
            return finish(errorResponse(statusCode: 503, message: "保姆 Runtime 尚未就绪。", requestID: requestID))
        }

        do {
            let modelContext = ModelContext(modelContainer)
            let settings = try fetchDefaultSettings(from: modelContext)

            guard let settings else {
                return finish(errorResponse(statusCode: 409, message: "未找到默认 AI 配置。", requestID: requestID))
            }
            guard settings.autoFillEnabled else {
                return finish(errorResponse(statusCode: 409, message: "AI 自动填写未启用。", requestID: requestID))
            }
            guard settings.apiKey.trimmedNonEmpty != nil else {
                return finish(errorResponse(statusCode: 409, message: "API Key 未配置。", requestID: requestID))
            }

            var snapshot = try fetchRuntimeData(from: modelContext)
            let preExecutionSnapshot = toVerificationSnapshot(snapshot)

            let currentMember = resolveCurrentMember(
                actorUsername: payload.actorUsername,
                members: snapshot.members
            )

            let initialPlannerContext = plannerContext(
                currentMember: currentMember,
                snapshot: snapshot
            )

            let loopResult = try await HousekeeperAgentLoopService.plan(
                instruction: instruction,
                settings: settings,
                context: initialPlannerContext,
                items: snapshot.items,
                locations: snapshot.locations,
                events: snapshot.events,
                members: snapshot.members
            )
            let plan = loopResult.plan
            let agentTrace = loopResult.trace
            let agentStats = loopResult.stats

            if let clarification = plan.clarification?.trimmedNonEmpty {
                let response = HousekeeperExecuteResponse(
                    ok: true,
                    requestID: requestID,
                    status: "clarification_required",
                    message: "需要补充说明后再执行。",
                    clarification: clarification,
                    plan: plan,
                    execution: nil,
                    agentTrace: agentTrace,
                    agentStats: agentStats,
                    verification: nil
                )
                return finish(jsonResponse(statusCode: 200, payload: response))
            }

            let shouldExecute = payload.autoExecute ?? true
            guard shouldExecute else {
                let response = HousekeeperExecuteResponse(
                    ok: true,
                    requestID: requestID,
                    status: "planned",
                    message: "计划生成完成，未执行。",
                    clarification: nil,
                    plan: plan,
                    execution: nil,
                    agentTrace: agentTrace,
                    agentStats: agentStats,
                    verification: nil
                )
                return finish(jsonResponse(statusCode: 200, payload: response))
            }

            let firstPass = AgentExecutorService.execute(
                plan: plan,
                modelContext: modelContext,
                currentMember: currentMember,
                items: snapshot.items,
                locations: snapshot.locations,
                events: snapshot.events,
                members: snapshot.members,
                requestID: requestID
            )

            var finalExecution = firstPass
            var finalPlan = plan
            let shouldAutoRepair = payload.autoRepair ?? true

            if shouldAutoRepair,
               firstPass.failureCount > 0 {
                let failedEntries = firstPass.entries.filter { !$0.success }
                if !failedEntries.isEmpty {
                    do {
                        snapshot = try fetchRuntimeData(from: modelContext)
                        let repairContext = plannerContext(
                            currentMember: currentMember,
                            snapshot: snapshot
                        )
                        let repairedPlan = try await AgentPlannerService.repairPlan(
                            originalInput: instruction,
                            previousPlan: plan,
                            failedEntries: failedEntries,
                            settings: settings,
                            context: repairContext
                        )
                        finalPlan = repairedPlan

                        if let clarification = repairedPlan.clarification?.trimmedNonEmpty {
                            let response = HousekeeperExecuteResponse(
                                ok: false,
                                requestID: requestID,
                                status: "clarification_required",
                                message: "首轮执行存在失败，自动修复需要补充说明。",
                                clarification: clarification,
                                plan: repairedPlan,
                                execution: HousekeeperExecutionPayload(result: firstPass),
                                agentTrace: agentTrace,
                                agentStats: agentStats,
                                verification: nil
                            )
                            return finish(jsonResponse(statusCode: 200, payload: response))
                        }

                        if !repairedPlan.operations.isEmpty {
                            let retryPass = AgentExecutorService.execute(
                                plan: repairedPlan,
                                modelContext: modelContext,
                                currentMember: currentMember,
                                items: snapshot.items,
                                locations: snapshot.locations,
                                events: snapshot.events,
                                members: snapshot.members,
                                requestID: requestID
                            )
                            finalExecution = mergeExecutionResults(
                                firstPass: firstPass,
                                retryPass: retryPass
                            )
                        }
                    } catch {
                        let repairFailure = AgentExecutionEntry(
                            operationID: "repair",
                            success: false,
                            message: "自动修复失败：\(error.localizedDescription)"
                        )
                        finalExecution = AgentExecutionResult(
                            entries: firstPass.entries + [repairFailure]
                        )
                    }
                }
            }

            let executionPayload = HousekeeperExecutionPayload(result: finalExecution)
            snapshot = try fetchRuntimeData(from: modelContext)
            let verificationResult = HousekeeperPostConditionVerifier.verify(
                plan: finalPlan,
                before: preExecutionSnapshot,
                after: toVerificationSnapshot(snapshot)
            )
            let verificationPayload = HousekeeperVerificationPayload(result: verificationResult)
            let hasExecutionFailure = finalExecution.failureCount > 0
            let hasVerificationFailure = verificationResult.failureCount > 0
            let responseMessage: String
            if hasExecutionFailure {
                responseMessage = "计划已执行，但存在失败项。\(finalExecution.summary)"
            } else if hasVerificationFailure {
                responseMessage = "执行完成，但目标校验未通过。\(verificationResult.summary)"
            } else {
                responseMessage = "\(finalExecution.summary) \(verificationResult.summary)"
            }

            let response = HousekeeperExecuteResponse(
                ok: !hasExecutionFailure && !hasVerificationFailure,
                requestID: requestID,
                status: "executed",
                message: responseMessage,
                clarification: nil,
                plan: finalPlan,
                execution: executionPayload,
                agentTrace: agentTrace,
                agentStats: agentStats,
                verification: verificationPayload
            )
            return finish(jsonResponse(statusCode: 200, payload: response))
        } catch {
            return finish(errorResponse(statusCode: 500, message: "执行失败：\(error.localizedDescription)", requestID: requestID))
        }
    }

    private func replayedIdempotentResponse(
        idempotencyKey: String?,
        requestHash: String,
        requestID: String
    ) -> HTTPResponse? {
        guard let idempotencyKey else { return nil }
        pruneIdempotencyStore(now: .now)

        guard let cached = idempotencyStore[idempotencyKey] else {
            return nil
        }

        guard cached.requestHash == requestHash else {
            var conflict = errorResponse(
                statusCode: 409,
                message: "同一个 Idempotency-Key 绑定了不同请求。",
                requestID: requestID
            )
            conflict.headers["Idempotency-Key"] = idempotencyKey
            return conflict
        }

        var replay = cached.response
        replay.headers["X-Idempotency-Replayed"] = "true"
        replay.headers["Idempotency-Key"] = idempotencyKey
        replay.headers["X-Request-ID"] = requestID
        replay.body = responseBodyWithUpdatedRequestID(replay.body, requestID: requestID)
        return replay
    }

    private func finalizeExecuteResponse(
        idempotencyKey: String?,
        requestHash: String,
        response: HTTPResponse,
        requestID: String
    ) -> HTTPResponse {
        var responseWithHeaders = response
        responseWithHeaders.headers["X-Request-ID"] = requestID

        guard let idempotencyKey else {
            return responseWithHeaders
        }

        responseWithHeaders.headers["Idempotency-Key"] = idempotencyKey
        responseWithHeaders.headers["X-Idempotency-Replayed"] = "false"

        pruneIdempotencyStore(now: .now)
        idempotencyStore[idempotencyKey] = IdempotencyCacheEntry(
            requestHash: requestHash,
            response: responseWithHeaders,
            createdAt: .now
        )
        pruneIdempotencyStore(now: .now)
        persistIdempotencyStoreToDisk()

        return responseWithHeaders
    }

    private func pruneIdempotencyStore(now: Date) {
        idempotencyStore = idempotencyStore.filter { now.timeIntervalSince($0.value.createdAt) <= Self.idempotencyTTL }
        guard idempotencyStore.count > Self.idempotencyMaxEntries else { return }

        let keysByOldest = idempotencyStore
            .sorted { lhs, rhs in
                lhs.value.createdAt < rhs.value.createdAt
            }
            .map(\.key)

        let overflow = idempotencyStore.count - Self.idempotencyMaxEntries
        for key in keysByOldest.prefix(overflow) {
            idempotencyStore.removeValue(forKey: key)
        }
    }

    private func loadIdempotencyStoreFromDisk() {
        guard let fileURL = idempotencyStoreFileURL() else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }

        do {
            let persisted = try jsonDecoder.decode(PersistedIdempotencyStore.self, from: data)
            var restored: [String: IdempotencyCacheEntry] = [:]

            for (key, entry) in persisted.entries {
                guard let body = Data(base64Encoded: entry.response.bodyBase64) else { continue }
                restored[key] = IdempotencyCacheEntry(
                    requestHash: entry.requestHash,
                    response: HTTPResponse(
                        statusCode: entry.response.statusCode,
                        headers: entry.response.headers,
                        body: body
                    ),
                    createdAt: entry.createdAt
                )
            }

            idempotencyStore = restored
            pruneIdempotencyStore(now: .now)
        } catch {
            lastListenerError = "幂等缓存加载失败：\(error.localizedDescription)"
            idempotencyStore = [:]
        }
    }

    private func persistIdempotencyStoreToDisk() {
        guard let fileURL = idempotencyStoreFileURL() else { return }

        let persisted = PersistedIdempotencyStore(
            entries: idempotencyStore.mapValues { entry in
                PersistedIdempotencyEntry(
                    requestHash: entry.requestHash,
                    response: PersistedHTTPResponse(
                        statusCode: entry.response.statusCode,
                        headers: entry.response.headers,
                        bodyBase64: entry.response.body.base64EncodedString()
                    ),
                    createdAt: entry.createdAt
                )
            }
        )

        do {
            let data = try jsonEncoder.encode(persisted)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            lastListenerError = "幂等缓存保存失败：\(error.localizedDescription)"
        }
    }

    private func idempotencyStoreFileURL() -> URL? {
        do {
            let runtimeDir = try AttachmentStore.appSupportDirectory()
                .appendingPathComponent(Self.runtimeFolder, isDirectory: true)
            try FileManager.default.createDirectory(
                at: runtimeDir,
                withIntermediateDirectories: true
            )
            return runtimeDir.appendingPathComponent(Self.idempotencyStoreFilename)
        } catch {
            lastListenerError = "无法创建 Runtime 存储目录：\(error.localizedDescription)"
            return nil
        }
    }

    private func resolveRequestID(from request: HTTPRequest) -> String {
        if let provided = request.headers["x-request-id"]?.trimmedNonEmpty {
            return provided
        }
        return "req-\(UUID().uuidString.lowercased())"
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func responseBodyWithUpdatedRequestID(_ body: Data, requestID: String) -> Data {
        guard !body.isEmpty else { return body }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: body, options: []),
              var dictionary = jsonObject as? [String: Any] else {
            return body
        }

        dictionary["requestID"] = requestID

        guard JSONSerialization.isValidJSONObject(dictionary),
              let updatedBody = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else {
            return body
        }
        return updatedBody
    }

    private func fetchDefaultSettings(from modelContext: ModelContext) throws -> AISettings? {
        let descriptor = FetchDescriptor<AISettings>(
            predicate: #Predicate<AISettings> { $0.key == "default" },
            sortBy: [SortDescriptor(\AISettings.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRuntimeData(from modelContext: ModelContext) throws -> RuntimeDataSnapshot {
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
        return RuntimeDataSnapshot(
            members: members,
            items: items,
            locations: locations,
            events: events
        )
    }

    private func plannerContext(
        currentMember: Member?,
        snapshot: RuntimeDataSnapshot
    ) -> AgentPlannerContext {
        AgentPlannerContext(
            now: .now,
            currentMemberName: currentMember?.displayName,
            itemNames: snapshot.items.map(\.name),
            locationNames: snapshot.locations.map(\.name),
            eventTitles: snapshot.events.map(\.title),
            members: snapshot.members.map {
                AgentPlannerMemberContext(name: $0.displayName, username: $0.username)
            }
        )
    }

    private func toVerificationSnapshot(_ snapshot: RuntimeDataSnapshot) -> HousekeeperVerificationSnapshot {
        HousekeeperVerificationSnapshot(
            items: snapshot.items,
            locations: snapshot.locations,
            events: snapshot.events,
            members: snapshot.members
        )
    }

    private func mergeExecutionResults(
        firstPass: AgentExecutionResult,
        retryPass: AgentExecutionResult
    ) -> AgentExecutionResult {
        let firstSuccessEntries = firstPass.entries
            .filter(\.success)
            .map { entry in
                AgentExecutionEntry(
                    operationID: entry.operationID,
                    success: true,
                    message: "[首轮] \(entry.message)"
                )
            }

        let retryEntries = retryPass.entries.map { entry in
            AgentExecutionEntry(
                operationID: entry.operationID,
                success: entry.success,
                message: "[修复] \(entry.message)"
            )
        }

        return AgentExecutionResult(entries: firstSuccessEntries + retryEntries)
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

    private func errorResponse(statusCode: Int, message: String, requestID: String? = nil) -> HTTPResponse {
        var response = jsonResponse(
            statusCode: statusCode,
            payload: ErrorPayload(ok: false, statusCode: statusCode, message: message, requestID: requestID)
        )
        if let requestID {
            response.headers["X-Request-ID"] = requestID
        }
        return response
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
    var autoRepair: Bool?
    var actorUsername: String?
}

private struct HousekeeperExecuteResponse: Codable {
    var ok: Bool
    var requestID: String
    var status: String
    var message: String
    var clarification: String?
    var plan: AgentPlan?
    var execution: HousekeeperExecutionPayload?
    var agentTrace: [String]?
    var agentStats: HousekeeperAgentLoopStats?
    var verification: HousekeeperVerificationPayload?
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

private struct HousekeeperVerificationPayload: Codable {
    struct Entry: Codable {
        var operationID: String
        var success: Bool
        var message: String
    }

    var successCount: Int
    var failureCount: Int
    var summary: String
    var entries: [Entry]

    init(result: HousekeeperVerificationResult) {
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

private struct RuntimeDataSnapshot {
    var members: [Member]
    var items: [LabItem]
    var locations: [LabLocation]
    var events: [LabEvent]
}

struct HousekeeperRuntimeSnapshot {
    var port: Int
    var endpoint: String
    var isRunning: Bool
    var isReady: Bool
    var stateText: String
    var startedAt: Date?
    var requestCount: Int
    var lastRequestAt: Date?
    var lastRequestPath: String?
    var lastRequestID: String?
    var lastResponseStatusCode: Int?
    var idempotencyEntryCount: Int
    var tokenRequired: Bool
    var lastError: String?
}

private struct IdempotencyCacheEntry {
    var requestHash: String
    var response: HTTPResponse
    var createdAt: Date
}

private struct PersistedIdempotencyStore: Codable {
    var entries: [String: PersistedIdempotencyEntry]
}

private struct PersistedIdempotencyEntry: Codable {
    var requestHash: String
    var response: PersistedHTTPResponse
    var createdAt: Date
}

private struct PersistedHTTPResponse: Codable {
    var statusCode: Int
    var headers: [String: String]
    var bodyBase64: String
}

private struct ErrorPayload: Codable {
    var ok: Bool
    var statusCode: Int
    var message: String
    var requestID: String?
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
