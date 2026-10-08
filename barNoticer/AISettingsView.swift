import Carbon.HIToolbox
import SwiftUI

struct AISettingsView: View {
    @State private var draft = AISettingsDraft()
    @StateObject private var memoryStore: AIGlobalMemoryStore
    @State private var memoryClearRequest: AIGlobalMemoryClearRequest?
    @State private var memoryError = ""

    init(memoryStore: AIGlobalMemoryStore? = nil) {
        _memoryStore = StateObject(wrappedValue: memoryStore ?? .shared)
    }

    var body: some View {
        SettingsPage(title: "AI 设置", subtitle: "管理供应商、模型和 AI 操作方式。修改后自动保存。") {
            AIProviderSettingsView(draft: $draft)
            behaviorSection
            memorySection
        }
        .onAppear {
            draft.reload()
        }
        .alert("清空全部记忆？", isPresented: Binding(
            get: { memoryClearRequest != nil },
            set: { if !$0 { memoryClearRequest = nil } }
        ), presenting: memoryClearRequest) { request in
            Button("取消", role: .cancel) { memoryClearRequest = nil }
            Button("清空记忆", role: .destructive) {
                do {
                    try memoryStore.confirmClear(request)
                    memoryError = ""
                } catch { memoryError = error.localizedDescription }
            }
        } message: { request in
            Text("将删除 \(request.entryCount) 条记忆，无法恢复。待办和聊天记录会保留。")
        }
    }

    private var behaviorSection: some View {
        SettingsSection(title: "交互", footer: "快捷键用于调出 AI 输入框。关闭操作确认后，普通操作会直接执行；清空全局记忆始终需要二次确认。") {
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

    private var memorySection: some View {
        let result = Result { try memoryStore.read().entries }
        let entries = (try? result.get()) ?? []
        return SettingsSection(title: "全局记忆", footer: "由 AI 按需查阅，跨新对话和应用重启保留。用户定义优先于内置默认偏好，可通过对话查看或修改。") {
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

    @ViewBuilder
    private func shortcutButton(_ title: String, _ value: AIKeyboardShortcut) -> some View {
        Button(title) {
            draft.shortcut = value
        }
    }


}

#Preview {
    AISettingsView()
}
