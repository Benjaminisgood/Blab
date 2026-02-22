import SwiftUI
import SwiftData
import AppKit

struct SettingsSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]
    @Query(filter: #Predicate<AISettings> { $0.key == "default" }, sort: [SortDescriptor(\AISettings.updatedAt, order: .reverse)]) private var aiSettingsList: [AISettings]

    @Binding var currentMemberID: String

    @State private var aiTestPrompt = "请用一句话介绍 Benlab 的用途。"
    @State private var aiTestResult = ""
    @State private var isTestingAI = false

    private var aiSettings: AISettings? {
        aiSettingsList.first
    }

    private var currentMember: Member? {
        members.first(where: { $0.id.uuidString == currentMemberID })
    }

    var body: some View {
        NavigationStack {
            EditorCanvas(maxWidth: 1040) {
                EditorHeader(
                    title: "系统设置",
                    subtitle: "管理当前权限视角、本地存储与 AI 接入能力。",
                    systemImage: "slider.horizontal.3"
                )

                EditorCard(
                    title: "当前成员视角",
                    subtitle: "用于权限判断和界面展示",
                    systemImage: "person.crop.circle.fill"
                ) {
                    if members.isEmpty {
                        Text("暂无成员，请先在成员页创建。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("活动成员", selection: $currentMemberID) {
                            ForEach(members) { member in
                                Text(member.displayName).tag(member.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)

                        if let currentMember {
                            Text("当前权限视角：@\(currentMember.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("请选择一个成员以启用权限判断。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                EditorCard(
                    title: "本地存储",
                    subtitle: "仅本地持久化，不依赖 OSS 或远程数据库",
                    systemImage: "internaldrive.fill"
                ) {
                    Text(localStoragePath)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack {
                        Button("打开数据目录") {
                            openStorageFolder()
                        }
                        .buttonStyle(.bordered)

                        Text("你可以在 Finder 中直接查看附件目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                EditorCard(
                    title: "数据库位置（SwiftData）",
                    subtitle: "主库文件 + WAL/SHM 日志文件",
                    systemImage: "cylinder.fill"
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("主库：\(databaseStorePath)")
                            .font(.caption)
                            .textSelection(.enabled)
                        Text("WAL：\(databaseWalPath)")
                            .font(.caption)
                            .textSelection(.enabled)
                        Text("SHM：\(databaseShmPath)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("定位数据库文件") {
                            revealDatabaseFiles()
                        }
                        .buttonStyle(.bordered)

                        Text("导出复用时建议同时备份这三个文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let aiSettings {
                    AISettingsEditor(
                        settings: aiSettings,
                        testPrompt: $aiTestPrompt,
                        testResult: $aiTestResult,
                        isTesting: $isTestingAI
                    )
                } else {
                    EditorCard(
                        title: "AI 配置",
                        subtitle: "正在初始化默认配置",
                        systemImage: "cpu.fill"
                    ) {
                        ProgressView("正在初始化配置...")
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                ensureCurrentMemberSelected()
                ensureAISettingsExists()
            }
        }
    }

    private var localStoragePath: String {
        (try? AttachmentStore.appSupportDirectory().path) ?? "无法读取 Application Support 目录"
    }

    private var appSupportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private var databaseStoreURL: URL? {
        appSupportDirectory?.appendingPathComponent("default.store")
    }

    private var databaseStorePath: String {
        databaseStoreURL?.path ?? "无法定位 default.store"
    }

    private var databaseWalPath: String {
        databaseStoreURL.map { "\($0.path)-wal" } ?? "无法定位 default.store-wal"
    }

    private var databaseShmPath: String {
        databaseStoreURL.map { "\($0.path)-shm" } ?? "无法定位 default.store-shm"
    }

    private func openStorageFolder() {
        guard let url = try? AttachmentStore.appSupportDirectory() else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealDatabaseFiles() {
        guard let storeURL = databaseStoreURL else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: storeURL.path) {
            var targets = [storeURL]

            let walURL = URL(fileURLWithPath: "\(storeURL.path)-wal")
            if fileManager.fileExists(atPath: walURL.path) {
                targets.append(walURL)
            }

            let shmURL = URL(fileURLWithPath: "\(storeURL.path)-shm")
            if fileManager.fileExists(atPath: shmURL.path) {
                targets.append(shmURL)
            }

            NSWorkspace.shared.activateFileViewerSelecting(targets)
        } else if let appSupportDirectory {
            NSWorkspace.shared.open(appSupportDirectory)
        }
    }

    private func ensureCurrentMemberSelected() {
        guard !members.isEmpty else { return }
        if members.first(where: { $0.id.uuidString == currentMemberID }) == nil {
            currentMemberID = members[0].id.uuidString
        }
    }

    private func ensureAISettingsExists() {
        if aiSettingsList.isEmpty {
            modelContext.insert(AISettings())
            try? modelContext.save()
        }
    }
}

private struct AISettingsEditor: View {
    @Environment(\.modelContext) private var modelContext

    let settings: AISettings
    @Binding var testPrompt: String
    @Binding var testResult: String
    @Binding var isTesting: Bool

    @State private var provider: AIAutofillProvider = .chatanywhere
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var timeoutSeconds: Int = 45
    @State private var autoFillEnabled: Bool = true
    @State private var preferredImageLimit: Int = 6

    var body: some View {
        EditorCard(
            title: "AI 模型与 API 配置",
            subtitle: "可视化配置 Provider、模型与密钥",
            systemImage: "cpu.fill"
        ) {
            Picker("Provider", selection: $provider) {
                ForEach(AIAutofillProvider.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: provider) { _, newValue in
                if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL == settings.provider.defaultBaseURL {
                    baseURL = newValue.defaultBaseURL
                }
                if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == settings.provider.defaultModel {
                    model = newValue.defaultModel
                }
            }

            TextField("Base URL", text: $baseURL)
            TextField("Model", text: $model)
            SecureField("API Key", text: $apiKey)

            HStack {
                Stepper("超时（秒）：\(timeoutSeconds)", value: $timeoutSeconds, in: 10...180)
                Stepper("图片上限：\(preferredImageLimit)", value: $preferredImageLimit, in: 1...16)
            }

            Toggle("启用 AI 自动填写", isOn: $autoFillEnabled)

            HStack {
                Button("保存配置") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("恢复 Provider 默认") {
                    baseURL = provider.defaultBaseURL
                    model = provider.defaultModel
                }
                .buttonStyle(.bordered)
            }
        }

        EditorCard(
            title: "连接测试",
            subtitle: "发送一条测试请求验证当前配置",
            systemImage: "bolt.horizontal.circle.fill"
        ) {
            TextField("测试 Prompt", text: $testPrompt, axis: .vertical)
                .lineLimit(3...6)

            HStack {
                Button {
                    testConnection()
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("发送测试请求")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)

                Button("清空结果") {
                    testResult = ""
                }
                .buttonStyle(.bordered)
            }

            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .onAppear {
            provider = settings.provider
            baseURL = settings.baseURL
            model = settings.model
            apiKey = settings.apiKey
            timeoutSeconds = settings.timeoutSeconds
            autoFillEnabled = settings.autoFillEnabled
            preferredImageLimit = settings.preferredImageLimit
        }
    }

    private func saveSettings() {
        settings.provider = provider
        settings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.timeoutSeconds = timeoutSeconds
        settings.autoFillEnabled = autoFillEnabled
        settings.preferredImageLimit = preferredImageLimit
        settings.touch()

        try? modelContext.save()
    }

    private func testConnection() {
        saveSettings()
        let prompt = testPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            testResult = "请输入测试 Prompt。"
            return
        }

        isTesting = true
        testResult = "正在请求..."

        Task {
            do {
                let reply = try await AIChatService.complete(prompt: prompt, settings: settings)
                await MainActor.run {
                    testResult = reply
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "请求失败：\(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
