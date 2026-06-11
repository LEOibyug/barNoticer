import Foundation

enum AIClientError: LocalizedError {
    case missingAPIKey
    case invalidSettings
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在设置中填写 API Key"
        case .invalidSettings:
            return "AI API 设置无效"
        case .invalidResponse:
            return "AI 返回内容无法解析"
        case let .requestFailed(status, body):
            return "AI 请求失败（\(status)）：\(body)"
        }
    }
}

struct AIChatMessage: Codable, Equatable {
    var role: String
    var content: String?
    var reasoningContent: String?
    var toolCallID: String?
    var toolCalls: [AIToolCall]?

    init(
        role: String,
        content: String?,
        reasoningContent: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [AIToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

struct AIToolCall: Codable, Equatable, Identifiable {
    struct Function: Codable, Equatable {
        var name: String
        var arguments: String
    }

    var id: String
    var type: String
    var function: Function
}

struct AIChatResult: Equatable {
    var content: String
    var reasoningContent: String?
    var toolCalls: [AIToolCall]
}

struct AIClient {
    var session: URLSession = .shared

    func testConnection(
        settings: AISettings,
        apiKey: String
    ) async throws {
        let request = try AIConnectivityCheckRequest.make(settings: settings, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AIClientError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(AIChatResponse.self, from: data)
        guard decoded.choices.first?.message.content != nil || decoded.choices.first?.message.toolCalls != nil else {
            throw AIClientError.invalidResponse
        }
    }

    func send(
        prompt: String,
        settings: AISettings,
        apiKey: String,
        toolResults: [AIChatMessage] = []
    ) async throws -> AIChatResult {
        try await send(
            messages: [
                AIChatMessage(role: "system", content: AISystemPrompt.text),
                AIChatMessage(role: "user", content: prompt)
            ] + toolResults,
            settings: settings,
            apiKey: apiKey
        )
    }

    func send(
        messages: [AIChatMessage],
        settings: AISettings,
        apiKey: String
    ) async throws -> AIChatResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.missingAPIKey
        }
        guard settings.isValid else { throw AIClientError.invalidSettings }

        let request = try AIChatRequestBuilder.make(
            messages: messages,
            settings: settings,
            apiKey: apiKey,
            tools: AIToolSchema.openAICompatibleTools
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AIClientError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(AIChatResponse.self, from: data)
        guard let message = decoded.choices.first?.message else {
            throw AIClientError.invalidResponse
        }

        return AIChatResult(
            content: message.content ?? "",
            reasoningContent: message.reasoningContent,
            toolCalls: message.toolCalls ?? []
        )
    }
}

enum AIChatRequestBuilder {
    static func make(
        messages: [AIChatMessage],
        settings: AISettings,
        apiKey: String,
        tools: [AIToolDefinition]
    ) throws -> URLRequest {
        var request = URLRequest(url: settings.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AIChatRequest(
                model: settings.model,
                messages: messages,
                tools: tools
            )
        )
        return request
    }
}

enum AIConnectivityCheckRequest {
    static func make(settings: AISettings, apiKey: String) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        guard settings.isValid else { throw AIClientError.invalidSettings }

        var request = URLRequest(url: settings.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AIConnectivityCheckBody(
                model: settings.model,
                messages: [
                    AIChatMessage(role: "system", content: "你只需要用中文回复：连接可用。"),
                    AIChatMessage(role: "user", content: "测试连接")
                ],
                maxTokens: 12
            )
        )
        return request
    }
}

private struct AIConnectivityCheckBody: Codable {
    var model: String
    var messages: [AIChatMessage]
    var maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
    }
}

private struct AIChatRequest: Codable {
    var model: String
    var messages: [AIChatMessage]
    var tools: [AIToolDefinition]
}

private struct AIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            var content: String?
            var reasoningContent: String?
            var toolCalls: [AIToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        var message: Message
    }

    var choices: [Choice]
}

enum AISystemPrompt {
    static let text = """
    你是 barNoticer 的轻量任务助手。你可以回答用户关于待办、已完成事项、习惯和当日总结的问题。
    AI 是软件的一部分，只负责管理事项、总结事项和分析事项习惯，不承担事项管理以外的闲聊角色。
    需要任务上下文时先调用读取或统计工具，不要假设你已经知道全部事项。
    事项包含标题、可选备注 note、重要性、自定义分组和可选时间计划。创建或修改事项时，你要主动判断哪些信息适合作为 title，哪些适合作为 note。
    title 要短而具体，通常包含“动作 + 对象 + 必要限定词”，用户扫一眼就能知道要做什么；不能太模糊，避免只写“处理一下”“看看”“跟进”“整理资料”这类缺少对象或目标的标题。
    note 用来保存不适合放进标题的内容，包括背景、原因、详细要求、验收标准、检查清单、上下文链接、长文本说明、用户原话中的补充限制。不要把这些细节堆进 title。
    多时间点事项展示和提醒时只使用最近一个未到来的时间点；重复事项支持 daily、weekly、monthly、every_n_days，用户完成一次后应用会自动滚到下一次，不要把它当成永久完成。
    用户可能用今天、明天、下周三等相对日期描述时间；必须基于任务上下文中的当前本地时间和时区解析为明确 ISO8601 时间。已有事项的 deadlineLocal、nextOccurrenceLocal 是权威本地时间，不要根据 createdAt 或 updatedAt 推断截止日期。单次截止写入 deadline_at；多个指定时间写入 scheduled_times；每天/每周/每月重复写入 recurrence_rule 和 recurrence_anchor；每 N 天重复写入 recurrence_rule=every_n_days、recurrence_interval_days=N 和 recurrence_anchor。
    可以读取、新增、修改、删除分组；内置“默认分组”不可删除，删除其他分组时组内事项会回到默认分组。
    新增、修改、完成、删除事项或保存总结时，只提出工具调用；应用会先让用户确认。需要清空备注时使用 clear_note=true。
    当你在回复中提到某条已存在事项时，必须使用 [[todo:<事项UUID>]] 标记引用；不要只写事项标题。应用会把这种引用渲染成可操作事项。已经用标记引用某条事项后，不要在标记之外重复这条事项的标题、重要性、创建时间等详情。
    连续列举多个事项引用时，引用标记之间不要插入任何文字或标点；例如直接连续输出多个 [[todo:<事项UUID>]] 标记。
    不要向用户询问是否需要你帮忙完成、整理或处理某件事；如果用户意图明确，直接回复结论或提出相应工具调用。
    不要使用 Markdown。不要使用标题、加粗、项目符号、编号列表或代码块；只输出自然语言纯文本和必要的 [[todo:<事项UUID>]] 引用。
    回复保持简洁，使用中文。
    """
}
