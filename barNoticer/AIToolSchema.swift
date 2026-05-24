import Foundation

struct AIToolDefinition: Codable, Equatable {
    struct Function: Codable, Equatable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    var type: String = "function"
    var function: Function
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }
}

enum AIToolSchema {
    static let openAICompatibleTools: [AIToolDefinition] = [
        tool(
            name: "list_active_todos",
            description: "读取当前未完成事项，按自定义分组返回，每条包含重要性、可选截止时间、多个时间点或重复计划。"
        ),
        tool(
            name: "list_completed_todos",
            description: "读取已完成事项，每条包含分组和时间计划。"
        ),
        tool(
            name: "get_completion_stats",
            description: "统计完成情况、未完成数量、平均完成耗时和当日总结。"
        ),
        tool(
            name: "list_groups",
            description: "读取所有自定义分组，包括内置默认分组。"
        ),
        tool(
            name: "create_todo",
            description: "提出新增待办事项。需要用户确认。",
            properties: [
                "title": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])]),
                "group_id": .object(["type": .string("string")]),
                "deadline_at": .object(["type": .string("string"), "description": .string("ISO8601 单次截止时间。用户说今天/明天/下周三时，先结合当前日期时间解析成明确 ISO8601。")]),
                "scheduled_times": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("一次性多个时间点，ISO8601 字符串数组。展示和提醒只使用最近一个未到来的时间点。")]),
                "recurrence_rule": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly")]), "description": .string("重复事项规则。")]),
                "recurrence_anchor": .object(["type": .string("string"), "description": .string("重复事项起始时间，ISO8601。每天/每周/每月都从该时间推导下一次。")])
            ],
            required: ["title", "priority"]
        ),
        tool(
            name: "update_todo",
            description: "提出修改待办标题、重要性、分组或截止时间。需要用户确认。",
            properties: [
                "id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])]),
                "group_id": .object(["type": .string("string")]),
                "deadline_at": .object(["type": .string("string"), "description": .string("ISO8601 单次截止时间")]),
                "scheduled_times": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("一次性多个时间点，ISO8601 字符串数组。")]),
                "recurrence_rule": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly")])]),
                "recurrence_anchor": .object(["type": .string("string"), "description": .string("重复事项起始时间，ISO8601。")]),
                "clear_deadline": .object(["type": .string("boolean")]),
                "clear_schedule": .object(["type": .string("boolean"), "description": .string("清除所有时间计划，包括 DDL、多时间点和重复规则。")])
            ],
            required: ["id"]
        ),
        tool(
            name: "complete_todo",
            description: "提出完成指定待办。需要用户确认。",
            properties: ["id": .object(["type": .string("string")])],
            required: ["id"]
        ),
        tool(
            name: "delete_todo",
            description: "提出删除指定待办。需要用户确认。",
            properties: ["id": .object(["type": .string("string")])],
            required: ["id"]
        ),
        tool(
            name: "create_group",
            description: "提出新增自定义分组。需要用户确认。",
            properties: [
                "name": .object(["type": .string("string")]),
                "color_hex": .object(["type": .string("string")])
            ],
            required: ["name"]
        ),
        tool(
            name: "update_group",
            description: "提出修改自定义分组名称、颜色或排序。需要用户确认。",
            properties: [
                "id": .object(["type": .string("string")]),
                "name": .object(["type": .string("string")]),
                "color_hex": .object(["type": .string("string")]),
                "sort_order": .object(["type": .string("integer")])
            ],
            required: ["id"]
        ),
        tool(
            name: "delete_group",
            description: "提出删除自定义分组；组内事项会移动到默认分组。需要用户确认。",
            properties: ["id": .object(["type": .string("string")])],
            required: ["id"]
        ),
        tool(
            name: "save_daily_summary",
            description: "保存用户主动输入的当日总结。需要用户确认。",
            properties: ["content": .object(["type": .string("string")])],
            required: ["content"]
        )
    ]

    private static func tool(
        name: String,
        description: String,
        properties: [String: JSONValue] = [:],
        required: [String] = []
    ) -> AIToolDefinition {
        AIToolDefinition(
            function: .init(
                name: name,
                description: description,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(required.map(JSONValue.string))
                ])
            )
        )
    }
}
