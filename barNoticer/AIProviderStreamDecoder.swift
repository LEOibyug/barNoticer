import Foundation

enum AIStreamEvent: Equatable {
    case text(String)
    case reasoning(String)
    case toolCall(String)
    case reset
}

/// Decodes complete SSE payloads. Tool arguments remain data until the caller receives a final result.
struct AIProviderStreamDecoder {
    private struct ChatTool {
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""
        var hasArguments = false
    }

    private struct AnthropicBlock {
        var value: [String: Any]
        var arguments = ""
        var hasArgumentDeltas = false
        var stopped = false
    }

    private let format: AIResponseFormat
    private let apiKey: String
    private var completed = false
    private var failure: Error?
    private var text = ""
    private var reasoning = ""
    private var chatTools: [Int: ChatTool] = [:]
    private var responseOutput: [Int: [String: Any]] = [:]
    private var finalResponse: [String: Any]?
    private var announcedResponseTools = Set<String>()
    private var previews: [String: String] = [:]
    private var anthropicStarted = false
    private var anthropicStopReason: String?
    private var anthropicBlocks: [Int: AnthropicBlock] = [:]

    init(format: AIResponseFormat, apiKey: String = "") {
        self.format = format
        self.apiKey = apiKey
    }

    var isComplete: Bool { completed && failure == nil }

