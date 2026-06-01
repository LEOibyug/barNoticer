import Foundation

struct TodoPriorityGroup: Identifiable {
    let priority: TodoPriority
    let items: [TodoItem]

    var id: TodoPriority { priority }
}

struct TodoDisplayGroup: Identifiable {
    let group: TodoGroup
    let items: [TodoItem]

    var id: UUID { group.id }
}

enum TodoSorter {
    static func sorted(_ items: [TodoItem], groups: [TodoGroup] = [], now: Date = Date()) -> [TodoItem] {
        items.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted {
                return !lhs.isCompleted
            }

            let lhsGroup = TodoGroupResolver.group(for: lhs, groups: groups)
            let rhsGroup = TodoGroupResolver.group(for: rhs, groups: groups)
            if lhsGroup.sortOrder != rhsGroup.sortOrder {
                return lhsGroup.sortOrder < rhsGroup.sortOrder
            }

            let lhsDeadline = lhs.nextOccurrence(after: now)
            let rhsDeadline = rhs.nextOccurrence(after: now)
            let lhsDeadlineRank = deadlineRank(lhsDeadline, now: now)
            let rhsDeadlineRank = deadlineRank(rhsDeadline, now: now)
            if lhsDeadlineRank != rhsDeadlineRank {
                return lhsDeadlineRank < rhsDeadlineRank
            }

            if let lhsDeadline, let rhsDeadline, lhsDeadline != rhsDeadline {
                return lhsDeadline < rhsDeadline
            }

            if lhs.priority.rank != rhs.priority.rank {
                return lhs.priority.rank < rhs.priority.rank
            }

            return lhs.createdAt < rhs.createdAt
        }
    }

    static func priorityGroups(_ items: [TodoItem], now: Date = Date()) -> [TodoPriorityGroup] {
        let sortedItems = sorted(items, now: now)

        return TodoPriority.allCases.compactMap { priority in
            let priorityItems = sortedItems.filter { $0.priority == priority }
            guard !priorityItems.isEmpty else { return nil }

            return TodoPriorityGroup(priority: priority, items: priorityItems)
        }
    }

    static func displayGroups(items: [TodoItem], groups: [TodoGroup], now: Date = Date()) -> [TodoDisplayGroup] {
        let normalizedGroups = TodoGroupResolver.normalizedGroups(groups)
        let sortedItems = sorted(items, groups: normalizedGroups, now: now)

        return normalizedGroups.compactMap { group in
            let groupItems = sortedItems.filter { TodoGroupResolver.group(for: $0, groups: normalizedGroups).id == group.id }
            guard !groupItems.isEmpty else { return nil }
            return TodoDisplayGroup(group: group, items: groupItems)
        }
    }

    private static func deadlineRank(_ deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 3 }
        if deadline < now { return 0 }
        if deadline.timeIntervalSince(now) <= 86_400 { return 1 }
        return 2
    }
}
