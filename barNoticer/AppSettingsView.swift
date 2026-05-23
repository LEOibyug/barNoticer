import SwiftUI

struct AppSettingsView: View {
    @StateObject private var launchAtLogin = AppLaunchAtLoginController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                launchSection
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear {
            launchAtLogin.refresh()
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
}

#Preview {
    AppSettingsView()
}
