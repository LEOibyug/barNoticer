import Foundation

struct TodoScheduledReminder: Equatable {
    static let maximumMinutes = 525_600
    let todoID: UUID
    let deadline: Date
    let minutesBefore: Int

    var fireDate: Date { deadline.addingTimeInterval(-TimeInterval(minutesBefore) * 60) }
    var key: String { "\(todoID.uuidString):\(deadline.timeIntervalSince1970):\(minutesBefore)" }
    var trigger: ReminderTrigger { .scheduledDeadline(todoID: todoID, deadline: deadline, minutesBefore: minutesBefore) }

    init?(item: TodoItem) {
        guard !item.isCompleted, [.singleDeadline, .recurring].contains(item.scheduleKind),
              let deadline = item.deferredAutomaticReminderAt ?? item.pendingOccurrence(), let minutes = item.reminderMinutesBefore,
              (0...Self.maximumMinutes).contains(minutes) else { return nil }
        self.todoID = item.id
        self.deadline = deadline
        self.minutesBefore = minutes
        guard item.lastDeliveredReminderKey != key else { return nil }
    }

    static func label(minutes: Int) -> String {
        if minutes == 0 { return "DDL 到点提醒" }
        if minutes % 1_440 == 0 { return "DDL 前 \(minutes / 1_440) 天提醒" }
        if minutes % 60 == 0 { return "DDL 前 \(minutes / 60) 小时提醒" }
        return "DDL 前 \(minutes) 分钟提醒"
    }

    func fallback(now: Date) -> ReminderDecision {
        let message = now >= deadline ? "这项任务已到截止时间，请及时查看。" : "到了你设置的提醒时间，别忘了这项任务。"
        return ReminderDecision(shouldRemind: true, message: message, todoReferences: [todoID], snoozeSuggestion: nil)
    }
}
