import Foundation
import Combine
import ServiceManagement

struct AppLaunchAtLoginStatus: Equatable {
    let status: SMAppService.Status

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var title: String {
        switch status {
        case .enabled:
            return "已开启"
        case .requiresApproval:
            return "需要系统确认"
        case .notRegistered:
            return "未开启"
        case .notFound:
            return "不可用"
        @unknown default:
            return "状态未知"
        }
    }

    var detail: String {
        switch status {
        case .enabled:
            return "应用会在登录后自动启动。"
        case .requiresApproval:
            return "已提交开机自启请求，可能需要在系统设置中确认。"
        case .notRegistered:
            return "应用不会随系统登录自动启动。"
        case .notFound:
            return "当前构建不支持注册登录项。"
        @unknown default:
            return "无法识别当前登录项状态。"
        }
    }
}

@MainActor
final class AppLaunchAtLoginController: ObservableObject {
    @Published private(set) var status: AppLaunchAtLoginStatus
    @Published private(set) var errorMessage = ""

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        status = AppLaunchAtLoginStatus(status: service.status)
    }

    var isEnabled: Bool {
        status.isEnabled
    }

    func refresh() {
        status = AppLaunchAtLoginStatus(status: service.status)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = ""
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }
}
