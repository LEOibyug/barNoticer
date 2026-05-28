import XCTest
@testable import barNoticer

final class TodoDeadlineFormatterTests: XCTestCase {
    func testFormatsRemainingTimeWithinOneHour() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = now.addingTimeInterval(45 * 60)

        XCTAssertEqual(TodoDeadlineFormatter.remainingText(until: deadline, now: now), "剩余一小时内")
    }

    func testFormatsRemainingHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            TodoDeadlineFormatter.remainingText(until: now.addingTimeInterval(3 * 3_600 + 20 * 60), now: now),
            "剩余3小时"
        )
        XCTAssertEqual(
            TodoDeadlineFormatter.remainingText(until: now.addingTimeInterval(2 * 86_400 + 3 * 3_600), now: now),
            "剩余2天3小时"
        )
    }

    func testFormatsOverdueDuration() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            TodoDeadlineFormatter.remainingText(until: now.addingTimeInterval(-2 * 3_600), now: now),
            "已逾期2小时"
        )
    }

    func testCombinesDeadlineAndRemainingTimeForCards() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = now.addingTimeInterval(2 * 3_600)

        let text = TodoDeadlineFormatter.cardText(for: deadline, now: now)

        XCTAssertTrue(text.contains("DDL"))
        XCTAssertTrue(text.contains("剩余2小时"))
    }

    func testCompletedSingleDeadlineTodoDoesNotShowOverdueCardText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TodoItem(
            title: "已交作业",
            deadlineAt: now.addingTimeInterval(-2 * 3_600),
            isCompleted: true
        )

        XCTAssertNil(TodoDeadlineFormatter.cardText(for: item, now: now))
    }
}
