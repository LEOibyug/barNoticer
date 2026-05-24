import Foundation
import SwiftData

@MainActor
final class AIReminderEngine {
    private let modelContext: ModelContext
    private let client: AIClient
    private let apiKeyStore: AIAPIKeyStore
    private let historyStore: ReminderHistoryStore
    private let logStore: AppDebugLogStore

    init(
        modelContext: ModelContext,
        client: AIClient = AIClient(),
        apiKeyStore: AIAPIKeyStore = .shared,
        historyStore: ReminderHistoryStore = ReminderHistoryStore(),
        logStore: AppDebugLogStore = .shared
    ) {
        self.modelContext = modelContext
        self.client = client
        self.apiKeyStore = apiKeyStore
        self.historyStore = historyStore
        self.logStore = logStore
    }

    func decision(for trigger: ReminderTrigger, settings: ReminderSettings, now: Date = Date()) async -> ReminderDecision {
        do {
            let snapshot = try ReminderSnapshotBuilder.make(modelContext: modelContext, now: now)
            let context = ReminderContext(
                now: now,
                timeZone: .current,
                todos: snapshot.todos,
                groups: snapshot.groups,
                history: historyStore.recentEntries(now: now),
                tone: settings.tone
            )
            let aiSettings = AISettings(defaults: .standard)
            let apiKey = apiKeyStore.readAPIKey()
            let messages = AIReminderPromptBuilder.messages(context: context, trigger: trigger)
            logReminderChat(role: "Prompt", content: messages.compactMap(\.content).joined(separator: "\n"))
            let result = try await client.sendReadOnly(
                messages: messages,
                settings: aiSettings,
                apiKey: apiKey
            )
            logReminderChat(role: "Assistant", content: result.content)
            let decision = try ReminderDecisionParser.parse(result.content)
            log(.info, "AI reminder decision", metadata: ["trigger": trigger.key, "shouldRemind": "\(decision.shouldRemind)"])
            return decision
        } catch {
            log(.error, "AI reminder failed", metadata: ["trigger": trigger.key, "error": error.localizedDescription])
            guard case let .deadline(todoID, _) = trigger,
                  let fallback = fallbackDecision(for: todoID)
            else {
                return ReminderDecision(shouldRemind: false, message: "", todoReferences: [], snoozeSuggestion: nil)
            }
            return fallback
        }
    }

    private func fallbackDecision(for todoID: UUID) -> ReminderDecision? {
        guard let item = (try? modelContext.fetch(FetchDescriptor<TodoItem>()))?.first(where: { $0.id == todoID }) else {
            return nil
        }
        return ReminderDecision(
            shouldRemind: true,
            message: "\(item.title) 接近截止时间了。",
            todoReferences: [todoID],
            snoozeSuggestion: 1_800
        )
    }

    private func log(_ level: AppDebugLogStore.Level, _ message: String, metadata: [String: String] = [:]) {
        try? logStore.write(level, category: "Reminder", message: message, metadata: metadata)
    }

    private func logReminderChat(role: String, content: String) {
        try? logStore.write(.info, category: "ReminderAI", message: role, metadata: ["content": content])
    }
}

enum AIReminderPromptBuilder {
    static func messages(context: ReminderContext, trigger: ReminderTrigger) -> [AIChatMessage] {
        [
            AIChatMessage(role: "system", content: systemPrompt(tone: context.tone)),
            AIChatMessage(role: "user", content: userContext(context: context, trigger: trigger))
        ]
    }

    private static func systemPrompt(tone: ReminderTone) -> String {
        """
        你是 barNoticer 的提醒判断器，只能决定是否提醒和生成提醒文案。
        你不能创建、修改、删除或完成事项，不能调用工具，也不能要求用户确认操作。
        输出必须是 JSON 对象，不要使用 Markdown，不要输出 JSON 以外的内容。
        格式：{"should_remind":true,"message":"提醒文案，可包含 [[todo:<UUID>]] 引用","todo_references":["UUID"],"snooze_minutes":30}
        如果不需要提醒，输出 {"should_remind":false,"message":"","todo_references":[]}
        文案风格：\(tone.promptDescription)
        如果文案引用了事项，只放 [[todo:<UUID>]] 标记，不要在标记旁重复事项标题和重要性。
        """
    }

