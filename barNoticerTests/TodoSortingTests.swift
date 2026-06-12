import XCTest
import SwiftData
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

    func testDefaultGroupHasStableIdentityAndCannotBeDeleted() {
        let defaultGroup = TodoGroup.defaultGroup

        XCTAssertEqual(defaultGroup.id, TodoGroup.defaultGroupID)
        XCTAssertEqual(defaultGroup.name, "默认分组")
        XCTAssertFalse(defaultGroup.canDelete)
    }

    func testReorderingGroupsPersistsSortOrder() {
        let defaultGroup = TodoGroup.defaultGroup
        let home = TodoGroup(name: "生活", sortOrder: 1)
        let work = TodoGroup(name: "工作", sortOrder: 2)
        let study = TodoGroup(name: "学习", sortOrder: 3)

        TodoGroupResolver.moveGroup(in: [defaultGroup, home, work, study], moving: study.id, to: 0)

        let groups = TodoGroupResolver.normalizedGroups([defaultGroup, home, work, study])
        XCTAssertEqual(groups.map(\.name), ["学习", "默认分组", "生活", "工作"])
        XCTAssertEqual(groups.map(\.sortOrder), [0, 1, 2, 3])
    }

    func testMovingEarlierGroupOntoLaterGroupMovesAfterTarget() {
        let defaultGroup = TodoGroup.defaultGroup
        let first = TodoGroup(name: "第一", sortOrder: 1)
        let second = TodoGroup(name: "第二", sortOrder: 2)
        let third = TodoGroup(name: "第三", sortOrder: 3)

        TodoGroupResolver.moveGroup(in: [defaultGroup, first, second, third], moving: first.id, near: third.id)

        let groups = TodoGroupResolver.normalizedGroups([defaultGroup, first, second, third])
        XCTAssertEqual(groups.map(\.name), ["默认分组", "第二", "第三", "第一"])
        XCTAssertEqual(groups.map(\.sortOrder), [0, 1, 2, 3])
    }

    func testMovingLaterGroupOntoEarlierGroupMovesBeforeTarget() {
        let defaultGroup = TodoGroup.defaultGroup
        let first = TodoGroup(name: "第一", sortOrder: 1)
        let second = TodoGroup(name: "第二", sortOrder: 2)
        let third = TodoGroup(name: "第三", sortOrder: 3)

        TodoGroupResolver.moveGroup(in: [defaultGroup, first, second, third], moving: third.id, near: first.id)

        let groups = TodoGroupResolver.normalizedGroups([defaultGroup, first, second, third])
        XCTAssertEqual(groups.map(\.name), ["默认分组", "第三", "第一", "第二"])
        XCTAssertEqual(groups.map(\.sortOrder), [0, 1, 2, 3])
    }

    @MainActor
    func testBootstrapRenamesExistingDefaultGroupFromInbox() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let legacyGroup = TodoGroup(id: TodoGroup.defaultGroupID, name: "收件箱", colorHex: "#3B82F6", sortOrder: 9)
        container.mainContext.insert(legacyGroup)
        try container.mainContext.save()

        TodoGroupBootstrap.ensureDefaultGroup(in: container.mainContext)

        let groups = try container.mainContext.fetch(FetchDescriptor<TodoGroup>())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "默认分组")
        XCTAssertEqual(groups.first?.colorHex, TodoGroup.defaultColorHex)
        XCTAssertEqual(groups.first?.sortOrder, 9)
    }

    func testTodoDisplayGroupsUseDefaultGroupForItemsWithoutGroup() {
        let custom = TodoGroup(name: "工作", colorHex: "#3B82F6", sortOrder: 1)
        let defaultGroupItem = TodoItem(title: "Loose", priority: .medium)
        let workItem = TodoItem(title: "Work", priority: .high, groupID: custom.id)

        let groups = TodoSorter.displayGroups(items: [workItem, defaultGroupItem], groups: [custom])

        XCTAssertEqual(groups.map(\.group.id), [TodoGroup.defaultGroupID, custom.id])
        XCTAssertEqual(groups.first?.items.map(\.title), ["Loose"])
        XCTAssertEqual(groups.last?.items.map(\.title), ["Work"])
    }

    func testDeadlineSortsOverdueAndUpcomingItemsBeforeNoDeadlineWithinGroup() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let noDeadlineHigh = TodoItem(title: "No deadline high", priority: .high, createdAt: now.addingTimeInterval(-300))
        let futureLow = TodoItem(title: "Future low", priority: .low, deadlineAt: now.addingTimeInterval(7_200), createdAt: now.addingTimeInterval(-200))
        let overdueMedium = TodoItem(title: "Overdue medium", priority: .medium, deadlineAt: now.addingTimeInterval(-3_600), createdAt: now.addingTimeInterval(-100))

        let sorted = TodoSorter.sorted([noDeadlineHigh, futureLow, overdueMedium], now: now)

        XCTAssertEqual(sorted.map(\.title), ["Overdue medium", "Future low", "No deadline high"])
    }
}
