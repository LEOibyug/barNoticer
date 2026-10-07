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
    /// 比较键顺序固定：未完成优先 → 分组顺序 → 逾期/24 小时内/更远/无时间 → 具体时间 → 重要性 → 创建时间。
    /// 排序前构造一次分组索引并给每个事项只计算一次 nextOccurrence，
    /// 避免比较器内反复规范化分组和重复解码日程。
    static func sorted(_ items: [TodoItem], groups: [TodoGroup] = [], now: Date = Date()) -> [TodoItem] {
        guard items.count > 1 else { return items }

        let groupIndex = TodoGroupResolver.indexedByID(groups)
        let decorated = items.map { item in
            DecoratedItem(
                item: item,
                groupSortOrder: groupIndex[TodoGroupResolver.groupID(for: item, index: groupIndex)]?.sortOrder ?? 0,
                deadline: item.nextOccurrence(after: now),
                now: now
            )
        }

        return decorated.sorted(by: <).map(\.item)
    }

    static func priorityGroups(_ items: [TodoItem], now: Date = Date()) -> [TodoPriorityGroup] {
        // 重要性视图不继承自定义分组顺序。
        let sortedItems = sorted(items, now: now)

        return TodoPriority.allCases.compactMap { priority in
            let priorityItems = sortedItems.filter { $0.priority == priority }
            guard !priorityItems.isEmpty else { return nil }

            return TodoPriorityGroup(priority: priority, items: priorityItems)
        }
    }

    /// 排序一次后按分组分桶，不再每个分组从头全量筛选。
    static func displayGroups(items: [TodoItem], groups: [TodoGroup], now: Date = Date()) -> [TodoDisplayGroup] {
        let normalizedGroups = TodoGroupResolver.normalizedGroups(groups)
        let sortedItems = sorted(items, groups: normalizedGroups, now: now)
        let groupIndex = TodoGroupResolver.indexedByID(normalizedGroups)

        var buckets: [UUID: [TodoItem]] = [:]
        for item in sortedItems {
            let groupID = TodoGroupResolver.groupID(for: item, index: groupIndex)
            buckets[groupID, default: []].append(item)
        }

        return normalizedGroups.compactMap { group in
            guard let groupItems = buckets[group.id], !groupItems.isEmpty else { return nil }
            return TodoDisplayGroup(group: group, items: groupItems)
        }
    }

    static func deadlineRank(_ deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 3 }
        if deadline < now { return 0 }
        if deadline.timeIntervalSince(now) <= 86_400 { return 1 }
        return 2
    }

    /// 全序排序键；字典序比较即得完整排序规则。
    private struct DecoratedItem: Comparable {
        let item: TodoItem
        let groupSortOrder: Int
        let deadline: Date?
        let now: Date

        static func < (lhs: DecoratedItem, rhs: DecoratedItem) -> Bool {
            if lhs.item.isCompleted != rhs.item.isCompleted {
                return !lhs.item.isCompleted
            }
            if lhs.groupSortOrder != rhs.groupSortOrder {
                return lhs.groupSortOrder < rhs.groupSortOrder
            }

            let lhsRank = TodoSorter.deadlineRank(lhs.deadline, now: lhs.now)
            let rhsRank = TodoSorter.deadlineRank(rhs.deadline, now: rhs.now)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            switch (lhs.deadline, rhs.deadline) {
            case let (l?, r?) where l != r:
                return l < r
            default:
                break
            }

            if lhs.item.priority.rank != rhs.item.priority.rank {
                return lhs.item.priority.rank < rhs.item.priority.rank
            }
            return lhs.item.createdAt < rhs.item.createdAt
        }
    }
}
