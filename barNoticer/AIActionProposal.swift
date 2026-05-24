import Foundation

enum AIActionProposal: Equatable, Identifiable {
    case createTodo(
        id: UUID = UUID(),
        title: String,
        priority: TodoPriority,
        groupID: UUID? = nil,
        deadlineAt: Date? = nil,
        scheduledTimes: [Date] = [],
        recurrenceRule: TodoRecurrenceRule? = nil,
        recurrenceAnchor: Date? = nil
    )
    case updateTodo(
        id: UUID,
        title: String?,
        priority: TodoPriority?,
        groupID: UUID? = nil,
        deadlineAt: Date? = nil,
        scheduledTimes: [Date] = [],
        recurrenceRule: TodoRecurrenceRule? = nil,
        recurrenceAnchor: Date? = nil,
        clearsDeadline: Bool = false,
        clearsSchedule: Bool = false
    )
    case completeTodo(id: UUID)
    case deleteTodo(id: UUID)
    case createGroup(id: UUID = UUID(), name: String, colorHex: String)
    case updateGroup(id: UUID, name: String?, colorHex: String?, sortOrder: Int?)
    case deleteGroup(id: UUID)
    case saveDailySummary(id: UUID = UUID(), content: String)

    var id: UUID {
        switch self {
        case let .createTodo(id, _, _, _, _, _, _, _), let .createGroup(id, _, _), let .saveDailySummary(id, _):
            return id
        case let .updateTodo(id, _, _, _, _, _, _, _, _, _), let .completeTodo(id), let .deleteTodo(id), let .updateGroup(id, _, _, _), let .deleteGroup(id):
            return id
        }
    }

    var requiresConfirmation: Bool { true }

    var referencedTodoID: UUID? {
        switch self {
        case let .updateTodo(id, _, _, _, _, _, _, _, _, _), let .completeTodo(id), let .deleteTodo(id):
            return id
        case .createTodo, .createGroup, .updateGroup, .deleteGroup, .saveDailySummary:
            return nil
        }
    }

    var groupID: UUID? {
        switch self {
        case let .createTodo(_, _, _, groupID, _, _, _, _), let .updateTodo(_, _, _, groupID, _, _, _, _, _, _):
            return groupID
        case let .updateGroup(id, _, _, _), let .deleteGroup(id):
            return id
        case .completeTodo, .deleteTodo, .createGroup, .saveDailySummary:
            return nil
        }
    }

    var deadlineAt: Date? {
        switch self {
        case let .createTodo(_, _, _, _, deadlineAt, _, _, _), let .updateTodo(_, _, _, _, deadlineAt, _, _, _, _, _):
            return deadlineAt
        case .completeTodo, .deleteTodo, .createGroup, .updateGroup, .deleteGroup, .saveDailySummary:
            return nil
        }
    }

    var summary: String {
        switch self {
        case let .createTodo(_, title, priority, _, _, _, _, _):
            return "新增\(priority.title)重要性事项：\(title)"
        case let .updateTodo(id, title, priority, groupID, deadlineAt, scheduledTimes, recurrenceRule, _, clearsDeadline, clearsSchedule):
            if let title, let priority {
                return "修改事项：\(title)，重要性：\(priority.title)"
            }
            if let title {
                return "修改事项：\(title)"
            }
            if let priority {
                return "修改事项：\(id.uuidString)，重要性：\(priority.title)"
            }
            if groupID != nil {
                return "修改事项分组：\(id.uuidString)"
            }
            if deadlineAt != nil {
                return "修改事项截止时间：\(id.uuidString)"
            }
            if !scheduledTimes.isEmpty || recurrenceRule != nil {
                return "修改事项时间计划：\(id.uuidString)"
            }
            if clearsDeadline || clearsSchedule {
                return "清除事项截止时间：\(id.uuidString)"
            }
            return "修改事项：\(id.uuidString)"
        case let .completeTodo(id):
            return "完成事项：\(id.uuidString)"
        case let .deleteTodo(id):
            return "删除事项：\(id.uuidString)"
        case let .createGroup(_, name, _):
            return "新增分组：\(name)"
        case let .updateGroup(id, name, _, _):
            return name.map { "修改分组：\($0)" } ?? "修改分组：\(id.uuidString)"
        case let .deleteGroup(id):
            return "删除分组：\(id.uuidString)"
        case .saveDailySummary:
            return "保存当日总结"
        }
    }
}
