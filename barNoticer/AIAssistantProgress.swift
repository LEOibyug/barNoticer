import Foundation

enum AIAssistantProgress: Equatable {
    case idle
    case thinking
    case readingTodos
    case preparingActions

    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .thinking:
            return "思考中..."
        case .readingTodos:
            return "阅览事项中..."
        case .preparingActions:
            return "整理操作建议中..."
        }
    }

    static func progress(forToolName name: String) -> AIAssistantProgress {
        switch name {
        case "list_active_todos", "list_completed_todos", "get_completion_stats", "list_groups":
            return .readingTodos
        case "create_todo", "update_todo", "complete_todo", "delete_todo", "create_group", "update_group", "delete_group", "save_daily_summary":
            return .preparingActions
        default:
            return .thinking
        }
    }
}
