import SwiftUI

/// 四页设置共用的容器：原生 grouped Form 承载，页名与说明走导航标题。
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
        .frame(maxWidth: 720, alignment: .leading)
    }
}

/// 设置分组：标题放 Section header，说明文字放 Section footer。
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}
