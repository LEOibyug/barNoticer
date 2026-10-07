import Foundation
import SwiftData

/// 按 ID 查询事项并构造引用卡片摘要。
/// 回复面板与提醒面板共用同一摘要规则；单项查询使用 ID predicate，
/// 不再先抓取全部事项。
@MainActor
enum AITodoLookup {
    /// 读取失败与不存在通过抛错区分：不存在返回 nil，存储异常抛出。
    static func todo(id: UUID, in modelContext: ModelContext) throws -> TodoItem? {
        var descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func todos(ids: [UUID], in modelContext: ModelContext) throws -> [TodoItem] {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { uniqueIDs.contains($0.id) })
        return try modelContext.fetch(descriptor)
    }

    static func referencedTodo(id: UUID, in modelContext: ModelContext) -> AIReferencedTodo {
        let item: TodoItem?
        do {
            item = try todo(id: id, in: modelContext)
        } catch {
            return .readFailure(id: id)
        }
        guard let item else {
            return .missing(id: id)
        }
        let groups = (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
        let group = TodoGroupResolver.group(for: item, groups: groups)
        return AIReferencedTodo(
            id: id,
            title: item.title,
            priority: item.priority,
            groupName: group.name,
            scheduleText: TodoDeadlineFormatter.cardText(for: item),
            createdAt: item.createdAt,
            isCompleted: item.isCompleted,
            exists: true
        )
    }

    /// 多卡片渲染按所需 ID 批量取回，分组索引共享一次。
    static func referencedTodoMap(ids: [UUID], in modelContext: ModelContext) -> [UUID: AIReferencedTodo] {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return [:] }

        let items: [TodoItem]
        do {
            items = try todos(ids: uniqueIDs, in: modelContext)
        } catch {
            return uniqueIDs.reduce(into: [:]) { map, id in
                map[id] = .readFailure(id: id)
            }
        }
        let groupIndex = TodoGroupResolver.indexedByID(
            (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
        )

        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return uniqueIDs.reduce(into: [:]) { map, id in
            guard let item = byID.removeValue(forKey: id) else {
                map[id] = .missing(id: id)
                return
            }
            let group = groupIndex[TodoGroupResolver.groupID(for: item, index: groupIndex)]
            map[id] = AIReferencedTodo(
                id: id,
                title: item.title,
                priority: item.priority,
                groupName: group?.name ?? TodoGroup.defaultName,
                scheduleText: TodoDeadlineFormatter.cardText(for: item),
                createdAt: item.createdAt,
                isCompleted: item.isCompleted,
                exists: true
            )
        }
    }
}

extension AIReferencedTodo {
    /// 事项不存在（已删除）。
    static func missing(id: UUID) -> AIReferencedTodo {
        AIReferencedTodo(id: id, title: "事项", priority: .low, groupName: nil, scheduleText: nil, createdAt: nil, isCompleted: false, exists: false)
    }

    /// 读取失败：与“事项不存在”区分，不误导用户。
    static func readFailure(id: UUID) -> AIReferencedTodo {
        AIReferencedTodo(id: id, title: "事项信息暂时无法读取", priority: .low, groupName: nil, scheduleText: nil, createdAt: nil, isCompleted: false, exists: false, readFailed: true)
    }
}
