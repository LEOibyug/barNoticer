import Foundation
import SwiftData

enum ReminderDeadlineOffset: String, Codable, Equatable {
    case oneDay
    case twelveHours

    var timeInterval: TimeInterval {
        switch self {
        case .oneDay:
            return 86_400
        case .twelveHours:
            return 43_200
        }
    }

    var title: String {
        switch self {
        case .oneDay:
            return "提前 1 天"
        case .twelveHours:
            return "提前 12 小时"
        }
    }
}

enum ReminderTrigger: Codable, Equatable {
    case deadline(todoID: UUID, offset: ReminderDeadlineOffset)
    case aiPoll

    var key: String {
        switch self {
        case let .deadline(todoID, offset):
            return "deadline:\(todoID.uuidString):\(offset.rawValue)"
        case .aiPoll:
            return "aiPoll"
        }
    }

    var title: String {
        switch self {
        case let .deadline(_, offset):
            return "DDL \(offset.title)"
        case .aiPoll:
            return "AI 轮询"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case todoID
        case offset
    }

    enum Kind: String, Codable {
        case deadline
        case aiPoll
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .deadline:
            self = .deadline(
                todoID: try container.decode(UUID.self, forKey: .todoID),
                offset: try container.decode(ReminderDeadlineOffset.self, forKey: .offset)
            )
        case .aiPoll:
            self = .aiPoll
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .deadline(todoID, offset):
            try container.encode(Kind.deadline, forKey: .kind)
            try container.encode(todoID, forKey: .todoID)
            try container.encode(offset, forKey: .offset)
        case .aiPoll:
            try container.encode(Kind.aiPoll, forKey: .kind)
        }
    }
}

struct ReminderDecision: Codable, Equatable {
    var shouldRemind: Bool
    var message: String
    var todoReferences: [UUID]
    var snoozeSuggestion: TimeInterval?
}

struct ReminderHistoryEntry: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case delivered
        case dismissed
        case snoozed
        case skipped
    }

    var id: UUID = UUID()
    var trigger: ReminderTrigger
    var decision: ReminderDecision
    var referencedTodoIDs: [UUID]
    var timestamp: Date
    var status: Status

    init(
        id: UUID = UUID(),
        trigger: ReminderTrigger,
        decision: ReminderDecision,
        referencedTodoIDs: [UUID]? = nil,
        timestamp: Date = Date(),
        status: Status = .delivered
    ) {
        self.id = id
        self.trigger = trigger
        self.decision = decision
        self.referencedTodoIDs = referencedTodoIDs ?? decision.todoReferences
        self.timestamp = timestamp
        self.status = status
    }
}

struct ReminderTodoSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let priority: TodoPriority
    let groupID: UUID
    let groupName: String
    let deadlineAt: Date?
    let nextOccurrenceAt: Date?
    let scheduleKind: TodoScheduleKind
    let recurrenceRule: TodoRecurrenceRule?
    let isCompleted: Bool
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID,
        title: String,
        priority: TodoPriority,
        groupID: UUID,
        groupName: String,
        deadlineAt: Date?,
        nextOccurrenceAt: Date? = nil,
        scheduleKind: TodoScheduleKind = .singleDeadline,
        recurrenceRule: TodoRecurrenceRule? = nil,
        isCompleted: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.groupID = groupID
        self.groupName = groupName
        self.deadlineAt = deadlineAt
        self.nextOccurrenceAt = nextOccurrenceAt ?? deadlineAt
        self.scheduleKind = scheduleKind
        self.recurrenceRule = recurrenceRule
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    @MainActor
    init(item: TodoItem, group: TodoGroup) {
        self.init(
            id: item.id,
            title: item.title,
            priority: item.priority,
            groupID: group.id,
            groupName: group.name,
            deadlineAt: item.deadlineAt,
            nextOccurrenceAt: item.nextOccurrence(),
            scheduleKind: item.scheduleKind,
            recurrenceRule: item.recurrenceRule,
            isCompleted: item.isCompleted,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }
}

struct ReminderGroupSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let sortOrder: Int

    @MainActor
    init(group: TodoGroup) {
        id = group.id
        name = group.name
        colorHex = group.colorHex
        sortOrder = group.sortOrder
    }

    init(id: UUID, name: String, colorHex: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}

struct ReminderContext: Equatable {
    let now: Date
    let timeZone: TimeZone
    let todos: [ReminderTodoSnapshot]
    let groups: [ReminderGroupSnapshot]
    let history: [ReminderHistoryEntry]
    let tone: ReminderTone
}

struct ReminderPanelContent: Equatable {
    let message: String
    let todoReferences: [UUID]

    static func from(message: String, explicitReferences: [UUID] = []) -> ReminderPanelContent {
        let parts = AITodoReferenceParser.parse(message)
        var textParts: [String] = []
        var references: [UUID] = explicitReferences

        for part in parts {
            switch part {
            case let .text(text):
                textParts.append(text)
            case let .todo(id):
                if !references.contains(id) {
                    references.append(id)
                }
            }
        }

        return ReminderPanelContent(
            message: textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            todoReferences: references
        )
    }
}

@MainActor
enum ReminderSnapshotBuilder {
    static func make(modelContext: ModelContext, now: Date = Date()) throws -> (todos: [ReminderTodoSnapshot], groups: [ReminderGroupSnapshot]) {
        let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
        let groups = TodoGroupResolver.normalizedGroups(try modelContext.fetch(FetchDescriptor<TodoGroup>()))
        let todoSnapshots = TodoSorter.sorted(items, groups: groups, now: now).map { item in
            ReminderTodoSnapshot(item: item, group: TodoGroupResolver.group(for: item, groups: groups))
        }
        return (todoSnapshots, groups.map(ReminderGroupSnapshot.init(group:)))
    }
}
