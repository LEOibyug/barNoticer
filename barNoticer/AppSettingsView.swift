import AppKit
import Carbon.HIToolbox
import SwiftUI

struct AppSettingsView: View {
    @StateObject private var launchAtLogin = AppLaunchAtLoginController()
    @State private var creationDraft = TodoCreationSettingsDraft()

    var body: some View {
        SettingsPage(title: "应用设置", subtitle: "管理应用级行为。") {
            creationSection
            launchSection
            advancedSection
        }
        .onAppear {
            launchAtLogin.refresh()
            creationDraft.reload()
        }
    }

    private var creationSection: some View {
        SettingsSection(title: "新建事项", footer: "快捷键用于在屏幕中心调出独立的新建事项面板。") {
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
        SettingsSection(title: "启动", footer: "控制 barNoticer 是否在登录 macOS 后自动运行。") {
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

    private var advancedSection: some View {
        SettingsSection(title: "高级", footer: "应用会写入轻量调试日志，并自动清理过大的旧日志。") {
            Text(AppDebugLogStore.shared.logFileURL.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                openLogDirectory()
            } label: {
                Label("打开日志位置", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
    }

    private func openLogDirectory() {
        try? FileManager.default.createDirectory(at: AppDebugLogStore.shared.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([AppDebugLogStore.shared.logFileURL])
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
