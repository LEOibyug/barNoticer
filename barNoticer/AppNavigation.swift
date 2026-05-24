import Foundation

enum SidebarSelection: Hashable {
    case filter(TodoFilter)
    case group(UUID)
    case islandSettings
    case aiSettings
    case reminderSettings
    case appSettings
}

enum TodoFilter: String, CaseIterable, Identifiable {
    case active
    case completed
    case all

    var id: String { rawValue }

    var emptyTitle: String {
        switch self {
        case .active: "没有进行中的待办"
        case .completed: "还没有完成记录"
        case .all: "还没有待办"
        }
    }

    var emptyMessage: String {
        switch self {
        case .active: "添加一条事项后，它会出现在顶部灵动岛摘要中。"
        case .completed: "勾选完成后，事项会保留在这里。"
        case .all: "用上方输入框创建第一条待办。"
        }
    }
}
