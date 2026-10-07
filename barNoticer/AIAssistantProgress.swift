import Foundation

enum AIAssistantProgress: Equatable {
    case idle
    case thinking
    case readingMemory
    case savingMemory
    case preparingMemoryClear
    case readingTodos
    case preparingActions

    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .thinking:
            return "思考中..."
        case .readingMemory:
            return "查阅记忆中..."
        case .savingMemory:
            return "记录记忆中..."
        case .preparingMemoryClear:
            return "准备清空确认..."
        case .readingTodos:
            return "查阅事项中..."
        case .preparingActions:
            return "整理操作建议中..."
        }
    }

    static func progress(forToolNames names: [String]) -> AIAssistantProgress {
        let activities = names.map { progress(forToolName: $0) }
        return [.readingMemory, .readingTodos, .savingMemory, .preparingMemoryClear, .preparingActions]
            .first(where: activities.contains) ?? .thinking
    }

    static func progress(forToolName name: String) -> AIAssistantProgress {
        switch name {
        case "read_global_memory": return .readingMemory
        case "save_global_memory": return .savingMemory
        case "clear_global_memory": return .preparingMemoryClear
        case "list_active_todos", "list_completed_todos", "get_completion_stats", "list_groups":
            return .readingTodos
        case "create_todo", "update_todo", "complete_todo", "delete_todo", "create_group", "update_group", "delete_group", "save_daily_summary":
            return .preparingActions
        default:
            return .thinking
        }
    }
}
