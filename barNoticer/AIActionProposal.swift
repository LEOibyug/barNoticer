import Foundation

enum AIActionProposal: Equatable, Identifiable {
    case createTodo(id: UUID = UUID(), title: String, priority: TodoPriority)
    case updateTodo(id: UUID, title: String?, priority: TodoPriority?)
    case completeTodo(id: UUID)
    case deleteTodo(id: UUID)
    case saveDailySummary(id: UUID = UUID(), content: String)

    var id: UUID {
        switch self {
        case let .createTodo(id, _, _), let .saveDailySummary(id, _):
            return id
        case let .updateTodo(id, _, _), let .completeTodo(id), let .deleteTodo(id):
            return id
        }
    }

    var requiresConfirmation: Bool { true }

    var referencedTodoID: UUID? {
        switch self {
        case let .updateTodo(id, _, _), let .completeTodo(id), let .deleteTodo(id):
            return id
        case .createTodo, .saveDailySummary:
            return nil
        }
    }

    var summary: String {
        switch self {
        case let .createTodo(_, title, priority):
            return "新增\(priority.title)重要性事项：\(title)"
        case let .updateTodo(id, title, priority):
            if let title, let priority {
                return "修改事项：\(title)，重要性：\(priority.title)"
            }
            if let title {
                return "修改事项：\(title)"
            }
            if let priority {
                return "修改事项：\(id.uuidString)，重要性：\(priority.title)"
            }
            return "修改事项：\(id.uuidString)"
        case let .completeTodo(id):
            return "完成事项：\(id.uuidString)"
        case let .deleteTodo(id):
            return "删除事项：\(id.uuidString)"
        case .saveDailySummary:
            return "保存当日总结"
        }
    }
}