    mutating func consume(data: String, event: String?) throws -> [AIStreamEvent] {
        if let failure { throw failure }
        do {
            if format == .chatCompletions, data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                if completed { return [] }
                let events = try completeChat()
                completed = true
                return events
            }
            guard let bytes = data.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw AIClientError.invalidResponse
            }
            if let error = root["error"], !(error is NSNull) {
                throw AIClientError.providerResponseFailed(AIProviderTransport.failureMessage(bytes, apiKey: apiKey))
            }
            guard !completed else { throw AIClientError.invalidResponse }
            switch format {
            case .chatCompletions: return try consumeChat(root)
            case .responses: return try consumeResponse(root, event: event)
            case .anthropic: return try consumeAnthropic(root, event: event)
            }
        } catch {
            failure = error
            throw error
        }
    }

    func finish() throws -> AIChatResult {
        if let failure { throw failure }
        guard completed else { throw incomplete("数据流提前结束，请重试") }
        switch format {
        case .chatCompletions:
            let calls = try chatTools.keys.sorted().map { index -> [String: Any] in
                let tool = try validatedChatTool(at: index)
                return ["id": tool.id, "type": tool.type,
                        "function": ["name": tool.name, "arguments": tool.arguments]]
            }
            var message: [String: Any] = ["content": text, "tool_calls": calls]
            if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
            return try decode(["choices": [["message": message]]])
        case .responses:
            guard let finalResponse else { throw AIClientError.invalidResponse }
            return try decode(finalResponse)
        case .anthropic:
            var texts: [String] = [], calls: [AIToolCall] = []
            for index in anthropicBlocks.keys.sorted() {
                guard let block = anthropicBlocks[index] else { throw AIClientError.invalidResponse }
                if block.value["type"] as? String == "text", let value = block.value["text"] as? String { texts.append(value) }
                if block.value["type"] as? String == "tool_use" {
                    guard let id = block.value["id"] as? String, let name = block.value["name"] as? String,
                          let input = block.value["input"] as? [String: Any] else { throw AIClientError.invalidResponse }
                    let arguments = block.hasArgumentDeltas ? block.arguments :
                        String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
                    calls.append(.init(id: id, type: "function", function: .init(name: name, arguments: arguments)))
                }
            }
            guard !texts.isEmpty || !calls.isEmpty || !reasoning.isEmpty else { throw AIClientError.invalidResponse }
            if anthropicStopReason == "tool_use", calls.isEmpty { throw AIClientError.invalidResponse }
            return AIChatResult(content: texts.joined(separator: "\n"),
                reasoningContent: reasoning.isEmpty ? nil : reasoning, toolCalls: calls)
        }
    }

    private mutating func consumeChat(_ root: [String: Any]) throws -> [AIStreamEvent] {
        guard let choices = root["choices"] as? [[String: Any]] else { throw AIClientError.invalidResponse }
        if choices.isEmpty {
            guard root["usage"] is [String: Any] else { throw AIClientError.invalidResponse }
            return []
        }
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }),
              let delta = choice["delta"] as? [String: Any] else { throw AIClientError.invalidResponse }
        var events: [AIStreamEvent] = []
        if let content = try optionalString(delta, key: "content"), !content.isEmpty {
            text += content
            events.append(.text(content))
        }
        let summary = try optionalString(delta, key: "reasoning_content") ?? optionalString(delta, key: "reasoning")
        if let summary, !summary.isEmpty {
            reasoning += summary
            events.append(.reasoning(summary))
        }
        if let rawCalls = delta["tool_calls"], !(rawCalls is NSNull) {
            guard let calls = rawCalls as? [[String: Any]] else { throw AIClientError.invalidResponse }
            for call in calls {
                guard let index = call["index"] as? Int, index >= 0 else { throw AIClientError.invalidResponse }
                var tool = chatTools[index] ?? ChatTool()
                if let id = try optionalString(call, key: "id") { tool.id += id }
                if let type = try optionalString(call, key: "type") {
                    guard type == "function" else { throw AIClientError.invalidResponse }
                    tool.type = type
                }
                if let rawFunction = call["function"] {
                    guard let function = rawFunction as? [String: Any] else { throw AIClientError.invalidResponse }
                    if let name = try optionalString(function, key: "name") { tool.name += name }
                    if let arguments = try optionalString(function, key: "arguments") {
                        tool.arguments += arguments
                        tool.hasArguments = true
                    }
                }
                chatTools[index] = tool
            }
        }
        if let reason = try optionalString(choice, key: "finish_reason") {
            guard reason == "stop" || reason == "tool_calls" else {
                throw incomplete(reason == "length" ? "达到输出长度限制，请提高输出上限或缩短请求后重试" : "输出被供应商中止（\(reason)），请调整请求后重试")
            }
            if reason == "tool_calls", chatTools.isEmpty { throw AIClientError.invalidResponse }
            events += try completeChat()
            completed = true
        }
        return events
    }

    private func validatedChatTool(at index: Int) throws -> ChatTool {
        guard let tool = chatTools[index], !tool.id.isEmpty, !tool.name.isEmpty, tool.hasArguments else {
            throw AIClientError.invalidResponse
        }
        return tool
    }

    private func completeChat() throws -> [AIStreamEvent] {
        guard !text.isEmpty || !reasoning.isEmpty || !chatTools.isEmpty else { throw AIClientError.invalidResponse }
        return try chatTools.keys.sorted().map { .toolCall(try validatedChatTool(at: $0).name) }
    }

    private mutating func consumeResponse(_ root: [String: Any], event: String?) throws -> [AIStreamEvent] {
        let type = try eventType(root, event: event)
        switch type {
        case "error", "response.failed", "response.incomplete":
            let response = root["response"] as? [String: Any] ?? root
            if let error = response["error"], !(error is NSNull) {
                throw AIClientError.providerResponseFailed(AIProviderTransport.failureMessage(try JSONSerialization.data(withJSONObject: response), apiKey: apiKey))
            }
            throw incomplete(type == "response.incomplete" ? "响应未完成，请提高输出上限或调整请求后重试" : "供应商未能完成响应，请重试")
        case "response.output_text.delta", "response.refusal.delta", "response.reasoning_summary_text.delta":
            guard let delta = root["delta"] as? String else { throw AIClientError.invalidResponse }
            let key = try responsePreviewKey(root, type: type)
            previews[key, default: ""] += delta
            guard !delta.isEmpty else { return [] }
            return type == "response.reasoning_summary_text.delta" ? [.reasoning(delta)] : [.text(delta)]
        case "response.output_text.done", "response.refusal.done", "response.reasoning_summary_text.done":
            let field = type == "response.refusal.done" ? "refusal" : "text"
            guard let value = root[field] as? String else { throw AIClientError.invalidResponse }
            return try preview(value, key: responsePreviewKey(root, type: type), reasoning: type == "response.reasoning_summary_text.done")
        case "response.output_item.added", "response.output_item.done":
            guard let index = root["output_index"] as? Int, index >= 0,
                  let item = root["item"] as? [String: Any], item["type"] is String else { throw AIClientError.invalidResponse }
            if type == "response.output_item.done" { responseOutput[index] = item }
            var events = announceResponseTool(item, index: index)
            if type == "response.output_item.done" { events += try previewResponseItem(item, index: index) }
            return events
        case "response.completed":
            guard var response = root["response"] as? [String: Any] else { throw AIClientError.invalidResponse }
            if response["output"] == nil {
                guard !responseOutput.isEmpty else { throw AIClientError.invalidResponse }
                let indices = responseOutput.keys.sorted()
                guard indices == Array(0..<indices.count) else { throw AIClientError.invalidResponse }
                response["output"] = indices.compactMap { responseOutput[$0] }
            }
            // The terminal envelope, not locally reconstructed deltas, owns opaque replay data and calls.
            _ = try decode(response)
            guard let output = response["output"] as? [[String: Any]] else { throw AIClientError.invalidResponse }
            var events: [AIStreamEvent] = []
            for (index, item) in output.enumerated() {
                events += announceResponseTool(item, index: index)
                events += try previewResponseItem(item, index: index)
            }
            finalResponse = response
            completed = true
            return events
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            let field = type.hasSuffix("delta") ? "delta" : "arguments"
            guard let index = root["output_index"] as? Int, index >= 0, root[field] is String else {
                throw AIClientError.invalidResponse
            }
            return []
        case "response.created", "response.queued", "response.in_progress",
             "response.content_part.added", "response.content_part.done",
             "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
            return []
        default:
            // Providers can add non-content lifecycle events; only supported content enters the result.
            guard type.hasPrefix("response.") else { throw AIClientError.invalidResponse }
            return []
        }
    }

    private mutating func announceResponseTool(_ item: [String: Any], index: Int) -> [AIStreamEvent] {
        guard item["type"] as? String == "function_call", let name = item["name"] as? String, !name.isEmpty else { return [] }
        let identity = "\(index)"
        guard announcedResponseTools.insert(identity).inserted else { return [] }
        return [.toolCall(name)]
    }

    private func responsePreviewKey(_ root: [String: Any], type: String) throws -> String {
        guard let index = root["output_index"] as? Int, index >= 0 else { throw AIClientError.invalidResponse }
        let isReasoning = type.contains("reasoning_summary_text")
        let partKey = isReasoning ? "summary_index" : "content_index"
        guard let part = root[partKey] as? Int, part >= 0 else { throw AIClientError.invalidResponse }
        let channel = isReasoning ? "reasoning" : (type.contains("refusal") ? "refusal" : "text")
        return "\(index):\(part):\(channel)"
    }

    private mutating func preview(_ value: String, key: String, reasoning: Bool = false) -> [AIStreamEvent] {
        let previous = previews[key] ?? ""
        guard value.hasPrefix(previous) else { return [] }
        let suffix = String(value.dropFirst(previous.count))
        previews[key] = value
        guard !suffix.isEmpty else { return [] }
        return reasoning ? [.reasoning(suffix)] : [.text(suffix)]
    }

    private mutating func previewResponseItem(_ item: [String: Any], index: Int) throws -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        switch item["type"] as? String {
        case "message":
            for (partIndex, part) in (item["content"] as? [[String: Any]] ?? []).enumerated() {
                if part["type"] as? String == "output_text", let value = part["text"] as? String {
                    events += preview(value, key: "\(index):\(partIndex):text")
                } else if part["type"] as? String == "refusal", let value = part["refusal"] as? String {
                    events += preview(value, key: "\(index):\(partIndex):refusal")
                }
            }
        case "reasoning":
            for (partIndex, part) in (item["summary"] as? [[String: Any]] ?? []).enumerated() {
                if part["type"] as? String == "summary_text", let value = part["text"] as? String {
                    events += preview(value, key: "\(index):\(partIndex):reasoning", reasoning: true)
                }
            }
        default: break
        }
        return events
    }

    private mutating func consumeAnthropic(_ root: [String: Any], event: String?) throws -> [AIStreamEvent] {
        let type = try eventType(root, event: event)
        if type == "error" {
            throw AIClientError.providerResponseFailed(AIProviderTransport.failureMessage(try JSONSerialization.data(withJSONObject: root), apiKey: apiKey))
        }
        if type == "ping" { return [] }
        if type == "message_start" {
            guard !anthropicStarted, let message = root["message"] as? [String: Any],
                  message["type"] as? String == "message", let content = message["content"] as? [Any], content.isEmpty else {
                throw AIClientError.invalidResponse
            }
            anthropicStarted = true
            return []
        }
        guard anthropicStarted else { throw AIClientError.invalidResponse }
        switch type {
        case "content_block_start":
            guard let index = root["index"] as? Int, index >= 0, anthropicBlocks[index] == nil,
                  let block = root["content_block"] as? [String: Any], let blockType = block["type"] as? String else {
                throw AIClientError.invalidResponse
            }
            var events: [AIStreamEvent] = []
            switch blockType {
            case "text":
                guard let value = block["text"] as? String else { throw AIClientError.invalidResponse }
                if !value.isEmpty { events.append(.text(value)) }
            case "thinking":
                guard let value = block["thinking"] as? String else { throw AIClientError.invalidResponse }
                reasoning += value
                if !value.isEmpty { events.append(.reasoning(value)) }
            case "redacted_thinking": break
            case "tool_use":
                guard let id = block["id"] as? String, !id.isEmpty, let name = block["name"] as? String,
                      !name.isEmpty, block["input"] is [String: Any] else { throw AIClientError.invalidResponse }
                events.append(.toolCall(name))
            default: throw AIClientError.invalidResponse
            }
            anthropicBlocks[index] = AnthropicBlock(value: block)
            return events
        case "content_block_delta":
            guard let index = root["index"] as? Int, var block = anthropicBlocks[index], !block.stopped,
                  let delta = root["delta"] as? [String: Any], let deltaType = delta["type"] as? String else {
                throw AIClientError.invalidResponse
            }
            var events: [AIStreamEvent] = []
            switch deltaType {
            case "text_delta":
                guard block.value["type"] as? String == "text", let value = delta["text"] as? String else { throw AIClientError.invalidResponse }
                block.value["text"] = (block.value["text"] as? String ?? "") + value
                if !value.isEmpty { events.append(.text(value)) }
            case "thinking_delta":
                guard block.value["type"] as? String == "thinking", let value = delta["thinking"] as? String else { throw AIClientError.invalidResponse }
                block.value["thinking"] = (block.value["thinking"] as? String ?? "") + value
                reasoning += value
                if !value.isEmpty { events.append(.reasoning(value)) }
            case "signature_delta":
                guard block.value["type"] as? String == "thinking", let value = delta["signature"] as? String else { throw AIClientError.invalidResponse }
                block.value["signature"] = (block.value["signature"] as? String ?? "") + value
            case "input_json_delta":
                guard block.value["type"] as? String == "tool_use", let value = delta["partial_json"] as? String else { throw AIClientError.invalidResponse }
                block.arguments += value
                block.hasArgumentDeltas = true
            default: throw AIClientError.invalidResponse
            }
            anthropicBlocks[index] = block
            return events
        case "content_block_stop":
            guard let index = root["index"] as? Int, var block = anthropicBlocks[index], !block.stopped else {
                throw AIClientError.invalidResponse
            }
            block.stopped = true
            anthropicBlocks[index] = block
            return []
        case "message_delta":
            guard let delta = root["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String,
                  anthropicStopReason == nil else { throw AIClientError.invalidResponse }
            guard ["end_turn", "tool_use", "stop_sequence"].contains(reason) else {
                throw incomplete(reason == "max_tokens" ? "达到输出长度限制，请提高输出上限或缩短请求后重试" : "供应商未完成消息（\(reason)），请重试")
            }
            anthropicStopReason = reason
            return []
        case "message_stop":
            guard anthropicStopReason != nil, !anthropicBlocks.isEmpty,
                  anthropicBlocks.values.allSatisfy(\.stopped) else { throw incomplete("消息或内容块未完成，请重试") }
            completed = true
            _ = try finish()
            return []
        default: throw AIClientError.invalidResponse
        }
    }

    private func eventType(_ root: [String: Any], event: String?) throws -> String {
        guard let type = root["type"] as? String, !type.isEmpty, event == nil || event == type else {
            throw AIClientError.invalidResponse
        }
        return type
    }

    private func optionalString(_ object: [String: Any], key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw AIClientError.invalidResponse }
        return string
    }

    private func decode(_ object: [String: Any]) throws -> AIChatResult {
        try AIProviderTransport.decode(JSONSerialization.data(withJSONObject: object), format: format, apiKey: apiKey)
    }

    private func incomplete(_ message: String) -> AIClientError {
        let data = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
        return .providerResponseFailed(AIProviderTransport.failureMessage(data, apiKey: apiKey))
    }
}
