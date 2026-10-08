import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class TodoScheduleDraftTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try TestSupport.makeInMemoryContainer()
        context = container.mainContext
    }

    func testEditingFirstOfFourScheduledTimesKeepsTheOtherThree() throws {
        let times = [
            Date.now.addingTimeInterval(1_800),
            Date.now.addingTimeInterval(3_600),
            Date.now.addingTimeInterval(7_200),
            Date.now.addingTimeInterval(86_400)
        ]
        let item = TodoItem(title: "多次提醒", scheduledTimes: times)
        context.insert(item)
        try context.save()

        var draft = TodoScheduleDraft(item: item)
        XCTAssertEqual(draft.scheduledTimes.count, 4)
        draft.scheduledTimes[0] = draft.scheduledTimes[0].addingTimeInterval(600)

        let outcome = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(item.scheduledTimes.count, 4)
        XCTAssertEqual(item.scheduledTimes, draft.scheduledTimes)
    }

    func testUnchangedCommitDoesNotTouchScheduleOrReminderRecords() throws {
        let anchor = Date.now.addingTimeInterval(-3_600)
        let item = TodoItem(title: "每天喝水", recurrenceRule: .daily, recurrenceAnchor: anchor)
        context.insert(item)
        item.completeCurrentOccurrence()
        try context.save()
        let progressBefore = item.lastCompletedOccurrenceAt
        let updatedAtBefore = item.updatedAt

        var draft = TodoScheduleDraft(item: item)
        XCTAssertFalse(draft.hasChanges)
        let outcome = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(item.lastCompletedOccurrenceAt, progressBefore)
        XCTAssertEqual(item.updatedAt, updatedAtBefore)
        XCTAssertNil(item.reminderMinutesBefore)
    }

    func testReminderOnlyEditDoesNotRewriteSchedule() throws {
        let item = TodoItem(title: "交报告", deadlineAt: Date.now.addingTimeInterval(86_400))
        context.insert(item)
        try context.save()
        let updatedAtBefore = item.updatedAt

        var draft = TodoScheduleDraft(item: item)
        draft.reminderMinutesBefore = 60
        let outcome = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(item.reminderMinutesBefore, 60)
        XCTAssertEqual(item.deadlineAt != nil, true)
        XCTAssertNotEqual(item.updatedAt, updatedAtBefore)
    }

    func testSwitchingDeadlineToOtherKindClearsReminder() throws {
        let item = TodoItem(
            title: "订机票",
            deadlineAt: Date.now.addingTimeInterval(43_200),
            reminderMinutesBefore: 30
        )
        context.insert(item)
        try context.save()

        var draft = TodoScheduleDraft(item: item)
        draft.kind = .multipleTimes
        let outcome = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        XCTAssertEqual(outcome, .saved)
        XCTAssertNil(item.reminderMinutesBefore)
        XCTAssertNil(item.deadlineAt)
        XCTAssertEqual(item.scheduleKind, .multipleTimes)
    }

    func testConcurrentEditOfSameFieldConflictsWhileUnrelatedFieldIsKept() throws {
        let item = TodoItem(title: "旧标题", deadlineAt: Date.now.addingTimeInterval(86_400))
        context.insert(item)
        try context.save()

        var draft = TodoScheduleDraft(item: item)
        draft.deadline = draft.deadline.addingTimeInterval(1_800)

        // 同一字段被外部修改且结果不同 → 冲突。
        item.updateSchedule(deadlineAt: item.deadlineAt!.addingTimeInterval(9_000))
        let conflict = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        guard case let .conflict(fields) = conflict else {
            return XCTFail("预期冲突，实际 \(conflict)")
        }
        XCTAssertEqual(fields, ["日程"])

        // 覆盖保存应用用户编辑。
        let forced = TodoScheduleCommitter.commit(&draft, into: item, context: context, force: true)
        XCTAssertEqual(forced, .saved)
        XCTAssertEqual(item.deadlineAt, draft.deadline)
    }

    func testUnrelatedExternalChangeDoesNotConflictAndExternalValueIsKept() throws {
        let item = TodoItem(title: "旧标题", deadlineAt: Date.now.addingTimeInterval(86_400), reminderMinutesBefore: 30)
        context.insert(item)
        try context.save()

        var draft = TodoScheduleDraft(item: item)
        draft.reminderMinutesBefore = 60
        // 外部只改了标题：与用户编辑的提醒字段无重叠。
        item.updateTitle("新标题")

        let outcome = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(item.title, "新标题")
        XCTAssertEqual(item.reminderMinutesBefore, 60)
    }

    func testCommittingIntoDeletedItemReportsDeletion() throws {
        let item = TodoItem(title: "将删除", deadlineAt: Date.now.addingTimeInterval(86_400))
        context.insert(item)
        try context.save()

        var draft = TodoScheduleDraft(item: item)
        context.delete(item)
        try context.save()

        let outcome = TodoScheduleCommitter.commit(&draft, into: item, context: context)
        XCTAssertEqual(outcome, .itemDeleted)
    }

    func testStaleRecurringEditorDoesNotRestoreCancelledReminder() throws {
        let item = TodoItem(title: "周期", recurrenceRule: .daily,
            recurrenceAnchor: Date.now, reminderMinutesBefore: 30)
        context.insert(item)
        try context.save()
        var draft = TodoScheduleDraft(item: item)
        item.updateReminder(minutesBefore: nil) // AI cancels while the editor remains open.
        try context.save()
        draft.recurrenceRule = .weekly
        XCTAssertEqual(TodoScheduleCommitter.commit(&draft, into: item, context: context), .saved)
        XCTAssertNil(item.reminderMinutesBefore)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(TodoScheduleCommitter.commit(&draft, into: item, context: context), .saved)
        XCTAssertNil(item.reminderMinutesBefore)
    }

    func testAutomaticCompletionDraftEnablesCatchUpAndPersistsWithoutResettingProgress() throws {
        let anchor = Date().addingTimeInterval(-40 * 86_400)
        let item = TodoItem(title: "积压周期", recurrenceRule: .weekly, recurrenceAnchor: anchor, reminderMinutesBefore: 60)
        context.insert(item)
        try context.save()
        var draft = TodoScheduleDraft(item: item)
        XCTAssertFalse(draft.automaticallyCompletes)
        draft.automaticallyCompletes = true
        XCTAssertEqual(TodoScheduleCommitter.commit(&draft, into: item, context: context), .saved)
        XCTAssertTrue(item.automaticallyCompletes)
        XCTAssertGreaterThan(item.nextOccurrence()!, Date())
        let progress = item.lastCompletedOccurrenceAt
        XCTAssertNotNil(progress)
        XCTAssertEqual(item.reminderMinutesBefore, 60)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(TodoScheduleCommitter.commit(&draft, into: item, context: context), .saved)
        XCTAssertEqual(item.lastCompletedOccurrenceAt, progress)
    }

    func testDraftWithSingleScheduledTimePadsToTwoEditableTimes() throws {
        // scheduledTimes 经 ISO8601 编解码，测试时间点使用整秒避免亚秒精度差异。
        let only = Date(timeIntervalSince1970: 1_800)
        let item = TodoItem(title: "单个时间点", scheduledTimes: [only])
        let draft = TodoScheduleDraft(item: item)
        XCTAssertEqual(draft.scheduledTimes, [only, only.addingTimeInterval(3_600)])
    }
}
