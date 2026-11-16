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
            description: "按 ID 修改任意进行中或已完成事项的业务字段，包括完成状态及恢复未完成。只提交要改的字段，省略或 null 保留原值；可独立修改已有重复规则或起点。应用按操作确认设置直接执行或等待确认，以工具返回结果为准。",
            properties: [
                "id": .object(["type": .string("string")]),
                "title": .object(["type": .string("string"), "description": .string("修改事项标题。应短而具体，保留动作、对象和必要限定词；不能改成过度模糊的标题。")]),
                "note": .object(["type": .string("string"), "description": .string("修改事项备注。用于保存背景、详细要求、验收标准、检查清单、上下文链接或长说明；清空备注时使用 clear_note=true。")]),
                "priority": .object(["type": .string("string"), "enum": .array([.string("high"), .string("medium"), .string("low")])]),
                "group_id": .object(["type": .string("string")]),
                "clear_group": .object(["type": .string("boolean"), "description": .string("移回默认分组，不能与 group_id 同时设置。")]),
                "is_completed": .object(["type": .string("boolean"), "description": .string("true 将整项标记已完成，false 恢复未完成；适用于普通及重复任务。重复任务仅完成当前一次时用 complete_todo，不要将整项结束。")]),
                "automatically_completes": .object(["type": .string("boolean"), "description": .string("重复任务到点自动完成。仅在用户明确要求时设 true，补齐到期次数并进入下一次；false 关闭。可与重复计划同时设置，计划必须有效。")]),
                "created_at": .object(["type": .string("string"), "description": .string("修改创建时间，带时区的 ISO8601。仅在用户明确要求修改历史时间时设置。")]),
                "updated_at": .object(["type": .string("string"), "description": .string("修改更新时间；已完成任务用此字段记录完成时间。带时区的 ISO8601。省略则由应用记录本次修改时间。")]),
                "last_completed_occurrence_at": .object(["type": .string("string"), "description": .string("重复任务最近已完成的周期时间，带时区的 ISO8601；用于修正推进进度，不是整项完成状态。")]),
                "clear_last_completed_occurrence": .object(["type": .string("boolean"), "description": .string("重置重复任务完成进度到起点，不能同时设置 last_completed_occurrence_at。自动完成仍开启时，调度器会继续推进到期周期。")]),
                "deadline_at": .object(["type": .string("string"), "description": .string("ISO8601 单次截止时间")]),
                "reminder_minutes_before": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(525600), "description": .string("设置单次 DDL 或重复事项每次到期前的提醒分钟数；0 为到点提醒。省略则保留原设置。需要任务已有单次 DDL/周期计划或同时设置有效日程；周期提醒完成本次后自动继承。")]),
                "clear_reminder": .object(["type": .string("boolean"), "description": .string("关闭该任务主动设置的定时提醒，保留 DDL。不能与 reminder_minutes_before 同时填写。")]),
                "scheduled_times": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("一次性多个时间点，ISO8601 字符串数组；空数组清除时间计划。不能同时设置 DDL 或重复计划。")]),
                "recurrence_rule": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("every_n_days")]), "description": .string("修改重复规则，省略 recurrence_anchor 时保留已有起点；every_n_days 需同时给出 recurrence_interval_days。")]),
                "recurrence_interval_days": .object(["type": .string("integer"), "minimum": .number(1), "description": .string("每 N 天重复的间隔；已有 every_n_days 任务可只修改此字段。")]),
                "recurrence_anchor": .object(["type": .string("string"), "description": .string("重复事项起始时间，ISO8601；省略 recurrence_rule 时保留已有规则。")]),
                "clear_note": .object(["type": .string("boolean"), "description": .string("清空事项备注。")]),
                "clear_deadline": .object(["type": .string("boolean")]),
                "clear_schedule": .object(["type": .string("boolean"), "description": .string("清除所有时间计划，包括 DDL、多时间点和重复规则。")])
            ],
            required: ["id"]
        ),
        tool(
            name: "complete_todo",
            description: "完成普通事项；重复事项只完成当前一次并推进到下一次，不结束整项。若用户要结束整个重复事项，使用 update_todo(is_completed=true)；恢复任意事项使用 update_todo(is_completed=false)。遵循操作确认设置。",
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
            name: "prepare_summary",
            description: "将已向用户展示的总结整理为保存建议，必须包含标题、覆盖时间段和完整正文。此工具绝不保存；应用必须先逐条询问用户是否保存，只有用户点击该总结的保存按钮后才会写入。时间段为 [period_start, period_end)，结束时间不含且必须晚于开始时间。",
            properties: [
                "title": .object(["type": .string("string")]),
                "period_start": .object(["type": .string("string"), "description": .string("覆盖开始时间，带时区的 ISO8601 日期时间。")]),
                "period_end": .object(["type": .string("string"), "description": .string("覆盖结束时间（不含），带时区的 ISO8601 日期时间，必须晚于 period_start。")]),
                "content": .object(["type": .string("string")])
            ],
            required: ["title", "period_start", "period_end", "content"]
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
