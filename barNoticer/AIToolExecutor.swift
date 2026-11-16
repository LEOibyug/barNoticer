import Foundation
import SwiftData

enum AIToolExecutorError: LocalizedError {
    case invalidArguments
    case invalidArgument(String)
    case unsupportedTool(String)
    case todoNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "AI 工具参数无效"
        case let .invalidArgument(detail):
            return "AI 工具参数无效：\(detail)"
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
    private let memoryStore: AIGlobalMemoryStore
    private let summaryStore: SummaryStore

    init(modelContext: ModelContext, memoryStore: AIGlobalMemoryStore? = nil, summaryStore: SummaryStore? = nil) {
        self.modelContext = modelContext
        self.memoryStore = memoryStore ?? .shared
        self.summaryStore = summaryStore ?? .shared
    }

    func handle(_ toolCall: AIToolCall) throws -> AIToolHandlingResult {
        let arguments = try ToolArguments(json: toolCall.function.arguments, toolName: toolCall.function.name)

        switch toolCall.function.name {
        case "read_global_memory":
            return .context(try memoryStore.toolContent())
        case "save_global_memory":
            guard let source = AIGlobalMemoryEntry.Source(rawValue: try arguments.string("source")) else {
                throw AIToolExecutorError.invalidArguments
            }
            try memoryStore.save(key: arguments.string("key"), content: arguments.string("content"), source: source)
            return .memoryUpdated("全局记忆已保存。")
        case "clear_global_memory":
            let snapshot = try memoryStore.read()
            guard !snapshot.entries.isEmpty else { return .context("全局记忆已经为空，无需清空。") }
            return .proposal(.clearGlobalMemory(revision: snapshot.revision))
        case "list_active_todos":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), groups: try fetchGroups())
            return .context(Self.encode(snapshot.activeByGroup))
        case "list_completed_todos":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), groups: try fetchGroups())
            return .context(Self.encode(snapshot.completed))
        case "get_completion_stats":
            let snapshot = AITodoContext.snapshot(items: try fetchTodos(), groups: try fetchGroups(), summaries: summaryStore.summaries)
            return .context(Self.encode(AIStatsPayload(snapshot: snapshot)))
        case "list_groups":
            return .context(Self.encode(TodoGroupResolver.normalizedGroups(try fetchGroups()).map(AITodoGroupSnapshot.init(group:))))
        case "create_todo":
            return .proposal(.createTodo(
                title: try arguments.string("title"),
                note: arguments.optionalRawString("note"),
                priority: try arguments.priority("priority"),
                groupID: arguments.optionalUUID("group_id"),
                deadlineAt: arguments.optionalDate("deadline_at"),
                scheduledTimes: arguments.optionalDates("scheduled_times"),
                recurrenceRule: arguments.optionalRecurrenceRule("recurrence_rule", intervalDaysKey: "recurrence_interval_days"),
                recurrenceAnchor: arguments.optionalDate("recurrence_anchor"),
                reminderMinutesBefore: try arguments.reminderMinutes()
            ))
        case "update_todo":
            return .proposal(.updateTodo(id: try arguments.uuid("id"), changes: AITodoUpdate(
                title: arguments.optionalString("title"),
                note: arguments.optionalRawString("note"),
                priority: arguments.optionalPriority("priority"),
                groupID: arguments.optionalUUID("group_id"),
                clearsGroup: arguments.optionalBool("clear_group") ?? false,
                deadlineAt: arguments.optionalDate("deadline_at"),
                scheduledTimes: arguments.optionalDateArray("scheduled_times"),
                recurrenceRule: arguments.optionalRecurrenceRule("recurrence_rule", intervalDaysKey: "recurrence_interval_days"),
                recurrenceIntervalDays: arguments.optionalInt("recurrence_interval_days"),
                recurrenceAnchor: arguments.optionalDate("recurrence_anchor"),
                clearsNote: arguments.optionalBool("clear_note") ?? false,
                clearsDeadline: arguments.optionalBool("clear_deadline") ?? false,
                clearsSchedule: arguments.optionalBool("clear_schedule") ?? false,
                reminderMinutesBefore: try arguments.reminderMinutes(),
                clearsReminder: arguments.optionalBool("clear_reminder") ?? false,
                automaticallyCompletes: arguments.optionalBool("automatically_completes"),
                isCompleted: arguments.optionalBool("is_completed"),
                createdAt: arguments.optionalDate("created_at"),
                updatedAt: arguments.optionalDate("updated_at"),
                lastCompletedOccurrenceAt: arguments.optionalDate("last_completed_occurrence_at"),
                clearsLastCompletedOccurrence: arguments.optionalBool("clear_last_completed_occurrence") ?? false
            )))
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
        case "prepare_summary":
            let start = try arguments.date("period_start")
            let end = try arguments.date("period_end")
            guard end > start else {
                throw AIToolExecutorError.invalidArgument("period_end 必须晚于 period_start；时间段为 [period_start, period_end)。")
            }
            return .proposal(.saveSummary(
                title: try arguments.string("title"),
                periodStart: start,
                periodEnd: end,
                content: try arguments.string("content")
            ))
        default:
            throw AIToolExecutorError.unsupportedTool(toolCall.function.name)
        }
    }

    @discardableResult
    func apply(_ proposal: AIActionProposal) throws -> AIActionApplicationResult {
        switch proposal {
        case .clearGlobalMemory:
            throw AIGlobalMemoryError.confirmationRequired
        case let .createTodo(id, title, note, priority, groupID, deadlineAt, scheduledTimes, recurrenceRule, recurrenceAnchor, reminderMinutes):
            if reminderMinutes != nil {
                let validSchedule = (deadlineAt != nil && recurrenceRule == nil && recurrenceAnchor == nil)
                    || (deadlineAt == nil && recurrenceRule != nil && recurrenceAnchor != nil)
                guard validSchedule, scheduledTimes.isEmpty,
                      (0...TodoScheduledReminder.maximumMinutes).contains(reminderMinutes!) else {
                    throw AIToolExecutorError.invalidArguments
                }
            }
            modelContext.insert(TodoItem(
                id: id,
                title: title,
                note: note,
                priority: priority,
                groupID: groupID,
                deadlineAt: deadlineAt,
                scheduledTimes: scheduledTimes,
                recurrenceRule: recurrenceRule,
                recurrenceAnchor: recurrenceAnchor,
                reminderMinutesBefore: reminderMinutes
            ))
            try modelContext.save()
            return .createdTodo(id: id, title: title)
        case let .updateTodo(id, changes):
            try applyUpdate(changes, to: fetchTodo(id: id))
            try modelContext.save()
            return .updatedTodo(id: id)
        case let .completeTodo(id):
            try fetchTodo(id: id).completeCurrentOccurrence()
            try modelContext.save()
            return .completedTodo(id: id)
        case let .deleteTodo(id):
            modelContext.delete(try fetchTodo(id: id))
            try modelContext.save()
            return .deletedTodo(id: id)
        case let .createGroup(id, name, colorHex):
            modelContext.insert(TodoGroup(id: id, name: name, colorHex: colorHex, sortOrder: TodoGroupResolver.nextSortOrder(in: try fetchGroups())))
            try modelContext.save()
            return .createdGroup(id: id, name: name)
        case let .updateGroup(id, name, colorHex, sortOrder):
            try fetchGroup(id: id).update(name: name, colorHex: colorHex, sortOrder: sortOrder)
            try modelContext.save()
            return .updatedGroup(id: id)
        case let .deleteGroup(id):
            try deleteGroup(id: id)
            try modelContext.save()
            return .deletedGroup(id: id)
        case let .saveSummary(id, title, periodStart, periodEnd, content):
            let savedAt = summaryStore.summaries.first(where: { $0.id == id })?.createdAt ?? Date()
            try summaryStore.save(SavedSummary(
                id: id, title: title, periodStart: periodStart, periodEnd: periodEnd,
                content: content, createdAt: savedAt
            ))
            return .savedSummary(id: id, title: title)
        }
    }

    private func applyUpdate(_ changes: AITodoUpdate, to item: TodoItem) throws {
        let previousSchedule = TodoSchedulePayload(item: item)
        let schedule = try updatedSchedule(changes, current: previousSchedule)
        let supportsReminder = schedule.kind == .singleDeadline || schedule.kind == .recurring
        if let minutes = changes.reminderMinutesBefore {
            guard supportsReminder, !changes.clearsReminder,
                  (0...TodoScheduledReminder.maximumMinutes).contains(minutes) else {
                throw AIToolExecutorError.invalidArgument("reminder_minutes_before 需要单次 DDL 或重复计划，且不能与 clear_reminder 同时设置。")
            }
        }
        if changes.automaticallyCompletes == true || changes.lastCompletedOccurrenceAt != nil || changes.clearsLastCompletedOccurrence {
            guard schedule.kind == .recurring else {
                throw AIToolExecutorError.invalidArgument("自动完成和周期完成进度需要有效的重复计划。")
            }
        }
        guard !(changes.clearsNote && changes.note != nil),
              !(changes.clearsGroup && changes.groupID != nil),
              !(changes.clearsLastCompletedOccurrence && changes.lastCompletedOccurrenceAt != nil) else {
            throw AIToolExecutorError.invalidArgument("同一字段不能同时设置新值并清空。")
        }

        // 全部检查通过后再改模型，避免错误参数留下部分修改。
        if let title = changes.title { item.updateTitle(title) }
        if let note = changes.note { item.updateNote(note) }
        if changes.clearsNote { item.updateNote(nil) }
        if let priority = changes.priority { item.priority = priority }
        if let groupID = changes.groupID { item.updateGroup(groupID) }
        if changes.clearsGroup { item.updateGroup(nil) }
        if schedule != previousSchedule {
            switch schedule {
            case .none: item.clearSchedule()
            case let .single(deadline): item.updateSchedule(deadlineAt: deadline)
            case let .multiple(times): item.updateSchedule(scheduledTimes: times)
            case let .recurring(rule, anchor): item.updateSchedule(recurrenceRule: rule, recurrenceAnchor: anchor)
            }
        }
        if let minutes = changes.reminderMinutesBefore { item.updateReminder(minutesBefore: minutes) }
        if changes.clearsReminder { item.updateReminder(minutesBefore: nil) }
        // 暂停整项先于自动推进；恢复则在关闭自动完成之后，避免意外补齐历史周期。
        if changes.isCompleted == true { item.updateCompletion(true) }
        if let automatic = changes.automaticallyCompletes, automatic != item.automaticallyCompletes {
            item.updateAutomaticCompletion(automatic)
        }
        if changes.isCompleted == false { item.updateCompletion(false) }
        if changes.lastCompletedOccurrenceAt != nil || changes.clearsLastCompletedOccurrence {
            item.lastCompletedOccurrenceAt = changes.lastCompletedOccurrenceAt
            item.lastDeliveredReminderKey = nil
            item.deferredAutomaticReminderAt = nil
        }
        if let createdAt = changes.createdAt { item.createdAt = createdAt }
        item.updatedAt = changes.updatedAt ?? Date()
    }

    private func updatedSchedule(_ changes: AITodoUpdate, current: TodoSchedulePayload) throws -> TodoSchedulePayload {
        let changesRecurrence = changes.recurrenceRule != nil || changes.recurrenceAnchor != nil || changes.recurrenceIntervalDays != nil
        let scheduleCount = (changes.deadlineAt != nil ? 1 : 0) + (changes.scheduledTimes != nil ? 1 : 0) + (changesRecurrence ? 1 : 0)
        let clearsSchedule = changes.clearsDeadline || changes.clearsSchedule
        guard scheduleCount <= 1, !(clearsSchedule && scheduleCount > 0) else {
            throw AIToolExecutorError.invalidArgument("只能设置一种时间计划，不能同时设置和清除计划。")
        }
        if clearsSchedule { return .none }
        if let deadline = changes.deadlineAt { return .single(deadline) }
        if let times = changes.scheduledTimes { return times.isEmpty ? .none : .multiple(times) }
        if changesRecurrence {
            var rule = changes.recurrenceRule
            var anchor = changes.recurrenceAnchor
            if case let .recurring(previousRule, previousAnchor) = current {
                rule = rule ?? previousRule
                anchor = anchor ?? previousAnchor
            }
            guard var rule, let anchor else {
                throw AIToolExecutorError.invalidArgument("重复计划需要 recurrence_rule 和 recurrence_anchor；修改时可省略已有字段。")
            }
            if let days = changes.recurrenceIntervalDays {
                guard rule.intervalDays != nil, days > 0 else {
                    throw AIToolExecutorError.invalidArgument("recurrence_interval_days 仅适用于 every_n_days，且必须为正整数。")
                }
                rule = .everyNDays(days)
            }
            return .recurring(rule, anchor)
        }
        return current
    }

    private func fetchTodos() throws -> [TodoItem] {
        try modelContext.fetch(FetchDescriptor<TodoItem>())
    }

    private func fetchGroups() throws -> [TodoGroup] {
        try modelContext.fetch(FetchDescriptor<TodoGroup>())
    }

    private func fetchTodo(id: UUID) throws -> TodoItem {
        guard let item = try AITodoLookup.todo(id: id, in: modelContext) else {
            throw AIToolExecutorError.todoNotFound(id)
        }
        return item
    }

    private func fetchGroup(id: UUID) throws -> TodoGroup {
        var descriptor = FetchDescriptor<TodoGroup>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let group = try modelContext.fetch(descriptor).first else {
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
    case memoryUpdated(String)
    case proposal(AIActionProposal)
}

enum AIActionApplicationResult: Equatable {
    case createdTodo(id: UUID, title: String)
    case updatedTodo(id: UUID)
    case completedTodo(id: UUID)
    case deletedTodo(id: UUID)
    case createdGroup(id: UUID, name: String)
    case updatedGroup(id: UUID)
    case deletedGroup(id: UUID)
    case savedSummary(id: UUID, title: String)

    var toolMessage: String {
        switch self {
        case let .createdTodo(id, title):
            return "操作已执行：新增事项 id=\(id.uuidString)，引用标记=[[todo:\(id.uuidString)]]，标题=\(title)。如果接下来要展示或提到这个新事项，必须使用这个引用标记。"
        case let .updatedTodo(id):
            return "操作已执行：修改事项 id=\(id.uuidString)，引用标记=[[todo:\(id.uuidString)]]。"
        case let .completedTodo(id):
            return "操作已执行：完成事项 id=\(id.uuidString)，引用标记=[[todo:\(id.uuidString)]]。"
        case let .deletedTodo(id):
            return "操作已执行：删除事项 id=\(id.uuidString)。"
        case let .createdGroup(id, name):
            return "操作已执行：新增分组 id=\(id.uuidString)，名称=\(name)。"
        case let .updatedGroup(id):
            return "操作已执行：修改分组 id=\(id.uuidString)。"
        case let .deletedGroup(id):
            return "操作已执行：删除分组 id=\(id.uuidString)。"
        case let .savedSummary(id, title):
            return "操作已执行：已保存总结《\(title)》，id=\(id.uuidString)，可在主页面的总结列表查看。"
        }
    }
}

private struct ToolArguments {
    private let values: [String: Any]

    init(json: String, toolName: String) throws {
        guard let definition = AIToolSchema.openAICompatibleTools.first(where: { $0.function.name == toolName }) else {
            throw AIToolExecutorError.unsupportedTool(toolName)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw AIToolExecutorError.invalidArgument("arguments 必须是完整的 JSON 对象。")
        }
        guard let values = object as? [String: Any] else {
            throw AIToolExecutorError.invalidArgument("arguments 必须是 JSON 对象，不能是数组或字符串。")
        }
        guard case let .object(schema) = definition.function.parameters,
              case let .object(properties) = schema["properties"] else {
            throw AIToolExecutorError.invalidArguments
        }
        if case let .array(required) = schema["required"] {
            for case let .string(key) in required where values[key] == nil || values[key] is NSNull {
                throw AIToolExecutorError.invalidArgument("缺少必填字段 \(key)。")
            }
        }
        for key in values.keys.sorted() {
            guard let schema = properties[key] else {
                throw AIToolExecutorError.invalidArgument("未知字段 \(key)，请使用工具定义中的字段。")
            }
            if let value = values[key], !(value is NSNull) {
                try Self.validate(value, schema: schema, key: key)
            }
        }
        if values["recurrence_rule"] as? String == "every_n_days", values["recurrence_interval_days"] == nil || values["recurrence_interval_days"] is NSNull {
            throw AIToolExecutorError.invalidArgument("every_n_days 需要 recurrence_interval_days（正整数）。")
        }
        self.values = values
    }

    private static func validate(_ value: Any, schema: JSONValue, key: String) throws {
        guard case let .object(fields) = schema else { return }
        func invalid(_ expected: String) -> AIToolExecutorError {
            .invalidArgument("\(key) 必须是\(expected)。")
        }
        switch fields["type"] {
        case .string("string"):
            guard let text = value as? String else { throw invalid("字符串") }
            if case let .array(options) = fields["enum"], !options.contains(.string(text)) {
                let allowed = options.compactMap { if case let .string(option) = $0 { return option }; return nil }
                throw invalid(allowed.joined(separator: " / "))
            }
            if ["id", "group_id"].contains(key), UUID(uuidString: text) == nil { throw invalid("UUID 字符串") }
            if ["deadline_at", "recurrence_anchor", "period_start", "period_end", "created_at", "updated_at", "last_completed_occurrence_at"].contains(key), DateParser.iso8601(text) == nil {
                throw invalid("带时区的 ISO8601 日期时间")
            }
            if key == "scheduled_times[]", DateParser.iso8601(text) == nil { throw invalid("带时区的 ISO8601 日期时间") }
        case .string("integer"):
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) else { throw invalid("整数") }
            if case let .number(minimum) = fields["minimum"], number.doubleValue < minimum { throw invalid("不小于 \(minimum) 的整数") }
            if case let .number(maximum) = fields["maximum"], number.doubleValue > maximum { throw invalid("不大于 \(maximum) 的整数") }
        case .string("boolean"):
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("布尔值 true / false") }
        case .string("array"):
            guard let items = value as? [Any] else { throw invalid("数组") }
            if let itemSchema = fields["items"] {
                for item in items { try validate(item, schema: itemSchema, key: key + "[]") }
            }
        default: break
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIToolExecutorError.invalidArgument("\(key) 必须是非空字符串。")
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        guard let value = values[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func optionalRawString(_ key: String) -> String? {
        values[key] as? String
    }

    func uuid(_ key: String) throws -> UUID {
        guard let value = values[key] as? String, let uuid = UUID(uuidString: value) else {
            throw AIToolExecutorError.invalidArgument("\(key) 必须是 UUID 字符串。")
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

    func date(_ key: String) throws -> Date {
        guard let date = optionalDate(key) else {
            throw AIToolExecutorError.invalidArgument("\(key) 必须是带时区的 ISO8601 日期时间。")
        }
        return date
    }

    func optionalDates(_ key: String) -> [Date] {
        guard let values = values[key] as? [String] else { return [] }
        return values.compactMap(DateParser.iso8601).sorted()
    }

    func optionalDateArray(_ key: String) -> [Date]? {
        guard values[key] is [String] else { return nil }
        return optionalDates(key)
    }

    func optionalBool(_ key: String) -> Bool? {
        values[key] as? Bool
    }

    func optionalInt(_ key: String) -> Int? {
        if let value = values[key] as? Int { return value }
        if let value = values[key] as? Double { return Int(value) }
        return nil
    }

    func reminderMinutes() throws -> Int? {
        guard let value = values["reminder_minutes_before"], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (0...Double(TodoScheduledReminder.maximumMinutes)).contains(number.doubleValue) else {
            throw AIToolExecutorError.invalidArguments
        }
        return number.intValue
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

    func optionalRecurrenceRule(_ key: String, intervalDaysKey: String) -> TodoRecurrenceRule? {
        guard let value = values[key] as? String else { return nil }
        if value == "every_n_days" {
            guard let days = optionalInt(intervalDaysKey), days > 0 else { return nil }
            return .everyNDays(days)
        }
        return TodoRecurrenceRule(rawValue: value)
    }
}

private nonisolated enum DateParser {
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
    let summaries: [SavedSummary]

    init(snapshot: AITodoSnapshot) {
        activeCount = snapshot.stats.activeCount
        completedCount = snapshot.stats.completedCount
        averageCompletionHours = snapshot.stats.averageCompletionInterval.map { $0 / 3_600 }
        groups = snapshot.groups
        summaries = snapshot.summaries
    }
}
