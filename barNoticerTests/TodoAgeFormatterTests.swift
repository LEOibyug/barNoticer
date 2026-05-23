import XCTest
@testable import barNoticer

final class TodoAgeFormatterTests: XCTestCase {
    func testFormatsItemsWithinOneHour() {
        let now = Date(timeIntervalSince1970: 1_000)
        let createdAt = Date(timeIntervalSince1970: 970)

        XCTAssertEqual(TodoAgeFormatter.elapsedText(since: createdAt, now: now), "一小时内")
        XCTAssertEqual(
            TodoAgeFormatter.elapsedText(since: now.addingTimeInterval(-59 * 60), now: now),
            "一小时内"
        )
    }

    func testFormatsHoursAndDaysWithAgoSuffix() {
        let now = Date(timeIntervalSince1970: 100_000)

        XCTAssertEqual(
            TodoAgeFormatter.elapsedText(since: now.addingTimeInterval(-3 * 60 * 60 - 20 * 60), now: now),
            "3小时20分钟前"
        )
        XCTAssertEqual(
            TodoAgeFormatter.elapsedText(since: now.addingTimeInterval(-2 * 24 * 60 * 60 - 22 * 60 * 60), now: now),
            "2天22小时前"
        )
    }

    func testFormatsLongerDurationsWithAgoSuffix() {
        let now = Date(timeIntervalSince1970: 10_000_000)

        XCTAssertEqual(
            TodoAgeFormatter.elapsedText(since: now.addingTimeInterval(-3 * 7 * 24 * 60 * 60 - 2 * 24 * 60 * 60), now: now),
            "3周2天前"
        )
        XCTAssertEqual(
            TodoAgeFormatter.elapsedText(since: now.addingTimeInterval(-5 * 30 * 24 * 60 * 60 - 3 * 7 * 24 * 60 * 60), now: now),
            "5个月3周前"
        )
        XCTAssertEqual(
            TodoAgeFormatter.elapsedText(since: now.addingTimeInterval(-2 * 365 * 24 * 60 * 60 - 4 * 30 * 24 * 60 * 60), now: now),
            "2年4个月前"
        )
    }
}
