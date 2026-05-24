import Foundation

struct AITodoItemSnapshot: Equatable, Identifiable, Codable {
    let id: UUID
    let title: String
    let priority: TodoPriority
    let groupID: UUID
    let groupName: String
    let deadlineAt: Date?
    let scheduledTimes: [Date]
    let recurrenceRule: TodoRecurrenceRule?
    let recurrenceAnchor: Date?
    let nextOccurrenceAt: Date?
    let scheduleKind: TodoScheduleKind
    let isCompleted: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct AITodoGroupSnapshot: Equatable, Identifiable, Codable {
    let id: UUID
    let name: String
    let colorHex: String
    let sortOrder: Int
}

struct AITodoGroupItemsSnapshot: Equatable, Identifiable, Codable {
    let group: AITodoGroupSnapshot
    let items: [AITodoItemSnapshot]

    var id: UUID { group.id }
}

struct AITodoStats: Equatable {
    let activeCount: Int
    let completedCount: Int
    let averageCompletionInterval: TimeInterval?
}

struct AITodoSnapshot: Equatable {
    let activeByPriority: [TodoPriority: [AITodoItemSnapshot]]
    let activeByGroup: [AITodoGroupItemsSnapshot]
    let completed: [AITodoItemSnapshot]
    let groups: [AITodoGroupSnapshot]
    let dailySummaries: [DailySummarySnapshot]
    let stats: AITodoStats
}

struct AITodoInlineContext: Equatable {
    let content: String
}

@MainActor
enum AITodoContext {
    static func snapshot(items: [TodoItem], groups: [TodoGroup] = [], dailySummaries: [DailySummary] = [], now: Date = Date()) -> AITodoSnapshot {
        let normalizedGroups = TodoGroupResolver.normalizedGroups(groups)
        let snapshots = TodoSorter.sorted(items, groups: normalizedGroups, now: now).map { item in
            AITodoItemSnapshot(item: item, group: TodoGroupResolver.group(for: item, groups: normalizedGroups))
        }
        let active = snapshots.filter { !$0.isCompleted }
        let completed = snapshots.filter(\.isCompleted)
        let grouped = Dictionary(grouping: active, by: \.priority)
        let activeByGroup = normalizedGroups.compactMap { group -> AITodoGroupItemsSnapshot? in
            let items = active.filter { $0.groupID == group.id }
            guard !items.isEmpty else { return nil }
            return AITodoGroupItemsSnapshot(group: AITodoGroupSnapshot(group: group), items: items)
        }
        let completionIntervals = completed.map { max(0, $0.updatedAt.timeIntervalSince($0.createdAt)) }
        let average = completionIntervals.isEmpty ? nil : completionIntervals.reduce(0, +) / Double(completionIntervals.count)

        return AITodoSnapshot(
            activeByPriority: grouped,
            activeByGroup: activeByGroup,
            completed: completed,
            groups: normalizedGroups.map(AITodoGroupSnapshot.init(group:)),
            dailySummaries: dailySummaries
                .sorted { $0.createdAt > $1.createdAt }
                .map(DailySummarySnapshot.init(summary:)),
            stats: AITodoStats(
                activeCount: active.count,
                completedCount: completed.count,
                averageCompletionInterval: average
            )
        )
    }
}

extension AITodoSnapshot {
    func inlineContext(
        activeLimitPerPriority: Int = 6,
        completedLimit: Int = 6,
        summaryLimit: Int = 3,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> AITodoInlineContext {
        var lines = [
            "当前任务上下文。引用已有事项时必须使用 [[todo:<UUID>]]：",
            "当前日期时间：\(Self.iso8601(now))；时区：\(Self.timeZoneDescription(timeZone))。",
            "相对日期必须基于当前日期时间解析，例如今天、明天、下周三都要转换为明确 ISO8601 截止时间。",
            "未完成：\(stats.activeCount)；已完成：\(stats.completedCount)。"
        ]

        for priority in TodoPriority.allCases {
            let items = Array((activeByPriority[priority] ?? []).prefix(activeLimitPerPriority))
            guard !items.isEmpty else { continue }
            lines.append("\(priority.title)重要性：")
            lines.append(contentsOf: items.map { item in
                let deadlineText = item.deadlineAt.map(Self.iso8601) ?? "none"
                let nextText = item.nextOccurrenceAt.map(Self.iso8601) ?? "none"
                let scheduledText = item.scheduledTimes.map(Self.iso8601).joined(separator: ",")
                let recurrenceText = item.recurrenceRule?.rawValue ?? "none"
                let anchorText = item.recurrenceAnchor.map(Self.iso8601) ?? "none"
                return "- id=\(item.id.uuidString) title=\(item.title) group=\(item.groupName) scheduleKind=\(item.scheduleKind.rawValue) deadlineAt=\(deadlineText) scheduledTimes=[\(scheduledText)] recurrenceRule=\(recurrenceText) recurrenceAnchor=\(anchorText) nextOccurrenceAt=\(nextText) createdAt=\(Self.iso8601(item.createdAt))"
            })
        }

        if !groups.isEmpty {
            lines.append("分组：")
            lines.append(contentsOf: groups.map { "- id=\($0.id.uuidString) name=\($0.name) color=\($0.colorHex) sortOrder=\($0.sortOrder)" })
        }

        let completedItems = Array(completed.prefix(completedLimit))
        if !completedItems.isEmpty {
            lines.append("最近已完成：")
            lines.append(contentsOf: completedItems.map { "- id=\($0.id.uuidString) title=\($0.title) completedAt=\(Self.iso8601($0.updatedAt))" })
        }

        let summaries = Array(dailySummaries.prefix(summaryLimit))
        if !summaries.isEmpty {
            lines.append("最近总结：")
            lines.append(contentsOf: summaries.map { "- \($0.content)" })
        }

        if let average = stats.averageCompletionInterval {
            let hours = average / 3_600
            lines.append(String(format: "平均完成耗时：%.1f 小时。", hours))
        }

        return AITodoInlineContext(content: lines.joined(separator: "\n"))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func timeZoneDescription(_ timeZone: TimeZone) -> String {
        let seconds = timeZone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}

extension AITodoItemSnapshot {
    init(item: TodoItem, group: TodoGroup) {
        id = item.id
        title = item.title
        priority = item.priority
        groupID = group.id
        groupName = group.name
        deadlineAt = item.deadlineAt
        scheduledTimes = item.scheduledTimes
        recurrenceRule = item.recurrenceRule
        recurrenceAnchor = item.recurrenceAnchor
        nextOccurrenceAt = item.nextOccurrence()
        scheduleKind = item.scheduleKind
        isCompleted = item.isCompleted
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }
}

extension AITodoGroupSnapshot {
    init(group: TodoGroup) {
        id = group.id
        name = group.name
        colorHex = group.colorHex
        sortOrder = group.sortOrder
    }
}

struct DailySummarySnapshot: Equatable, Identifiable, Codable {
    let id: UUID
    let content: String
    let createdAt: Date

    init(summary: DailySummary) {
        id = summary.id
        content = summary.content
        createdAt = summary.createdAt
    }
}
