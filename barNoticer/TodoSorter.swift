import Foundation

struct TodoPriorityGroup: Identifiable {
    let priority: TodoPriority
    let items: [TodoItem]

    var id: TodoPriority { priority }
}

enum TodoSorter {
    static func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted {
                return !lhs.isCompleted
            }

            if lhs.priority.rank != rhs.priority.rank {
                return lhs.priority.rank < rhs.priority.rank
            }

            return lhs.createdAt < rhs.createdAt
        }
    }

    static func priorityGroups(_ items: [TodoItem]) -> [TodoPriorityGroup] {
        let sortedItems = sorted(items)

        return TodoPriority.allCases.compactMap { priority in
            let priorityItems = sortedItems.filter { $0.priority == priority }
            guard !priorityItems.isEmpty else { return nil }

            return TodoPriorityGroup(priority: priority, items: priorityItems)
        }
    }
}
