import Foundation

struct AITodoItemSnapshot: Equatable, Identifiable, Codable {
    let id: UUID
    let title: String
    let priority: TodoPriority
    let isCompleted: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct AITodoStats: Equatable {
    let activeCount: Int
    let completedCount: Int
    let averageCompletionInterval: TimeInterval?
}

struct AITodoSnapshot: Equatable {
    let activeByPriority: [TodoPriority: [AITodoItemSnapshot]]
    let completed: [AITodoItemSnapshot]
    let dailySummaries: [DailySummarySnapshot]
    let stats: AITodoStats
}

struct AITodoInlineContext: Equatable {
    let content: String
}

@MainActor
enum AITodoContext {
    static func snapshot(items: [TodoItem], dailySummaries: [DailySummary] = [], now: Date = Date()) -> AITodoSnapshot {
        let snapshots = TodoSorter.sorted(items).map(AITodoItemSnapshot.init(item:))
        let active = snapshots.filter { !$0.isCompleted }
        let completed = snapshots.filter(\.isCompleted)
        let grouped = Dictionary(grouping: active, by: \.priority)
        let completionIntervals = completed.map { max(0, $0.updatedAt.timeIntervalSince($0.createdAt)) }
        let average = completionIntervals.isEmpty ? nil : completionIntervals.reduce(0, +) / Double(completionIntervals.count)

        return AITodoSnapshot(
            activeByPriority: grouped,
            completed: completed,
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
    func inlineContext(activeLimitPerPriority: Int = 6, completedLimit: Int = 6, summaryLimit: Int = 3) -> AITodoInlineContext {
        var lines = [
            "当前任务上下文。引用已有事项时必须使用 [[todo:<UUID>]]：",
            "未完成：\(stats.activeCount)；已完成：\(stats.completedCount)。"
        ]

        for priority in TodoPriority.allCases {
            let items = Array((activeByPriority[priority] ?? []).prefix(activeLimitPerPriority))
            guard !items.isEmpty else { continue }
            lines.append("\(priority.title)重要性：")
            lines.append(contentsOf: items.map { "- id=\($0.id.uuidString) title=\($0.title) createdAt=\(Self.iso8601($0.createdAt))" })
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
}

extension AITodoItemSnapshot {
    init(item: TodoItem) {
        id = item.id
        title = item.title
        priority = item.priority
        isCompleted = item.isCompleted
        createdAt = item.createdAt
        updatedAt = item.updatedAt
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
