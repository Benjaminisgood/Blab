import SwiftUI
import SwiftData

struct DashboardHousekeeperCard: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<AISettings> { $0.key == "default" }, sort: [SortDescriptor(\AISettings.updatedAt, order: .reverse)]) private var aiSettingsList: [AISettings]
    @AppStorage("dashboard.agent.autoExecuteEnabled") private var autoExecuteEnabled = false

    let currentMember: Member?
    let items: [LabItem]
    let locations: [LabLocation]
    let events: [LabEvent]
    let members: [Member]

    @State private var instructionText: String = ""
    @State private var pendingPlan: AgentPlan?
    @State private var planningError: String?
    @State private var executionResult: AgentExecutionResult?
    @State private var isPlanning = false
    @State private var isExecuting = false
    @State private var latestSubmittedInstruction = ""
    @State private var clarificationReply = ""
    @State private var clarificationDecision: ClarificationDecision = .supplement
    @State private var clarificationTitleHint = ""
    @State private var clarificationParticipantsHint = ""
    @StateObject private var speechInputService = SpeechInputService()

    private var aiSettings: AISettings? {
        aiSettingsList.first
    }

    private var canSubmitClarificationFeedback: Bool {
        switch clarificationDecision {
        case .confirm, .reject:
            return true
        case .supplement:
            return clarificationReply.trimmedNonEmpty != nil
                || clarificationTitleHint.trimmedNonEmpty != nil
                || !parseParticipantNames(from: clarificationParticipantsHint).isEmpty
        }
    }

    var body: some View {
        EditorCard(
            title: "智能录入保姆",
            subtitle: "支持文本/语音输入，先生成执行计划，再确认自动新增/修改物品、空间、事项与成员。",
            systemImage: "sparkles.rectangle.stack.fill"
        ) {
            TextField(
                "例如：新增成员小王，用户名 wangx；把示波器状态改成借出并由 Ben 负责。",
                text: $instructionText,
                axis: .vertical
            )
            .lineLimit(3...7)

            HStack(spacing: 10) {
                Button {
                    generatePlan()
                } label: {
                    if isPlanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("生成执行计划")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPlanning || isExecuting || speechInputService.isRecording || instructionText.trimmedNonEmpty == nil)

                Button {
                    toggleSpeechInput()
                } label: {
                    Label(
                        speechInputService.isRecording ? "停止语音" : "语音输入",
                        systemImage: speechInputService.isRecording ? "stop.circle.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(speechInputService.isRecording ? .red : .accentColor)
                .disabled(isPlanning || isExecuting)

                Button("清空") {
                    reset()
                }
                .buttonStyle(.bordered)
                .disabled(isPlanning || isExecuting)
            }

            Toggle("自动执行（可选）", isOn: $autoExecuteEnabled)
                .font(.caption)

            Text("开启后：当计划无待澄清项时，生成计划后自动执行。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if speechInputService.isRecording {
                Label("语音识别中（\(speechInputService.recognitionMode.displayLabel)），点击“停止语音”结束。", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let speechError = speechInputService.errorMessage?.trimmedNonEmpty {
                Text(speechError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let settings = aiSettings {
                if !settings.autoFillEnabled {
                    Text("AI 自动填写未启用，请先在设置页开启。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if settings.apiKey.trimmedNonEmpty == nil {
                    Text("尚未配置 API Key，请先在设置页完成配置。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("未检测到 AI 配置，请先前往设置页保存默认配置。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let planningError {
                Text(planningError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let pendingPlan {
                Divider()

                Text("执行计划")
                    .font(.headline)

                Text(pendingPlan.batchSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if pendingPlan.operations.isEmpty {
                    Text("当前无可执行操作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pendingPlan.operations.enumerated()), id: \.offset) { index, operation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(operation.previewText)")
                                .font(.subheadline.weight(.semibold))

                            if let targetHint = operation.targetPreviewText {
                                Text(targetHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if operation.fieldPreviewLines.isEmpty {
                                Text("未检测到明确字段变更。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(operation.fieldPreviewLines.enumerated()), id: \.offset) { _, line in
                                    Text("• \(line)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let note = operation.note?.trimmedNonEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Button {
                        executePlan(pendingPlan)
                    } label: {
                        if isExecuting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("确认执行")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isPlanning
                        || isExecuting
                        || pendingPlan.operations.isEmpty
                        || pendingPlan.clarification?.trimmedNonEmpty != nil
                    )
                }

                if let clarification = pendingPlan.clarification?.trimmedNonEmpty {
                    ClarificationEditor(
                        clarification: clarification,
                        decision: $clarificationDecision,
                        titleHint: $clarificationTitleHint,
                        participantsHint: $clarificationParticipantsHint,
                        reply: $clarificationReply,
                        canSubmit: canSubmitClarificationFeedback,
                        isBusy: isPlanning || isExecuting,
                        onSubmit: {
                            regeneratePlanFromClarification(clarification)
                        },
                        onDismiss: {
                            self.pendingPlan = nil
                            resetClarificationInputs()
                        }
                    )
                }
            }

            if let executionResult {
                Divider()

                Text(executionResult.summary)
                    .font(.subheadline.weight(.semibold))

                ForEach(executionResult.entries) { entry in
                    Label {
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(entry.success ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(entry.success ? .green : .red)
                    }
                }
            }
        }
        .onChange(of: speechInputService.transcribedText) { _, newValue in
            instructionText = newValue
        }
        .onDisappear {
            speechInputService.stopRecording()
        }
    }

    private func reset() {
        speechInputService.reset()
        instructionText = ""
        latestSubmittedInstruction = ""
        resetClarificationInputs()
        pendingPlan = nil
        planningError = nil
        executionResult = nil
    }

    private func toggleSpeechInput() {
        if speechInputService.isRecording {
            speechInputService.stopRecording()
            return
        }

        Task {
            await speechInputService.startRecording(seedText: instructionText)
        }
    }

    private func generatePlan(
        modelInput: String? = nil,
        submittedInstruction: String? = nil
    ) {
        guard let input = (submittedInstruction ?? instructionText).trimmedNonEmpty else { return }
        let promptInput = modelInput ?? input
        latestSubmittedInstruction = input

        guard let aiSettings else {
            planningError = "未找到 AI 配置，请先在设置页保存默认配置。"
            return
        }

        guard aiSettings.autoFillEnabled else {
            planningError = "AI 自动填写未启用，请先在设置页开启。"
            return
        }

        guard aiSettings.apiKey.trimmedNonEmpty != nil else {
            planningError = "API Key 未配置，请先前往设置页保存。"
            return
        }

        planningError = nil
        executionResult = nil
        pendingPlan = nil
        isPlanning = true
        resetClarificationInputs()
        speechInputService.stopRecording()

        let context = AgentPlannerContext(
            now: .now,
            currentMemberName: currentMember?.displayName,
            itemNames: items.map(\.name),
            locationNames: locations.map(\.name),
            eventTitles: events.map(\.title),
            members: members.map { AgentPlannerMemberContext(name: $0.displayName, username: $0.username) }
        )

        Task {
            do {
                let plan = try await AgentPlannerService.plan(input: promptInput, settings: aiSettings, context: context)
                await MainActor.run {
                    pendingPlan = plan
                    planningError = nil
                    isPlanning = false

                    if autoExecuteEnabled,
                       plan.clarification?.trimmedNonEmpty == nil,
                       !plan.operations.isEmpty {
                        executePlan(plan)
                    }
                }
            } catch {
                await MainActor.run {
                    pendingPlan = nil
                    planningError = error.localizedDescription
                    isPlanning = false
                }
            }
        }
    }

    private func regeneratePlanFromClarification(_ clarification: String) {
        guard let feedback = buildClarificationFeedback() else { return }
        let base = latestSubmittedInstruction.trimmedNonEmpty ?? instructionText.trimmedNonEmpty ?? ""
        let feedbackSummary = feedback.summaryText
        let merged = [base, feedbackSummary].filter { !$0.isEmpty }.joined(separator: "；")
        instructionText = merged

        let clarificationPrompt = """
原始用户输入：
\(base)

上一轮待确认问题：
\(clarification)

用户结构化反馈（JSON）：
\(encodeClarificationFeedback(feedback))

请严格遵循：
1) 先理解 decision：
   - confirm: 按原意继续规划；若涉及事项，必须给出 event.title。
   - reject: 取消该意图，不要新增对应实体。
   - supplement: 结合补充细节继续规划。
2) 每个 operation 只能包含与 entity 对应的字段对象。
3) create 必须有基础名称；update 必须有可定位目标。
4) 若信息仍不足，返回 operations=[] 并在 clarification 说明缺少什么。
请重新输出完整、可执行的 JSON 计划。
"""

        generatePlan(modelInput: clarificationPrompt, submittedInstruction: merged)
    }

    private func executePlan(_ plan: AgentPlan) {
        guard !plan.operations.isEmpty else { return }

        isExecuting = true
        executionResult = nil

        Task {
            let firstPass = await MainActor.run {
                AgentExecutorService.execute(
                    plan: plan,
                    modelContext: modelContext,
                    currentMember: currentMember,
                    items: items,
                    locations: locations,
                    events: events,
                    members: members
                )
            }

            var finalResult = firstPass
            var repairPlan: AgentPlan?
            var repairError: String?
            let failedEntries = firstPass.entries.filter { !$0.success }

            if !failedEntries.isEmpty,
               let settings = aiSettings,
               settings.autoFillEnabled,
               settings.apiKey.trimmedNonEmpty != nil {
                let context = AgentPlannerContext(
                    now: .now,
                    currentMemberName: currentMember?.displayName,
                    itemNames: items.map(\.name),
                    locationNames: locations.map(\.name),
                    eventTitles: events.map(\.title),
                    members: members.map { AgentPlannerMemberContext(name: $0.displayName, username: $0.username) }
                )

                let originalInput = latestSubmittedInstruction.trimmedNonEmpty
                    ?? instructionText.trimmedNonEmpty
                    ?? ""

                do {
                    let repaired = try await AgentPlannerService.repairPlan(
                        originalInput: originalInput,
                        previousPlan: plan,
                        failedEntries: failedEntries,
                        settings: settings,
                        context: context
                    )
                    repairPlan = repaired

                    if repaired.clarification?.trimmedNonEmpty == nil,
                       !repaired.operations.isEmpty {
                        let retryResult = await MainActor.run {
                            AgentExecutorService.execute(
                                plan: repaired,
                                modelContext: modelContext,
                                currentMember: currentMember,
                                items: items,
                                locations: locations,
                                events: events,
                                members: members
                            )
                        }
                        finalResult = mergeExecutionResults(firstPass: firstPass, retryPass: retryResult)
                    }
                } catch {
                    repairError = error.localizedDescription
                }
            }

            await MainActor.run {
                executionResult = finalResult
                isExecuting = false

                if let repaired = repairPlan,
                   let clarification = repaired.clarification?.trimmedNonEmpty {
                    pendingPlan = repaired
                    planningError = "自动修复需要补充信息：\(clarification)"
                } else if let repairError {
                    planningError = "自动修复失败：\(repairError)"
                } else if finalResult.successCount > 0 {
                    pendingPlan = nil
                }
            }
        }
    }

    private func resetClarificationInputs() {
        clarificationReply = ""
        clarificationDecision = .supplement
        clarificationTitleHint = ""
        clarificationParticipantsHint = ""
    }

    private func buildClarificationFeedback() -> ClarificationFeedback? {
        let detail = clarificationReply.trimmedNonEmpty
        let title = clarificationTitleHint.trimmedNonEmpty
        let participantNames = parseParticipantNames(from: clarificationParticipantsHint)
        let normalizedParticipants = participantNames.isEmpty ? nil : participantNames

        if clarificationDecision == .supplement,
           detail == nil,
           title == nil,
           normalizedParticipants == nil {
            return nil
        }

        return ClarificationFeedback(
            decision: clarificationDecision.rawValue,
            eventTitle: title,
            participantNames: normalizedParticipants,
            extraNote: detail
        )
    }

    private func parseParticipantNames(from raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n")
        return raw
            .components(separatedBy: separators)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func encodeClarificationFeedback(_ feedback: ClarificationFeedback) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(feedback),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
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
}

private struct ClarificationEditor: View {
    let clarification: String
    @Binding var decision: ClarificationDecision
    @Binding var titleHint: String
    @Binding var participantsHint: String
    @Binding var reply: String
    let canSubmit: Bool
    let isBusy: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("待确认：\(clarification)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Picker("处理方式", selection: $decision) {
                Text(ClarificationDecision.confirm.label).tag(ClarificationDecision.confirm)
                Text(ClarificationDecision.reject.label).tag(ClarificationDecision.reject)
                Text(ClarificationDecision.supplement.label).tag(ClarificationDecision.supplement)
            }
            .pickerStyle(.segmented)
            .font(.caption)

            TextField("事项标题（可选）", text: $titleHint)

            TextField("参与成员（可选，逗号分隔）", text: $participantsHint)

            TextField(decision.replyPlaceholder, text: $reply, axis: .vertical)
                .lineLimit(2...4)

            HStack(spacing: 10) {
                Button("结构化反馈并重新生成") {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !canSubmit)

                Button("忽略并手动继续编辑输入") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }

            Text("存在待确认问题时，需先补充信息，系统不会执行。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let token = trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

private enum ClarificationDecision: String, CaseIterable, Identifiable {
    case confirm
    case reject
    case supplement

    var id: String { rawValue }

    var label: String {
        switch self {
        case .confirm:
            return "确认意图"
        case .reject:
            return "否定意图"
        case .supplement:
            return "补充细节"
        }
    }

    var replyPlaceholder: String {
        switch self {
        case .confirm:
            return "可选：补充执行细节（如时间、地点）"
        case .reject:
            return "可选：说明取消原因或替代动作"
        case .supplement:
            return "请补充说明后重新生成计划"
        }
    }
}

private struct ClarificationFeedback: Codable {
    var decision: String
    var eventTitle: String?
    var participantNames: [String]?
    var extraNote: String?
}

private extension ClarificationFeedback {
    var summaryText: String {
        var parts = ["澄清decision=\(decision)"]
        if let eventTitle {
            parts.append("title=\(eventTitle)")
        }
        if let participantNames, !participantNames.isEmpty {
            parts.append("participants=\(participantNames.joined(separator: ","))")
        }
        if let extraNote {
            parts.append("note=\(extraNote)")
        }
        return parts.joined(separator: "；")
    }
}

private extension AgentPlan {
    var batchSummaryText: String {
        guard !operations.isEmpty else { return "共 0 条操作" }

        let orderedPairs: [(AgentAction, AgentEntity)] = [
            (.create, .item), (.update, .item),
            (.create, .location), (.update, .location),
            (.create, .event), (.update, .event),
            (.create, .member), (.update, .member)
        ]

        let segments: [String] = orderedPairs.compactMap { pair in
            let count = operations.filter { $0.action == pair.0 && $0.entity == pair.1 }.count
            guard count > 0 else { return nil }
            let action = pair.0 == .create ? "新增" : "修改"
            let entity: String
            switch pair.1 {
            case .item:
                entity = "物品"
            case .location:
                entity = "空间"
            case .event:
                entity = "事项"
            case .member:
                entity = "成员"
            }
            return "\(action)\(entity) \(count) 条"
        }

        return "共 \(operations.count) 条操作：\(segments.joined(separator: "，"))"
    }
}
