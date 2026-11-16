import Foundation

enum AIActionProposal: Equatable, Identifiable {
    case createTodo(
        id: UUID = UUID(),
        title: String,
        note: String? = nil,
        priority: TodoPriority,
        groupID: UUID? = nil,
        deadlineAt: Date? = nil,
        scheduledTimes: [Date] = [],
        recurrenceRule: TodoRecurrenceRule? = nil,
        recurrenceAnchor: Date? = nil,
        reminderMinutesBefore: Int? = nil
    )
    case updateTodo(id: UUID, changes: AITodoUpdate)
    case completeTodo(id: UUID)
    case deleteTodo(id: UUID)
    case createGroup(id: UUID = UUID(), name: String, colorHex: String)
    case updateGroup(id: UUID, name: String?, colorHex: String?, sortOrder: Int?)
    case deleteGroup(id: UUID)
    case saveSummary(id: UUID = UUID(), title: String, periodStart: Date, periodEnd: Date, content: String)
    case clearGlobalMemory(id: UUID = UUID(), revision: UUID)

    var id: UUID {
        switch self {
        case let .clearGlobalMemory(id, _): return id
        case let .createTodo(id, _, _, _, _, _, _, _, _, _), let .createGroup(id, _, _), let .saveSummary(id, _, _, _, _):
            return id
        case let .updateTodo(id, _), let .completeTodo(id), let .deleteTodo(id), let .updateGroup(id, _, _, _), let .deleteGroup(id):
            return id
        }
    }

    var requiresConfirmation: Bool { true }

    var requiresMandatoryConfirmation: Bool {
        switch self {
        case .clearGlobalMemory, .saveSummary: return true
        default: return false
        }
    }

    var changeSummary: String? {
        if case let .updateTodo(_, changes) = self { return changes.summary }
        return nil
    }

    var referencedTodoID: UUID? {
        switch self {
        case let .updateTodo(id, _), let .completeTodo(id), let .deleteTodo(id):
            return id
        case .createTodo, .createGroup, .updateGroup, .deleteGroup, .saveSummary, .clearGlobalMemory:
            return nil
        }
    }

    var groupID: UUID? {
        switch self {
        case let .createTodo(_, _, _, _, groupID, _, _, _, _, _): return groupID
        case let .updateTodo(_, changes): return changes.clearsGroup ? TodoGroup.defaultGroupID : changes.groupID
        case let .updateGroup(id, _, _, _), let .deleteGroup(id):
            return id
        case .completeTodo, .deleteTodo, .createGroup, .saveSummary, .clearGlobalMemory:
            return nil
        }
    }

    var deadlineAt: Date? {
        switch self {
        case let .createTodo(_, _, _, _, _, deadlineAt, _, _, _, _): return deadlineAt
        case let .updateTodo(_, changes): return changes.deadlineAt
        case .completeTodo, .deleteTodo, .createGroup, .updateGroup, .deleteGroup, .saveSummary, .clearGlobalMemory:
            return nil
        }
    }

    var summary: String {
        switch self {
        case .clearGlobalMemory: return "清空全部全局记忆（必须二次确认）"
        case let .createTodo(_, title, _, priority, _, _, _, _, _, reminderMinutes):
            let suffix = reminderMinutes.map { "；" + TodoScheduledReminder.label(minutes: $0) } ?? ""
            return "新增\(priority.title)重要性事项：\(title)\(suffix)"
        case let .updateTodo(_, changes):
            return "修改事项：\(changes.summary)"
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
        case let .saveSummary(_, title, periodStart, periodEnd, _):
            return "保存总结：\(title)（\(SavedSummary.periodDescription(start: periodStart, end: periodEnd))）"
        }
    }
}

struct AITodoUpdate: Equatable {
    var title: String?
    var note: String?
    var priority: TodoPriority?
    var groupID: UUID?
    var clearsGroup = false
    var deadlineAt: Date?
    var scheduledTimes: [Date]?
    var recurrenceRule: TodoRecurrenceRule?
    var recurrenceIntervalDays: Int?
    var recurrenceAnchor: Date?
    var clearsNote = false
    var clearsDeadline = false
    var clearsSchedule = false
    var reminderMinutesBefore: Int?
    var clearsReminder = false
    var automaticallyCompletes: Bool?
    var isCompleted: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    var lastCompletedOccurrenceAt: Date?
    var clearsLastCompletedOccurrence = false

    var summary: String {
        var fields: [String] = []
        if let title { fields.append("标题：\(title)") }
        if let note { fields.append("备注：\(note)") }
        if clearsNote { fields.append("清空备注") }
        if let priority { fields.append("重要性：\(priority.title)") }
        if let groupID { fields.append("分组：\(groupID.uuidString)") }
        if clearsGroup { fields.append("移回默认分组") }
        if let deadlineAt { fields.append("截止时间：\(deadlineAt.formatted())") }
        if let scheduledTimes {
            fields.append(scheduledTimes.isEmpty ? "清除时间计划" : "时间点：" + scheduledTimes.map { $0.formatted() }.joined(separator: "、"))
        }
        if let recurrenceRule { fields.append("重复规则：\(recurrenceRule.title)") }
        if let recurrenceIntervalDays, recurrenceRule == nil { fields.append("每 \(recurrenceIntervalDays) 天重复") }
        if let recurrenceAnchor { fields.append("重复起点：\(recurrenceAnchor.formatted())") }
        if clearsDeadline || clearsSchedule { fields.append("清除时间计划") }
        if let reminderMinutesBefore { fields.append(TodoScheduledReminder.label(minutes: reminderMinutesBefore)) }
        if clearsReminder { fields.append("关闭定时提醒") }
        if let automaticallyCompletes { fields.append(automaticallyCompletes ? "开启到点自动完成" : "关闭到点自动完成") }
        if let isCompleted { fields.append(isCompleted ? "标记整项完成" : "恢复为未完成") }
        if let createdAt { fields.append("创建时间：\(createdAt.formatted())") }
        if let updatedAt { fields.append("更新时间／完成时间：\(updatedAt.formatted())") }
        if let lastCompletedOccurrenceAt { fields.append("最近完成周期：\(lastCompletedOccurrenceAt.formatted())") }
        if clearsLastCompletedOccurrence { fields.append("重置重复任务完成进度") }
        return fields.isEmpty ? "未指定修改字段" : fields.joined(separator: "；")
    }
}