    private static func userContext(context: ReminderContext, trigger: ReminderTrigger) -> String {
        var lines = [
            "触发来源：\(trigger.title)",
            "当前日期时间：\(iso8601(context.now))",
            "时区：\(timeZoneDescription(context.timeZone))",
            "相对日期描述必须以当前日期时间为基准。",
            "全部事项："
        ]

        for todo in context.todos {
            let deadline = todo.deadlineAt.map(iso8601) ?? "none"
            let next = todo.nextOccurrenceAt.map(iso8601) ?? "none"
            let recurrence = todo.recurrenceRule?.rawValue ?? "none"
            let status = todo.isCompleted ? "completed" : "active"
            lines.append("- id=\(todo.id.uuidString) title=\(todo.title) priority=\(todo.priority.rawValue) group=\(todo.groupName) status=\(status) scheduleKind=\(todo.scheduleKind.rawValue) deadlineAt=\(deadline) recurrenceRule=\(recurrence) nextOccurrenceAt=\(next) createdAt=\(iso8601(todo.createdAt)) updatedAt=\(iso8601(todo.updatedAt))")
        }

        lines.append("分组：")
        lines.append(contentsOf: context.groups.map { "- id=\($0.id.uuidString) name=\($0.name) color=\($0.colorHex) sortOrder=\($0.sortOrder)" })

        lines.append("近期提醒历史：")
        if context.history.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: context.history.map { entry in
                let refs = entry.referencedTodoIDs.map(\.uuidString).joined(separator: ",")
                return "- at=\(iso8601(entry.timestamp)) trigger=\(entry.trigger.key) shouldRemind=\(entry.decision.shouldRemind) refs=\(refs) status=\(entry.status.rawValue) message=\(entry.decision.message)"
            })
        }

        return lines.joined(separator: "\n")
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func timeZoneDescription(_ timeZone: TimeZone) -> String {
        let seconds = timeZone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}

enum ReminderDecisionParser {
    static func parse(_ text: String) throws -> ReminderDecision {
        let data = Data(extractJSONObject(from: text).utf8)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return ReminderDecision(
            shouldRemind: decoded.shouldRemind,
            message: decoded.message ?? "",
            todoReferences: (decoded.todoReferences ?? []).compactMap(UUID.init(uuidString:)),
            snoozeSuggestion: decoded.snoozeMinutes.map { TimeInterval($0) * 60 }
        )
    }

    private static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return text
        }
        return String(text[start...end])
    }

    private struct Payload: Decodable {
        let shouldRemind: Bool
        let message: String?
        let todoReferences: [String]?
        let snoozeMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case shouldRemind = "should_remind"
            case message
            case todoReferences = "todo_references"
            case snoozeMinutes = "snooze_minutes"
        }
    }
}

enum ReminderDeadlinePolicy {
    static func dueTriggers(
        for todos: [ReminderTodoSnapshot],
        now: Date = Date(),
        history: ReminderHistoryStore,
        dedupeWindow: TimeInterval
    ) -> [ReminderTrigger] {
        todos.flatMap { todo -> [ReminderTrigger] in
            guard !todo.isCompleted, let deadline = todo.nextOccurrenceAt else { return [] }
            let remaining = deadline.timeIntervalSince(now)
            let matchingOffsets = [ReminderDeadlineOffset.twelveHours, .oneDay].filter { offset in
                remaining > 0 && remaining <= offset.timeInterval
            }
            guard let offset = matchingOffsets.first else { return [] }
            let trigger = ReminderTrigger.deadline(todoID: todo.id, offset: offset)
            guard !history.hasRecentTrigger(trigger, now: now, dedupeWindow: max(dedupeWindow, offset.timeInterval - remaining + 1)) else {
                return []
            }
            return [trigger]
        }
    }
}

private extension AIClient {
    func sendReadOnly(messages: [AIChatMessage], settings: AISettings, apiKey: String) async throws -> AIChatResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.missingAPIKey
        }
        guard settings.isValid else { throw AIClientError.invalidSettings }
        let request = try AIChatRequestBuilder.make(messages: messages, settings: settings, apiKey: apiKey, tools: [])
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AIClientError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(AIReadOnlyChatResponse.self, from: data)
        guard let message = decoded.choices.first?.message else { throw AIClientError.invalidResponse }
        return AIChatResult(content: message.content ?? "", reasoningContent: message.reasoningContent, toolCalls: [])
    }
}

private struct AIReadOnlyChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
            var reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        var message: Message
    }

    var choices: [Choice]
}
