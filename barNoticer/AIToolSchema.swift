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
            description: "读取当前未完成事项，按重要性分组。"
        ),
        tool(
            name: "list_completed_todos",
            description: "读取已完成事项。"
        ),
        tool(
            name: "get_completion_stats",
            description: "统计完成情况、未完成数量、平均完成耗时和当日总结。"
        ),
        tool(
            name: "create_todo",
            description: "提出新增待办事项。需要用户确认。",
            properties: [
                "title": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])])
            ],
            required: ["title", "priority"]
        ),
        tool(
            name: "update_todo",
            description: "提出修改待办标题或重要性。需要用户确认。",
            properties: [
                "id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])])
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
