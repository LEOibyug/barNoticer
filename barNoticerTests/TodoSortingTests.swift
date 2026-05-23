import XCTest
@testable import barNoticer

final class TodoSortingTests: XCTestCase {
    func testUnfinishedItemsSortBeforeFinishedThenPriorityThenCreationDate() {
        let now = Date()
        let oldLow = TodoItem(title: "Old low", priority: .low, createdAt: now.addingTimeInterval(-300))
        let newestHigh = TodoItem(title: "Newest high", priority: .high, createdAt: now.addingTimeInterval(-60))
        let oldestMedium = TodoItem(title: "Oldest medium", priority: .medium, createdAt: now.addingTimeInterval(-600))
        let finishedHigh = TodoItem(title: "Finished high", priority: .high, isCompleted: true, createdAt: now.addingTimeInterval(-900))

        let sorted = TodoSorter.sorted([oldLow, newestHigh, oldestMedium, finishedHigh])

        XCTAssertEqual(sorted.map(\.title), ["Newest high", "Oldest medium", "Old low", "Finished high"])
    }

    func testPriorityGroupsOnlyIncludeNonEmptyPrioritiesInImportanceOrder() {
        let now = Date()
        let low = TodoItem(title: "Low", priority: .low, createdAt: now.addingTimeInterval(-100))
        let high = TodoItem(title: "High", priority: .high, createdAt: now.addingTimeInterval(-50))
        let anotherHigh = TodoItem(title: "Another high", priority: .high, createdAt: now.addingTimeInterval(-200))

        let groups = TodoSorter.priorityGroups([low, high, anotherHigh])

        XCTAssertEqual(groups.map(\.priority), [.high, .low])
        XCTAssertEqual(groups.first?.items.map(\.title), ["Another high", "High"])
        XCTAssertEqual(groups.last?.items.map(\.title), ["Low"])
    }
}
