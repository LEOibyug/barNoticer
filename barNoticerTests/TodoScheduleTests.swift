import XCTest
@testable import barNoticer

final class TodoScheduleTests: XCTestCase {
    func testMultipleTimesUseNearestUpcomingOccurrence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TodoItem(
            title: "多次服药",
            priority: .high,
            scheduledTimes: [
                now.addingTimeInterval(-3_600),
                now.addingTimeInterval(7_200),
                now.addingTimeInterval(1_800)
            ]
        )

        XCTAssertEqual(item.scheduleKind, .multipleTimes)
        XCTAssertEqual(item.nextOccurrence(after: now), now.addingTimeInterval(1_800))
        let cardText = TodoDeadlineFormatter.cardText(for: item, now: now)
        XCTAssertTrue(cardText?.hasPrefix("下次 ") == true)
        XCTAssertTrue(cardText?.contains("剩余一小时内") == true)
    }

    func testRecurringTodoCompletesCurrentOccurrenceAndRollsForward() {
        let calendar = Calendar(identifier: .gregorian)
        let now = ISO8601DateFormatter().date(from: "2026-05-24T10:00:00Z")!
        let anchor = ISO8601DateFormatter().date(from: "2026-05-24T09:00:00Z")!
        let item = TodoItem(title: "每日站会", recurrenceRule: .daily, recurrenceAnchor: anchor)

        XCTAssertEqual(item.scheduleKind, .recurring)
        XCTAssertEqual(item.nextOccurrence(after: now), calendar.date(byAdding: .day, value: 1, to: anchor))

        item.completeCurrentOccurrence(now: now)

        XCTAssertFalse(item.isCompleted)
        XCTAssertEqual(item.lastCompletedOccurrenceAt, calendar.date(byAdding: .day, value: 1, to: anchor))
        XCTAssertEqual(item.nextOccurrence(after: now), calendar.date(byAdding: .day, value: 2, to: anchor))
    }

    func testMonthlyRecurringClampsToValidDayInShortMonth() {
        let anchor = ISO8601DateFormatter().date(from: "2026-01-31T09:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
        let item = TodoItem(title: "月底结账", recurrenceRule: .monthly, recurrenceAnchor: anchor)

        let next = item.nextOccurrence(after: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.month, .day, .hour], from: next!)

        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 28)
        XCTAssertEqual(components.hour, 9)
    }

    func testCustomDailyRecurringUsesConfiguredDayInterval() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = ISO8601DateFormatter().date(from: "2026-05-24T09:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-05-25T10:00:00Z")!
        let item = TodoItem(title: "隔三天复盘", recurrenceRule: .everyNDays(3), recurrenceAnchor: anchor)

        XCTAssertEqual(item.scheduleKind, .recurring)
        XCTAssertEqual(item.recurrenceRuleRawValue, "every_n_days:3")
        XCTAssertEqual(item.recurrenceRule, .everyNDays(3))
        XCTAssertEqual(item.nextOccurrence(after: now), calendar.date(byAdding: .day, value: 3, to: anchor))

        item.completeCurrentOccurrence(now: now)

        XCTAssertEqual(item.lastCompletedOccurrenceAt, calendar.date(byAdding: .day, value: 3, to: anchor))
        XCTAssertEqual(item.nextOccurrence(after: now), calendar.date(byAdding: .day, value: 6, to: anchor))
    }

    func testCustomDailyRecurrenceRejectsInvalidIntervals() {
        XCTAssertNil(TodoRecurrenceRule(rawValue: "every_n_days:0"))
        XCTAssertNil(TodoRecurrenceRule(rawValue: "every_n_days:-2"))
    }
}
