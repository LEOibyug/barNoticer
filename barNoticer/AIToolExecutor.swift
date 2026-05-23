import Foundation
import SwiftData

enum AIToolExecutorError: LocalizedError {
    case invalidArguments
    case unsupportedTool(String)
    case todoNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "AI 工具参数无效"
        case let .unsupportedTool(name):
            return "不支持的 AI 工具：\(name)"
        case let .todoNotFound(id):
            return "未找到事项：\(id.uuidString)"
        }
    }
}

@MainActor
final class AIToolExecutor {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func handle(_ toolCall: AIToolCall) throws -> AIToolHandlingResult {
        let arguments = try ToolArguments(json: toolCall.function.arguments)

        switch toolCall.function.name {
        case "list_active_todos":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), groups: try fetchGroups(), dailySummaries: try fetchDailySummaries())
            return .context(Self.encode(snapshot.activeByGroup))
        case "list_completed_todos":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), groups: try fetchGroups(), dailySummaries: try fetchDailySummaries())
            return .context(Self.encode(snapshot.completed))
        case "get_completion_stats":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), groups: try fetchGroups(), dailySummaries: try fetchDailySummaries())
            return .context(Self.encode(AIStatsPayload(snapshot: snapshot)))
        case "list_groups":
            return .context(Self.encode(TodoGroupResolver.normalizedGroups(try fetchGroups()).map(AITodoGroupSnapshot.init(group:))))
        case "create_todo":
            return .proposal(.createTodo(
                title: try arguments.string("title"),
                priority: try arguments.priority("priority"),
                groupID: arguments.optionalUUID("group_id"),
                deadlineAt: arguments.optionalDate("deadline_at")
            ))
        case "update_todo":
            return .proposal(.updateTodo(
                id: try arguments.uuid("id"),
                title: arguments.optionalString("title"),
                priority: arguments.optionalPriority("priority"),
                groupID: arguments.optionalUUID("group_id"),
                deadlineAt: arguments.optionalDate("deadline_at"),
                clearsDeadline: arguments.optionalBool("clear_deadline") ?? false
            ))
        case "complete_todo":
            return .proposal(.completeTodo(id: try arguments.uuid("id")))
        case "delete_todo":
            return .proposal(.deleteTodo(id: try arguments.uuid("id")))
        case "create_group":
            let colorHex: String
            if let providedColorHex = arguments.optionalString("color_hex") {
                colorHex = providedColorHex
            } else {
                colorHex = TodoGroupResolver.nextColorHex(for: try fetchGroups())
            }
            return .proposal(.createGroup(
                name: try arguments.string("name"),
                colorHex: colorHex
            ))
        case "update_group":
            return .proposal(.updateGroup(
                id: try arguments.uuid("id"),
                name: arguments.optionalString("name"),
                colorHex: arguments.optionalString("color_hex"),
                sortOrder: arguments.optionalInt("sort_order")
            ))
        case "delete_group":
            return .proposal(.deleteGroup(id: try arguments.uuid("id")))
        case "save_daily_summary":
            return .proposal(.saveDailySummary(content: try arguments.string("content")))
        default:
            throw AIToolExecutorError.unsupportedTool(toolCall.function.name)
        }
    }

    func apply(_ proposal: AIActionProposal) throws {
        switch proposal {
        case let .createTodo(_, title, priority, groupID, deadlineAt):
            modelContext.insert(TodoItem(title: title, priority: priority, groupID: groupID, deadlineAt: deadlineAt))
        case let .updateTodo(id, title, priority, groupID, deadlineAt, clearsDeadline):
            let item = try fetchTodo(id: id)
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                item.updateTitle(title)
            }
            if let priority {
                item.priority = priority
            }
            if let groupID {
                item.updateGroup(groupID)
            }
            if let deadlineAt {
                item.updateDeadline(deadlineAt)
            }
            if clearsDeadline {
                item.updateDeadline(nil)
            }
        case let .completeTodo(id):
            try fetchTodo(id: id).updateCompletion(true)
        case let .deleteTodo(id):
            modelContext.delete(try fetchTodo(id: id))
        case let .createGroup(_, name, colorHex):
            modelContext.insert(TodoGroup(name: name, colorHex: colorHex, sortOrder: TodoGroupResolver.nextSortOrder(in: try fetchGroups())))
        case let .updateGroup(id, name, colorHex, sortOrder):
            try fetchGroup(id: id).update(name: name, colorHex: colorHex, sortOrder: sortOrder)
        case let .deleteGroup(id):
            try deleteGroup(id: id)
        case let .saveDailySummary(_, content):
            modelContext.insert(DailySummary(content: content))
        }

        try modelContext.save()
    }

    private func fetchTodos() throws -> [TodoItem] {
        try modelContext.fetch(FetchDescriptor<TodoItem>())
    }

    private func fetchDailySummaries() throws -> [DailySummary] {
        try modelContext.fetch(FetchDescriptor<DailySummary>())
    }

    private func fetchGroups() throws -> [TodoGroup] {
        try modelContext.fetch(FetchDescriptor<TodoGroup>())
    }

    private func fetchTodo(id: UUID) throws -> TodoItem {
        let items = try fetchTodos()
        guard let item = items.first(where: { $0.id == id }) else {
            throw AIToolExecutorError.todoNotFound(id)
        }
        return item
    }

    private func fetchGroup(id: UUID) throws -> TodoGroup {
        guard let group = try fetchGroups().first(where: { $0.id == id }) else {
            throw AIToolExecutorError.invalidArguments
        }
        return group
    }

    private func deleteGroup(id: UUID) throws {
        guard id != TodoGroup.defaultGroupID else { throw AIToolExecutorError.invalidArguments }
        let group = try fetchGroup(id: id)
        for item in try fetchTodos() where item.groupID == id {
            item.updateGroup(nil)
        }
        modelContext.delete(group)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum AIToolHandlingResult: Equatable {
    case context(String)
    case proposal(AIActionProposal)
}

private struct ToolArguments {
    private let values: [String: Any]

    init(json: String) throws {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let values = object as? [String: Any] else {
            throw AIToolExecutorError.invalidArguments
        }
        self.values = values
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIToolExecutorError.invalidArguments
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        guard let value = values[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func uuid(_ key: String) throws -> UUID {
        guard let value = values[key] as? String, let uuid = UUID(uuidString: value) else {
            throw AIToolExecutorError.invalidArguments
        }
        return uuid
    }

    func optionalUUID(_ key: String) -> UUID? {
        guard let value = values[key] as? String else { return nil }
        return UUID(uuidString: value)
    }

    func optionalDate(_ key: String) -> Date? {
        guard let value = values[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DateParser.iso8601(value)
    }

    func optionalBool(_ key: String) -> Bool? {
        values[key] as? Bool
    }

    func optionalInt(_ key: String) -> Int? {
        if let value = values[key] as? Int { return value }
        if let value = values[key] as? Double { return Int(value) }
        return nil
    }

    func priority(_ key: String) throws -> TodoPriority {
        guard let priority = optionalPriority(key) else {
            throw AIToolExecutorError.invalidArguments
        }
        return priority
    }

    func optionalPriority(_ key: String) -> TodoPriority? {
        guard let value = values[key] as? String else { return nil }
        return TodoPriority(rawValue: value)
    }
}

private enum DateParser {
    static func iso8601(_ value: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static let formatters: [ISO8601DateFormatter] = {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return [standard, fractional]
    }()
}

private struct AIStatsPayload: Encodable {
    let activeCount: Int
    let completedCount: Int
    let averageCompletionHours: Double?
    let groups: [AITodoGroupSnapshot]
    let dailySummaries: [DailySummarySnapshot]

    init(snapshot: AITodoSnapshot) {
        activeCount = snapshot.stats.activeCount
        completedCount = snapshot.stats.completedCount
        averageCompletionHours = snapshot.stats.averageCompletionInterval.map { $0 / 3_600 }
        groups = snapshot.groups
        dailySummaries = snapshot.dailySummaries
    }
}
