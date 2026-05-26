import XCTest
import SwiftData
@testable import barNoticer

final class ReminderEngineTests: XCTestCase {
    func testDeadlinePolicyEmitsOneDayAndTwelveHourTriggersOnce() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let suiteName = "ReminderDeadlineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let todo = ReminderTodoSnapshot(
            id: id,
            title: "写 v4 说明",
            priority: .high,
            groupID: TodoGroup.defaultGroupID,
            groupName: "默认分组",
            deadlineAt: now.addingTimeInterval(86_400 - 60),
            isCompleted: false,
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-1_800)
        )
        let history = ReminderHistoryStore(defaults: defaults)

        let first = ReminderDeadlinePolicy.dueTriggers(for: [todo], now: now, history: history, dedupeWindow: 1_800)
        XCTAssertEqual(first, [.deadline(todoID: id, offset: .oneDay)])

        history.record(ReminderHistoryEntry(trigger: .deadline(todoID: id, offset: .oneDay), decision: .init(shouldRemind: true, message: "提醒", todoReferences: [id], snoozeSuggestion: nil), timestamp: now))
        let duplicate = ReminderDeadlinePolicy.dueTriggers(for: [todo], now: now.addingTimeInterval(300), history: history, dedupeWindow: 1_800)
        XCTAssertTrue(duplicate.isEmpty)

        let twelveHourTodo = ReminderTodoSnapshot(
            id: id,
            title: "写 v4 说明",
            priority: .high,
            groupID: TodoGroup.defaultGroupID,
            groupName: "默认分组",
            deadlineAt: now.addingTimeInterval(43_200 - 30),
            isCompleted: false,
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-1_800)
        )
        let twelveHour = ReminderDeadlinePolicy.dueTriggers(for: [twelveHourTodo], now: now, history: history, dedupeWindow: 1_800)
        XCTAssertEqual(twelveHour, [.deadline(todoID: id, offset: .twelveHours)])
    }

    func testDeadlinePolicyUsesNextOccurrenceForScheduledTodos() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let suiteName = "ReminderOccurrenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let todo = ReminderTodoSnapshot(
            id: id,
            title: "重复提醒",
            priority: .high,
            groupID: TodoGroup.defaultGroupID,
            groupName: "默认分组",
            deadlineAt: nil,
            nextOccurrenceAt: now.addingTimeInterval(43_200 - 30),
            scheduleKind: .multipleTimes,
            recurrenceRule: nil,
            isCompleted: false,
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-1_800)
        )
        let history = ReminderHistoryStore(defaults: defaults)

        let triggers = ReminderDeadlinePolicy.dueTriggers(for: [todo], now: now, history: history, dedupeWindow: 1_800)

        XCTAssertEqual(triggers, [.deadline(todoID: id, offset: .twelveHours)])
    }

    func testReminderPromptIncludesTimeTodosHistoryAndReadOnlyBoundary() {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let now = Date(timeIntervalSince1970: 2_000_000)
        let context = ReminderContext(
            now: now,
            timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!,
            todos: [
                ReminderTodoSnapshot(
                    id: id,
                    title: "复盘提醒系统",
                    priority: .medium,
                    groupID: TodoGroup.defaultGroupID,
                    groupName: "默认分组",
                    deadlineAt: now.addingTimeInterval(3_600),
                    isCompleted: false,
                    createdAt: now.addingTimeInterval(-7_200),
                    updatedAt: now.addingTimeInterval(-3_600)
                )
            ],
            groups: [ReminderGroupSnapshot(id: TodoGroup.defaultGroupID, name: "默认分组", colorHex: "#6B7280", sortOrder: 0)],
            history: [
                ReminderHistoryEntry(trigger: .aiPoll, decision: .init(shouldRemind: false, message: "", todoReferences: [], snoozeSuggestion: nil), timestamp: now.addingTimeInterval(-600))
            ],
            tone: .professional
        )

        let messages = AIReminderPromptBuilder.messages(context: context, trigger: .aiPoll)
        let joined = messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(joined.contains("当前本地时间："))
        XCTAssertTrue(joined.contains("当前 ISO8601："))
        XCTAssertTrue(joined.contains("时区：GMT+08:00"))
        XCTAssertTrue(joined.contains("deadlineLocal="))
        XCTAssertTrue(joined.contains("nextOccurrenceLocal="))
        XCTAssertTrue(joined.contains(id.uuidString))
        XCTAssertTrue(joined.contains("复盘提醒系统"))
        XCTAssertTrue(joined.contains("近期提醒历史"))
        XCTAssertTrue(joined.contains("只能决定是否提醒"))
        XCTAssertTrue(joined.contains("不能创建、修改、删除或完成事项"))
    }

    func testReminderDecisionParserReadsJSONAndReferences() throws {
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let decision = try ReminderDecisionParser.parse("""
        {"should_remind":true,"message":"该看一眼截止任务了 [[todo:\(id.uuidString)]]","todo_references":["\(id.uuidString)"],"snooze_minutes":25}
        """)

        XCTAssertTrue(decision.shouldRemind)
        XCTAssertEqual(decision.message, "该看一眼截止任务了 [[todo:\(id.uuidString)]]")
        XCTAssertEqual(decision.todoReferences, [id])
        XCTAssertEqual(decision.snoozeSuggestion, 1_500)
    }

    @MainActor
    func testReminderEngineWritesPromptAndReplyToDebugLog() async throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suiteName = "ReminderLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model").save(to: defaults)
        let keyStore = AIAPIKeyStore(defaults: defaults)
        keyStore.saveAPIKey("test-api-key")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderLogTests-\(UUID().uuidString)")
        let logStore = AppDebugLogStore(directory: directory)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ReminderDecisionURLProtocol.self]
        ReminderDecisionURLProtocol.responseBody = #"{"choices":[{"message":{"content":"{\"should_remind\":false,\"message\":\"\",\"todo_references\":[]}"}}]}"#

        let engine = AIReminderEngine(
            modelContext: container.mainContext,
            client: AIClient(session: URLSession(configuration: sessionConfiguration)),
            apiKeyStore: keyStore,
            historyStore: ReminderHistoryStore(defaults: defaults),
            logStore: logStore
        )

        _ = await engine.decision(for: .aiPoll, settings: ReminderSettings(), now: Date(timeIntervalSince1970: 2_000_000))

        let content = try String(contentsOf: logStore.logFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[ReminderAI] Prompt"))
        XCTAssertTrue(content.contains("[ReminderAI] Assistant"))
        XCTAssertTrue(content.contains("should_remind"))
    }

    func testReminderPanelContentSeparatesMessageFromReferenceCards() {
        let first = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let second = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!

        let content = ReminderPanelContent.from(message: "这两件该处理了：[[todo:\(first.uuidString)]]、[[todo:\(second.uuidString)]]")

        XCTAssertEqual(content.message, "这两件该处理了：")
        XCTAssertEqual(content.todoReferences, [first, second])
    }

    @MainActor
    func testReminderEngineFallsBackForDeadlineWhenAIUnavailable() async throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suiteName = "ReminderFallbackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        container.mainContext.insert(TodoItem(id: id, title: "马上截止", priority: .high, deadlineAt: Date().addingTimeInterval(3_600)))
        let engine = AIReminderEngine(
            modelContext: container.mainContext,
            client: AIClient(session: URLSession(configuration: .ephemeral)),
            apiKeyStore: AIAPIKeyStore(defaults: defaults)
        )

        let decision = await engine.decision(for: .deadline(todoID: id, offset: .twelveHours), settings: ReminderSettings(), now: Date())

        XCTAssertTrue(decision.shouldRemind)
        XCTAssertTrue(decision.message.contains("马上截止"))
        XCTAssertEqual(decision.todoReferences, [id])
    }
}

private final class ReminderDecisionURLProtocol: URLProtocol {
    static var responseBody = #"{"choices":[{"message":{"content":"{\"should_remind\":false,\"message\":\"\",\"todo_references\":[]}"}}]}"#

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let data = Data(Self.responseBody.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
