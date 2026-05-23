import Foundation
import SwiftData
import SwiftUI

@Model
final class TodoGroup {
    static let defaultGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultName = "默认分组"
    static let defaultColorHex = "#64748B"
    static let presetColorHexes = ["#64748B", "#3B82F6", "#22C55E", "#F59E0B", "#EF4444", "#A855F7"]

    var id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    static var defaultGroup: TodoGroup {
        TodoGroup(id: defaultGroupID, name: defaultName, colorHex: defaultColorHex, sortOrder: 0)
    }

    var canDelete: Bool {
        id != Self.defaultGroupID
    }

    var color: Color {
        Color(hex: colorHex) ?? .secondary
    }

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = TodoGroup.defaultColorHex,
        sortOrder: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func update(name: String? = nil, colorHex: String? = nil, sortOrder: Int? = nil) {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let colorHex, !colorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.colorHex = colorHex
        }
        if let sortOrder {
            self.sortOrder = sortOrder
        }
        updatedAt = Date()
    }
}

enum TodoGroupResolver {
    static func normalizedGroups(_ groups: [TodoGroup]) -> [TodoGroup] {
        var byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        if byID[TodoGroup.defaultGroupID] == nil {
            byID[TodoGroup.defaultGroupID] = .defaultGroup
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    static func group(for item: TodoItem, groups: [TodoGroup]) -> TodoGroup {
        let normalized = normalizedGroups(groups)
        guard let groupID = item.groupID else {
            return normalized.first(where: { $0.id == TodoGroup.defaultGroupID }) ?? .defaultGroup
        }
        return normalized.first(where: { $0.id == groupID }) ?? normalized.first(where: { $0.id == TodoGroup.defaultGroupID }) ?? .defaultGroup
    }

    static func nextSortOrder(in groups: [TodoGroup]) -> Int {
        (groups.map(\.sortOrder).max() ?? 0) + 1
    }

    static func nextColorHex(for groups: [TodoGroup]) -> String {
        let index = max(0, groups.count) % TodoGroup.presetColorHexes.count
        return TodoGroup.presetColorHexes[index]
    }
}

enum TodoGroupBootstrap {
    static func ensureDefaultGroup(in modelContext: ModelContext) {
        do {
            let groups = try modelContext.fetch(FetchDescriptor<TodoGroup>())
            if let defaultGroup = groups.first(where: { $0.id == TodoGroup.defaultGroupID }) {
                defaultGroup.update(
                    name: TodoGroup.defaultName,
                    colorHex: TodoGroup.defaultColorHex,
                    sortOrder: 0
                )
            } else {
                modelContext.insert(TodoGroup.defaultGroup)
            }
            try modelContext.save()
        } catch {
            assertionFailure("Failed to bootstrap default group: \(error)")
        }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let integer = Int(value, radix: 16) else { return nil }
        let red = Double((integer >> 16) & 0xFF) / 255.0
        let green = Double((integer >> 8) & 0xFF) / 255.0
        let blue = Double(integer & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
