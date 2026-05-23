import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID
    var title: String
    var priorityRawValue: String
    var isCompleted: Bool
    var createdAt: Date
    var updatedAt: Date

    var priority: TodoPriority {
        get { TodoPriority(rawValue: priorityRawValue) ?? .medium }
        set {
            priorityRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    func updateTitle(_ newTitle: String) {
        title = newTitle
        updatedAt = Date()
    }

    func updateCompletion(_ completed: Bool) {
        isCompleted = completed
        updatedAt = Date()
    }

    init(
        id: UUID = UUID(),
        title: String,
        priority: TodoPriority = .medium,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.priorityRawValue = priority.rawValue
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
