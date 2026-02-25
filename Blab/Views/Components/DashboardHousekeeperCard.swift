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
    @StateObject private var speechInputService = SpeechInputService()

    private var aiSettings: AISettings? {
        aiSettingsList.first
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("待确认：\(clarification)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        TextField("请补充说明后重新生成计划", text: $clarificationReply, axis: .vertical)
                            .lineLimit(2...4)

                        HStack(spacing: 10) {
                            Button("补充说明并重新生成") {
                                regeneratePlanFromClarification(clarification)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isPlanning || isExecuting || clarificationReply.trimmedNonEmpty == nil)

                            Button("忽略并手动继续编辑输入") {
                                self.pendingPlan = nil
                            }
                            .buttonStyle(.bordered)
                            .disabled(isPlanning || isExecuting)
                        }

                        Text("存在待确认问题时，需先补充信息，系统不会执行。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
        clarificationReply = ""
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
        clarificationReply = ""
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
        guard let reply = clarificationReply.trimmedNonEmpty else { return }
        let base = latestSubmittedInstruction.trimmedNonEmpty ?? instructionText.trimmedNonEmpty ?? ""
        let merged = [base, reply].filter { !$0.isEmpty }.joined(separator: "；")
        instructionText = merged

        let clarificationPrompt = """
原始用户输入：
\(base)

上一轮待确认问题：
\(clarification)

用户补充说明：
\(reply)

请结合以上信息，重新输出完整、可执行的 JSON 计划。
"""

        generatePlan(modelInput: clarificationPrompt, submittedInstruction: merged)
    }

    private func executePlan(_ plan: AgentPlan) {
        guard !plan.operations.isEmpty else { return }

        isExecuting = true
        executionResult = nil

        Task {
            let result = await MainActor.run {
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

            await MainActor.run {
                executionResult = result
                isExecuting = false
                if result.successCount > 0 {
                    pendingPlan = nil
                }
            }
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let token = trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
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
