import XCTest
import SwiftData
import SwiftUI
import AppKit
@testable import barNoticer

@MainActor
final class ScheduledReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testCreatingTodoThroughAIStoresReminderInContext() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let call = AIToolCall(id: "create", type: "function", function: .init(name: "create_todo", arguments:
            #"{"title":"提交作业","priority":"high","deadline_at":"2026-10-09T10:00:00Z","reminder_minutes_before":30}"#))
        guard case let .proposal(proposal) = try executor.handle(call) else { return XCTFail("Missing proposal") }
        try executor.apply(proposal)
        let snapshot = AITodoContext.snapshot(items: try container.mainContext.fetch(FetchDescriptor<TodoItem>()), groups: [])
        let data = try JSONEncoder().encode(try XCTUnwrap(snapshot.activeByPriority[.high]?.first))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["reminderMinutesBefore"] as? Int, 30)
    }

    func testAIUpdateCanChangeOrClearReminderWithoutChangingDeadline() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = TodoItem(title: "任务", deadlineAt: now.addingTimeInterval(3_600), reminderMinutesBefore: 30)
        fixture.container.mainContext.insert(item)
        let executor = AIToolExecutor(modelContext: fixture.container.mainContext)
        for json in [#"{"id":"\#(item.id)","reminder_minutes_before":10}"#, #"{"id":"\#(item.id)","clear_reminder":true}"#] {
            let call = AIToolCall(id: "update", type: "function", function: .init(name: "update_todo", arguments: json))
            guard case let .proposal(proposal) = try executor.handle(call) else { return XCTFail("Missing proposal") }
            try executor.apply(proposal)
        }
        XCTAssertNil(item.reminderMinutesBefore)
        XCTAssertEqual(item.deadlineAt, now.addingTimeInterval(3_600))
    }

    func testInvalidReminderValuesAreRejectedAndMissingDeadlineDoesNotInsertTodo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executor = AIToolExecutor(modelContext: fixture.container.mainContext)
        for value in ["-1", "1.5", "true", "525601", "\"30\""] {
            let call = AIToolCall(id: "bad", type: "function", function: .init(name: "create_todo", arguments:
                "{\"title\":\"任务\",\"priority\":\"high\",\"reminder_minutes_before\":\(value)}"))
            XCTAssertThrowsError(try executor.handle(call))
        }
        XCTAssertThrowsError(try executor.apply(.createTodo(title: "无 DDL", priority: .high, reminderMinutesBefore: 30)))
        XCTAssertEqual(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 0)
    }

    func testCustomReminderFiresAtExactBoundaryWithAIPollingOffOnlyOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = TodoItem(title: "交作业", deadlineAt: now.addingTimeInterval(1_800), reminderMinutesBefore: 30)
        fixture.container.mainContext.insert(item)
        fixture.scheduler.refresh(now: now.addingTimeInterval(-0.01))
        XCTAssertTrue(fixture.presenter.deliveries.isEmpty)
        fixture.scheduler.refresh(now: now)
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
        XCTAssertEqual(fixture.presenter.deliveries.first?.todoReferences, [item.id])
        XCTAssertEqual(fixture.presenter.triggers.first, .scheduledDeadline(todoID: item.id, deadline: item.deadlineAt!, minutesBefore: 30))
        fixture.scheduler.refresh(now: now.addingTimeInterval(60))
        fixture.makeScheduler().refresh(now: now.addingTimeInterval(120))
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
    }

    func testAtDeadlineZeroOffsetAndMissedReminderCatchUp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = TodoItem(title: "到点提醒", deadlineAt: now, reminderMinutesBefore: 0)
        fixture.container.mainContext.insert(item)
        fixture.scheduler.refresh(now: now.addingTimeInterval(-1))
        XCTAssertTrue(fixture.presenter.deliveries.isEmpty)
        fixture.scheduler.refresh(now: now.addingTimeInterval(300))
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
        XCTAssertTrue(fixture.presenter.deliveries[0].message.contains("截止"))
    }

    func testCompletedDisabledDeletedAndNonDeadlineTasksDoNotRemind() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let completed = TodoItem(title: "已完成", deadlineAt: now, isCompleted: true, reminderMinutesBefore: 30)
        let disabled = TodoItem(title: "关闭", deadlineAt: now)
        let recurring = TodoItem(title: "重复", recurrenceRule: .daily, recurrenceAnchor: now, reminderMinutesBefore: 30)
        let deleted = TodoItem(title: "已删除", deadlineAt: now, reminderMinutesBefore: 30)
        for item in [completed, disabled, recurring, deleted] { fixture.container.mainContext.insert(item) }
        fixture.container.mainContext.delete(deleted)
        fixture.scheduler.refresh(now: now)
        XCTAssertTrue(fixture.presenter.deliveries.isEmpty)
    }

    func testEditingDeadlineReschedulesAndClearingScheduleRemovesReminder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = TodoItem(title: "修改时间", deadlineAt: now.addingTimeInterval(1_800), reminderMinutesBefore: 30)
        fixture.container.mainContext.insert(item)
        item.updateDeadline(now.addingTimeInterval(3_600))
        fixture.scheduler.refresh(now: now)
        XCTAssertTrue(fixture.presenter.deliveries.isEmpty)
        fixture.scheduler.refresh(now: now.addingTimeInterval(1_800))
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
        item.updateDeadline(now.addingTimeInterval(7_200))
        fixture.scheduler.refresh(now: now.addingTimeInterval(5_400))
        XCTAssertEqual(fixture.presenter.deliveries.count, 2)
        item.clearSchedule()
        XCTAssertNil(item.reminderMinutesBefore)
        XCTAssertNil(TodoScheduledReminder(item: item))
    }

    func testScheduledReminderSettingsAndTriggerRoundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        ReminderSettings(aiPollingEnabled: false, scheduledAIWordingEnabled: true).save(to: fixture.defaults)
        XCTAssertFalse(ReminderSettings(defaults: fixture.defaults).aiPollingEnabled)
        XCTAssertTrue(ReminderSettings(defaults: fixture.defaults).scheduledAIWordingEnabled)
        let trigger = ReminderTrigger.scheduledDeadline(todoID: UUID(), deadline: now, minutesBefore: 90)
        XCTAssertEqual(try JSONDecoder().decode(ReminderTrigger.self, from: JSONEncoder().encode(trigger)), trigger)
        let legacy = #"{"kind":"deadline","todoID":"11111111-1111-1111-1111-111111111111","offset":"oneDay"}"#
        XCTAssertEqual(try JSONDecoder().decode(ReminderTrigger.self, from: Data(legacy.utf8)), .deadline(todoID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, offset: .oneDay))
    }

    func testSlowAIWordingDoesNotBlockTimerAndCannotVetoScheduledReminder() async throws {
        let fixture = try Fixture(aiWording: true)
        defer { fixture.cleanUp() }
        ScheduledWordingURLProtocol.responseDelay = 1
        ScheduledWordingURLProtocol.responseBody = #"{"choices":[{"message":{"content":"{\"should_remind\":false}"}}]}"#
        let start = Date()
        let item = TodoItem(title: "离线也要提醒", deadlineAt: start.addingTimeInterval(0.3), reminderMinutesBefore: 0)
        fixture.container.mainContext.insert(item)
        fixture.scheduler.start()
        for _ in 0..<40 where fixture.presenter.deliveries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
        XCTAssertTrue(fixture.presenter.deliveries.first?.shouldRemind == true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let decision = await fixture.engine.decision(for: .scheduledDeadline(todoID: item.id, deadline: item.deadlineAt!, minutesBefore: 0), settings: ReminderSettings(), now: Date())
        XCTAssertTrue(decision.shouldRemind)
        XCTAssertEqual(decision.todoReferences, [item.id])
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
    }

    func testPreparedAIWordingUsedWithoutCallingAIPolling() async throws {
        let fixture = try Fixture(aiWording: true)
        defer { fixture.cleanUp() }
        ScheduledWordingURLProtocol.responseBody = #"{"choices":[{"message":{"content":"{\"should_remind\":true,\"message\":\"该提交作业啦。\",\"todo_references\":[]}"}}]}"#
        let deadline = Date().addingTimeInterval(1)
        let item = TodoItem(title: "作业", deadlineAt: deadline, reminderMinutesBefore: 0)
        fixture.container.mainContext.insert(item)
        fixture.scheduler.start()
        for _ in 0..<100 where fixture.presenter.deliveries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.presenter.deliveries.first?.message, "该提交作业啦。")
        XCTAssertEqual(fixture.presenter.deliveries.first?.todoReferences, [item.id])
        XCTAssertEqual(ScheduledWordingURLProtocol.requestCount, 1)
    }

    func testChangingMemoryInvalidatesPreparedReminderWording() async throws {
        let fixture = try Fixture(aiWording: true)
        defer { fixture.cleanUp() }
        let memory = AIGlobalMemoryStore(defaults: fixture.defaults)
        try memory.save(key: "称呼", content: "小王", source: .explicit)
        ScheduledWordingURLProtocol.responseBody = #"{"choices":[{"message":{"content":"{\"should_remind\":true,\"message\":\"小王，交作业啦\"}"}}]}"#
        let deadline = Date().addingTimeInterval(60)
        let item = TodoItem(title: "作业", deadlineAt: deadline, reminderMinutesBefore: 0)
        fixture.container.mainContext.insert(item)
        fixture.scheduler.refresh()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ScheduledWordingURLProtocol.requestCount, 1)
        try memory.confirmClear(memory.requestClear())
        fixture.scheduler.refresh(now: deadline)
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
        XCTAssertFalse(fixture.presenter.deliveries[0].message.contains("小王"))
    }

    func testSavingEarlierDeadlineRearmsLiveTimerWithoutWaitingForScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = TodoItem(title: "改早的截止时间", deadlineAt: Date().addingTimeInterval(3_600), reminderMinutesBefore: 0)
        fixture.container.mainContext.insert(item)
        try fixture.container.mainContext.save()
        fixture.scheduler.start()
        item.updateDeadline(Date().addingTimeInterval(0.3))
        try fixture.container.mainContext.save()
        for _ in 0..<75 where fixture.presenter.deliveries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.presenter.deliveries.count, 1)
    }

    func testReminderDeliveryMarkerSurvivesStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderPersistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        let id = UUID()
        do {
            let container = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self, configurations: configuration)
            let item = TodoItem(id: id, title: "已提醒", deadlineAt: now, reminderMinutesBefore: 10)
            container.mainContext.insert(item)
            item.lastDeliveredReminderKey = try XCTUnwrap(TodoScheduledReminder(item: item)).key
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self, configurations: configuration)
        let item = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<TodoItem>()).first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.reminderMinutesBefore, 10)
        XCTAssertNil(TodoScheduledReminder(item: item))
    }

    func testReminderEditorDisplaysSavedHoursAndRenders() async throws {
        let host = NSHostingView(rootView: TodoReminderEditor(minutesBefore: .constant(120)).padding(20).background(Color.white).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 430, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        XCTAssertTrue(fields(in: host).contains { $0.stringValue == "2" })
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Task reminder editor"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNoPendingRemindersLeavesNoArmedTimer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.scheduler.start()
        // 无待提醒事项且无重试时不装周期兜底 timer，等待数据事件唤醒。
        XCTAssertFalse(fixture.scheduler.isTimerArmed)

        let item = TodoItem(title: "未来事项", deadlineAt: now.addingTimeInterval(1_800), reminderMinutesBefore: 10)
        fixture.container.mainContext.insert(item)
        fixture.scheduler.refresh(now: now)
        XCTAssertTrue(fixture.scheduler.isTimerArmed)

        fixture.container.mainContext.delete(item)
        try fixture.container.mainContext.save()
        fixture.scheduler.refresh(now: now)
        XCTAssertFalse(fixture.scheduler.isTimerArmed)
    }

    func testAITimersFollowPollingToggleIndependentlyOfScheduledReminders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = ReminderScheduler(
            modelContext: fixture.container.mainContext,
            engine: fixture.engine,
            presenter: ReminderPresenter(modelContext: fixture.container.mainContext, historyStore: ReminderHistoryStore(), defaults: fixture.defaults),
            historyStore: ReminderHistoryStore(),
            defaults: fixture.defaults
        )
        // AI 关闭：AI 轮询与默认 DDL 扫描 timer 均不存在；用户主动定时提醒仍继续运行。
        scheduler.start()
        XCTAssertFalse(scheduler.aiTimersArmed)

        ReminderSettings(aiPollingEnabled: true, systemNotificationsEnabled: false, scheduledAIWordingEnabled: false).save(to: fixture.defaults)
        XCTAssertTrue(scheduler.aiTimersArmed)

        ReminderSettings(aiPollingEnabled: false, systemNotificationsEnabled: false, scheduledAIWordingEnabled: false).save(to: fixture.defaults)
        XCTAssertFalse(scheduler.aiTimersArmed)
    }

    private final class Fixture {
        let suite = "ScheduledReminderTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let container: ModelContainer
        let engine: AIReminderEngine
        let presenter = RecordingScheduledPresenter()
        lazy var scheduler = makeScheduler()

        init(aiWording: Bool = false) throws {
            defaults = UserDefaults(suiteName: suite)!
            ReminderSettings(aiPollingEnabled: false, systemNotificationsEnabled: false, scheduledAIWordingEnabled: aiWording).save(to: defaults)
            AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model").save(to: defaults)
            let keyStore = AIAPIKeyStore(defaults: defaults)
            keyStore.saveAPIKey("test")
            ScheduledWordingURLProtocol.responseDelay = 0
            ScheduledWordingURLProtocol.requestCount = 0
            container = try TestSupport.makeInMemoryContainer()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ScheduledWordingURLProtocol.self]
            engine = AIReminderEngine(modelContext: container.mainContext,
                                      client: AIClient(session: URLSession(configuration: config)),
                                      apiKeyStore: keyStore, defaults: defaults)
        }

        func makeScheduler() -> ScheduledReminderScheduler {
            ScheduledReminderScheduler(modelContext: container.mainContext, presenter: presenter, engine: engine, defaults: defaults)
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}

@MainActor
private final class RecordingScheduledPresenter: ReminderPresenting {
    var deliveries: [ReminderDecision] = []
    var triggers: [ReminderTrigger] = []
    func present(decision: ReminderDecision, trigger: ReminderTrigger, settings: ReminderSettings, timestamp: Date) {
        deliveries.append(decision)
        triggers.append(trigger)
    }
}

private final class ScheduledWordingURLProtocol: URLProtocol {
    static var responseBody = #"{"choices":[{"message":{"content":"{\"should_remind\":false}"}}]}"#
    static var responseDelay: TimeInterval = 0
    static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let body = Self.responseBody
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseDelay) { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
