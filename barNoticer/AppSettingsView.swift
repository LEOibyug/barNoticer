import Carbon.HIToolbox
import SwiftUI

struct AppSettingsView: View {
    @StateObject private var launchAtLogin = AppLaunchAtLoginController()
    @State private var creationDraft = TodoCreationSettingsDraft()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                creationSection
                launchSection
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear {
            launchAtLogin.refresh()
            creationDraft.reload()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("应用设置")
                .font(.system(size: 28, weight: .semibold))
            Text("管理应用级行为。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var creationSection: some View {
        SettingsSection(title: "新建事项", subtitle: "快捷键用于在屏幕中心调出独立的新建事项面板。") {
            LabeledContent("快捷键") {
                HStack {
                    Text(creationDraft.shortcut.displayValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu("选择") {
                        creationShortcutButton("⌘⌥N", .init(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command, .option]))
                        creationShortcutButton("⌘⇧N", .init(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command, .shift]))
                        creationShortcutButton("⌘⌃N", .init(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command, .control]))
                    }
                }
            }
        }
    }

    private var launchSection: some View {
        SettingsSection(title: "启动", subtitle: "控制 barNoticer 是否在登录 macOS 后自动运行。") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    Text("开机自启")
                }
                .toggleStyle(.switch)

                Text(launchAtLogin.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(launchAtLogin.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !launchAtLogin.errorMessage.isEmpty {
                    Text(launchAtLogin.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func creationShortcutButton(_ title: String, _ value: AIKeyboardShortcut) -> some View {
        Button(title) {
            creationDraft.shortcut = value
        }
    }
}

#Preview {
    AppSettingsView()
}
