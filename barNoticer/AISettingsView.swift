import Carbon.HIToolbox
import SwiftUI

struct AISettingsView: View {
    @State private var draft = AISettingsDraft()
    @State private var statusMessage = ""
    @State private var isTestingConnection = false
    @StateObject private var memoryStore: AIGlobalMemoryStore
    @State private var memoryClearRequest: AIGlobalMemoryClearRequest?
    @State private var memoryError = ""

    init(memoryStore: AIGlobalMemoryStore? = nil) {
        _memoryStore = StateObject(wrappedValue: memoryStore ?? .shared)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                apiSection
                behaviorSection
                memorySection
                testSection
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear {
            draft.reload()
        }
        .alert("清空全部全局记忆？", isPresented: Binding(
            get: { memoryClearRequest != nil },
            set: { if !$0 { memoryClearRequest = nil } }
        ), presenting: memoryClearRequest) { request in
            Button("取消", role: .cancel) { memoryClearRequest = nil }
            Button("确认清空", role: .destructive) {
                do {
                    try memoryStore.confirmClear(request)
                    memoryError = ""
                } catch { memoryError = error.localizedDescription }
            }
        } message: { request in
            Text("将永久删除 \(request.entryCount) 条全局记忆，无法撤销。待办和当前聊天记录会保留。即使关闭 AI 操作审批，此操作仍需要确认。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 设置")
                .font(.system(size: 28, weight: .semibold))
            Text("配置 OpenAI 兼容接口、唤起快捷键和 AI 操作确认方式。修改后会自动保存。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var apiSection: some View {
        SettingsSection(title: "接口", subtitle: "默认按 OpenAI Chat Completions 格式请求。") {
            VStack(spacing: 12) {
                LabeledContent("Base URL") {
                    TextField("https://api.openai.com/v1", text: $draft.baseURLText)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("模型") {
                    TextField("gpt-4o-mini", text: $draft.model)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("API Key") {
                    SecureField("sk-...", text: $draft.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var behaviorSection: some View {
        SettingsSection(title: "交互", subtitle: "快捷键用于在屏幕中心调出 AI 输入框。") {
            VStack(spacing: 12) {
                LabeledContent("快捷键") {
                    HStack {
                        Text(draft.shortcut.displayValue)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu("选择") {
                            shortcutButton("⌘⌥Space", .init(keyCode: UInt32(kVK_Space), modifiers: [.command, .option]))
                            shortcutButton("⌘⌥A", .init(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command, .option]))
                            shortcutButton("⌘⌃Space", .init(keyCode: UInt32(kVK_Space), modifiers: [.command, .control]))
                        }
                    }
                }

                Toggle("AI 操作需要手动确认", isOn: $draft.requiresActionConfirmation)
                    .toggleStyle(.switch)
            }
        }
    }

    private var testSection: some View {
        SettingsSection(title: "连接测试", subtitle: "使用当前配置发送一次轻量请求。") {
            HStack {
                Button {
                    testConnection()
                } label: {
                    if isTestingConnection {
                        Label("测试中", systemImage: "hourglass")
                    } else {
                        Label("测试连接", systemImage: "network")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTestingConnection || !draft.canTestConnection)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    private var memorySection: some View {
        let result = Result { try memoryStore.read().entries }
        let entries = (try? result.get()) ?? []
        return SettingsSection(title: "全局记忆", subtitle: "每轮对话都会带入，跨新对话和应用重启保留。用户定义优先于内置默认偏好，可通过对话查看或修改。") {
            VStack(alignment: .leading, spacing: 12) {
                Text("记忆保存在本机，并随对话发送给你配置的 AI 服务。AI 可自动记录稳定偏好；用户明确保存的定义优先。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case let .failure(error) = result {
                    Text("读取记忆失败：\(error.localizedDescription)")
                        .foregroundStyle(.red)
                } else if entries.isEmpty {
                    Text("暂无全局记忆")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.key).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(entry.source.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(entry.content).font(.body).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
                HStack {
                    Text("\(entries.count) 条记忆").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空全部记忆…", role: .destructive) {
                        do { memoryClearRequest = try memoryStore.requestClear() }
                        catch { memoryError = error.localizedDescription }
                    }
                    .disabled(entries.isEmpty)
                }
                if !memoryError.isEmpty {
                    Text(memoryError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutButton(_ title: String, _ value: AIKeyboardShortcut) -> some View {
        Button(title) {
            draft.shortcut = value
        }
    }

    private func testConnection() {
        guard !isTestingConnection else { return }
        isTestingConnection = true
        statusMessage = "正在测试连接..."
        try? AppDebugLogStore.shared.write(.info, category: "AISettings", message: "Testing AI connection", metadata: ["model": draft.settings.model])

        let settings = draft.settings
        let key = draft.apiKey

        Task {
            do {
                try await AIClient().testConnection(settings: settings, apiKey: key)
                await MainActor.run {
                    try? AppDebugLogStore.shared.write(.info, category: "AISettings", message: "AI connection test succeeded")
                    statusMessage = "连接可用"
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    try? AppDebugLogStore.shared.write(.error, category: "AISettings", message: "AI connection test failed", metadata: ["error": error.localizedDescription])
                    statusMessage = error.localizedDescription
                    isTestingConnection = false
                }
            }
        }
    }
}

#Preview {
    AISettingsView()
}
