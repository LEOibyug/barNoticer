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
    static let readGlobalMemoryTool = tool(name: "read_global_memory", description: "按需查阅长期用户记忆。上下文不会预先提供记忆；需要用户信息、偏好、习惯、已有定义，或用户询问记住了什么、要求修改记忆时主动调用。返回 key、content、source 和更新时间；不必每轮固定查阅。")
    static let openAICompatibleTools: [AIToolDefinition] = [
        readGlobalMemoryTool,
        tool(
            name: "save_global_memory",
            description: "按 key 新增或更新一条全局记忆，立即保存，跨会话生效。自动记录仅限用户本人表述的稳定信息或偏好；用户明确要求记住或修改时使用 explicit。同一主题复用原 key，避免冲突和重复；不能用空内容删除或清空。",
            properties: [
                "key": .object(["type": .string("string"), "description": .string("稳定的主题名称，1～64 字，例如：称呼、回复语言、任务命名习惯。")]),
                "content": .object(["type": .string("string"), "description": .string("简洁、明确的用户信息或用户定义，1～1000 字。")]),
                "source": .object(["type": .string("string"), "enum": .array([.string("explicit"), .string("automatic")]), "description": .string("explicit=用户明确要求保存或修改；automatic=依据用户本人表述自动记录。")])
            ], required: ["key", "content", "source"]
        ),
        tool(name: "clear_global_memory", description: "仅在用户明确要求清空全部全局记忆时提出清空请求。此调用不会清空；应用必须弹出二次确认，即使关闭普通操作审批也不能绕过。不得声称已清空，等待用户在应用中确认。"),
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
            description: "提出新增待办事项。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: [
                "title": .object(["type": .string("string"), "description": .string("简洁且能独立识别任务的标题：动作 + 对象 + 必要限定信息，通常 8～20 个汉字左右，非硬性限制。保留关键项目名、课程名、交付物或区分任务所需的范围；不截断必要名称，不照抄用户长句。背景、步骤和详细要求放入 note，时间安排等放入对应字段。")]),
                "note": .object(["type": .string("string"), "description": .string("可选备注。完整保存从标题移出的背景、步骤、详细要求、验收标准、检查清单、链接、文件路径和补充限制，不遗漏或虚构用户要求。长输入通常应填写备注；无补充信息时可省略，不要仅重复标题。")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])]),
                "group_id": .object(["type": .string("string")]),
                "deadline_at": .object(["type": .string("string"), "description": .string("ISO8601 单次截止时间。用户说今天/明天/下周三时，先结合当前日期时间解析成明确 ISO8601。")]),
                "reminder_minutes_before": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(525600), "description": .string("用户主动设置的 DDL 提前提醒分钟数，适用于单次 deadline_at 或带 recurrence_anchor 的重复事项；0 为到点提醒，30 为提前半小时，1440 为提前一天。不受 AI 轮询开关影响。未要求时省略。")]),
                "scheduled_times": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("一次性多个时间点，ISO8601 字符串数组。展示和提醒只使用最近一个未到来的时间点。")]),
                "recurrence_rule": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("every_n_days")]), "description": .string("重复事项规则。用户说每 N 天时使用 every_n_days，并同时填写 recurrence_interval_days。")]),
                "recurrence_interval_days": .object(["type": .string("integer"), "minimum": .number(1), "description": .string("仅 recurrence_rule=every_n_days 时填写，表示每 N 天重复。")]),
                "recurrence_anchor": .object(["type": .string("string"), "description": .string("重复事项起始时间，ISO8601。每天/每周/每月/每 N 天都从该时间推导下一次。")])
            ],
            required: ["title", "priority"]
        ),
        tool(
            name: "update_todo",
            description: "提出修改待办标题、重要性、分组或截止时间。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: [
                "id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string"), "description": .string("修改事项标题。应短而具体，保留动作、对象和必要限定词；不能改成过度模糊的标题。")]),
                "note": .object(["type": .string("string"), "description": .string("修改事项备注。用于保存背景、详细要求、验收标准、检查清单、上下文链接或长说明；清空备注时使用 clear_note=true。")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])]),
                "group_id": .object(["type": .string("string")]),
                "deadline_at": .object(["type": .string("string"), "description": .string("ISO8601 单次截止时间")]),
                "reminder_minutes_before": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(525600), "description": .string("设置单次 DDL 或重复事项每次到期前的提醒分钟数；0 为到点提醒。省略则保留原设置。需要任务已有单次 DDL/周期计划或同时设置有效日程；周期提醒完成本次后自动继承。")]),
                "clear_reminder": .object(["type": .string("boolean"), "description": .string("关闭该任务主动设置的定时提醒，保留 DDL。不能与 reminder_minutes_before 同时填写。")]),
                "scheduled_times": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("一次性多个时间点，ISO8601 字符串数组。")]),
                "recurrence_rule": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("every_n_days")])]),
                "recurrence_interval_days": .object(["type": .string("integer"), "minimum": .number(1), "description": .string("仅 recurrence_rule=every_n_days 时填写，表示每 N 天重复。")]),
                "recurrence_anchor": .object(["type": .string("string"), "description": .string("重复事项起始时间，ISO8601。")]),
                "clear_note": .object(["type": .string("boolean"), "description": .string("清空事项备注。")]),
                "clear_deadline": .object(["type": .string("boolean")]),
                "clear_schedule": .object(["type": .string("boolean"), "description": .string("清除所有时间计划，包括 DDL、多时间点和重复规则。")])
            ],
            required: ["id"]
        ),
        tool(
            name: "set_recurring_auto_completion",
            description: "设置周期事项到点自动完成。仅当用户明确要求时开启；开启后补齐过期次数并进入下一次，不累计逾期，提醒设置保留。关闭后需要手动完成。遵循普通操作确认开关。",
            properties: ["id": .object(["type": .string("string")]), "enabled": .object(["type": .string("boolean")])],
            required: ["id", "enabled"]
        ),
        tool(
            name: "complete_todo",
            description: "提出完成指定待办。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: ["id": .object(["type": .string("string")])],
            required: ["id"]
        ),
        tool(
            name: "delete_todo",
            description: "提出删除指定待办。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: ["id": .object(["type": .string("string")])],
            required: ["id"]
        ),
        tool(
            name: "create_group",
            description: "提出新增自定义分组。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: [
                "name": .object(["type": .string("string")]),
                "color_hex": .object(["type": .string("string")])
            ],
            required: ["name"]
        ),
        tool(
            name: "update_group",
            description: "提出修改自定义分组名称、颜色或排序。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
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
            description: "提出删除自定义分组；组内事项会移动到默认分组。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: ["id": .object(["type": .string("string")])],
            required: ["id"]
        ),
        tool(
            name: "save_daily_summary",
            description: "保存用户主动输入的当日总结。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
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
