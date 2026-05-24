import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID
    var title: String
    var priorityRawValue: String
    var groupID: UUID?
    var deadlineAt: Date?
    var scheduledTimesData: Data?
    var recurrenceRuleRawValue: String?
    var recurrenceAnchor: Date?
    var lastCompletedOccurrenceAt: Date?
    var isCompleted: Bool
    var createdAt: Date
    var updatedAt: Date

    var scheduleKind: TodoScheduleKind {
        if recurrenceRule != nil, recurrenceAnchor != nil {
            return .recurring
        }
        if !scheduledTimes.isEmpty {
            return .multipleTimes
        }
        if deadlineAt != nil {
            return .singleDeadline
        }
        return .none
    }

    var recurrenceRule: TodoRecurrenceRule? {
        get {
            guard let recurrenceRuleRawValue else { return nil }
            return TodoRecurrenceRule(rawValue: recurrenceRuleRawValue)
        }
        set {
            recurrenceRuleRawValue = newValue?.rawValue
            updatedAt = Date()
        }
    }

    var scheduledTimes: [Date] {
        get {
            guard let scheduledTimesData,
                  let dates = try? JSONDecoder.iso8601Decoder.decode([Date].self, from: scheduledTimesData)
            else { return [] }
            return dates.sorted()
        }
        set {
            let sorted = newValue.sorted()
            scheduledTimesData = sorted.isEmpty ? nil : try? JSONEncoder.iso8601Encoder.encode(sorted)
            updatedAt = Date()
        }
    }

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

    func completeCurrentOccurrence(now: Date = Date()) {
        guard scheduleKind == .recurring, let occurrence = nextOccurrence(after: now.addingTimeInterval(-1)) else {
            updateCompletion(true)
            return
        }
        lastCompletedOccurrenceAt = occurrence
        isCompleted = false
        updatedAt = Date()
    }

    func updateGroup(_ groupID: UUID?) {
        self.groupID = groupID == TodoGroup.defaultGroupID ? nil : groupID
        updatedAt = Date()
    }

    func updateDeadline(_ deadlineAt: Date?) {
        self.deadlineAt = deadlineAt
        if deadlineAt != nil {
            scheduledTimesData = nil
            recurrenceRuleRawValue = nil
            recurrenceAnchor = nil
            lastCompletedOccurrenceAt = nil
        }
        updatedAt = Date()
    }

    func updateSchedule(
        deadlineAt: Date? = nil,
        scheduledTimes: [Date] = [],
        recurrenceRule: TodoRecurrenceRule? = nil,
        recurrenceAnchor: Date? = nil,
        clearsSchedule: Bool = false
    ) {
        if clearsSchedule {
            self.deadlineAt = nil
            self.scheduledTimesData = nil
            self.recurrenceRuleRawValue = nil
            self.recurrenceAnchor = nil
            self.lastCompletedOccurrenceAt = nil
            updatedAt = Date()
            return
        }

        self.deadlineAt = deadlineAt
        self.scheduledTimesData = scheduledTimes.isEmpty ? nil : try? JSONEncoder.iso8601Encoder.encode(scheduledTimes.sorted())
        self.recurrenceRuleRawValue = recurrenceRule?.rawValue
        self.recurrenceAnchor = recurrenceAnchor
        if recurrenceRule == nil {
            self.lastCompletedOccurrenceAt = nil
        }
        updatedAt = Date()
    }

    func nextOccurrence(after now: Date = Date()) -> Date? {
        TodoSchedulePolicy.nextOccurrence(
            deadlineAt: deadlineAt,
            scheduledTimes: scheduledTimes,
            recurrenceRule: recurrenceRule,
            recurrenceAnchor: recurrenceAnchor,
            lastCompletedOccurrenceAt: lastCompletedOccurrenceAt,
            after: now
        )
    }

    var displayDeadlineAt: Date? {
        nextOccurrence()
    }

    var hasSchedule: Bool {
        scheduleKind != .none
    }

    func clearSchedule() {
        deadlineAt = nil
        scheduledTimesData = nil
        recurrenceRuleRawValue = nil
        recurrenceAnchor = nil
        lastCompletedOccurrenceAt = nil
        updatedAt = Date()
    }

    init(
        id: UUID = UUID(),
        title: String,
        priority: TodoPriority = .medium,
        groupID: UUID? = nil,
        deadlineAt: Date? = nil,
        scheduledTimes: [Date] = [],
        recurrenceRule: TodoRecurrenceRule? = nil,
        recurrenceAnchor: Date? = nil,
        lastCompletedOccurrenceAt: Date? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.priorityRawValue = priority.rawValue
        self.groupID = groupID == TodoGroup.defaultGroupID ? nil : groupID
        self.deadlineAt = deadlineAt
        self.scheduledTimesData = scheduledTimes.isEmpty ? nil : try? JSONEncoder.iso8601Encoder.encode(scheduledTimes.sorted())
        self.recurrenceRuleRawValue = recurrenceRule?.rawValue
        self.recurrenceAnchor = recurrenceAnchor
        self.lastCompletedOccurrenceAt = lastCompletedOccurrenceAt
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
