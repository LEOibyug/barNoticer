import Foundation

struct IslandQuickAddDraft {
    var title = ""
    var priority: TodoPriority = .medium
    var groupID: UUID?
    var deadlineAt: Date?

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        !trimmedTitle.isEmpty
    }

    mutating func clearTitle() {
        title = ""
        deadlineAt = nil
    }
}
