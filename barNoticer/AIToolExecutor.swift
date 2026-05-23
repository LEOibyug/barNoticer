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
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), dailySummaries: try fetchDailySummaries())
            return .context(Self.encode([
                "high": snapshot.activeByPriority[.high] ?? [],
                "medium": snapshot.activeByPriority[.medium] ?? [],
                "low": snapshot.activeByPriority[.low] ?? []
            ]))
        case "list_completed_todos":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), dailySummaries: try fetchDailySummaries())
            return .context(Self.encode(snapshot.completed))
        case "get_completion_stats":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), dailySummaries: try fetchDailySummaries())
            return .context(Self.encode(AIStatsPayload(snapshot: snapshot)))
        case "create_todo":
            return .proposal(.createTodo(title: try arguments.string("title"), priority: try arguments.priority("priority")))
        case "update_todo":
            return .proposal(.updateTodo(
                id: try arguments.uuid("id"),
                title: arguments.optionalString("title"),
                priority: arguments.optionalPriority("priority")
            ))
        case "complete_todo":
            return .proposal(.completeTodo(id: try arguments.uuid("id")))
        case "delete_todo":
            return .proposal(.deleteTodo(id: try arguments.uuid("id")))
        case "save_daily_summary":
            return .proposal(.saveDailySummary(content: try arguments.string("content")))
        default:
            throw AIToolExecutorError.unsupportedTool(toolCall.function.name)
        }
    }

    func apply(_ proposal: AIActionProposal) throws {
        switch proposal {
        case let .createTodo(_, title, priority):
            modelContext.insert(TodoItem(title: title, priority: priority))
        case let .updateTodo(id, title, priority):
            let item = try fetchTodo(id: id)
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                item.updateTitle(title)
            }
            if let priority {
                item.priority = priority
            }
        case let .completeTodo(id):
            try fetchTodo(id: id).updateCompletion(true)
        case let .deleteTodo(id):
            modelContext.delete(try fetchTodo(id: id))
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

    private func fetchTodo(id: UUID) throws -> TodoItem {
        let items = try fetchTodos()
        guard let item = items.first(where: { $0.id == id }) else {
            throw AIToolExecutorError.todoNotFound(id)
        }
        return item
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

private struct AIStatsPayload: Encodable {
    let activeCount: Int
    let completedCount: Int
    let averageCompletionHours: Double?
    let dailySummaries: [DailySummarySnapshot]

    init(snapshot: AITodoSnapshot) {
        activeCount = snapshot.stats.activeCount
        completedCount = snapshot.stats.completedCount
        averageCompletionHours = snapshot.stats.averageCompletionInterval.map { $0 / 3_600 }
        dailySummaries = snapshot.dailySummaries
    }
}
