import CryptoKit
import Foundation

/// Wire adapters keep vendor payloads out of task execution and approval policy.
enum AIProviderTransport {
    static func endpoint(base: URL, format: AIResponseFormat, path: String? = nil) -> URL {
        var root = base
        for suffix in ["chat/completions", "responses", "messages"] {
            let path = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == suffix || path.hasSuffix("/" + suffix) {
                for _ in suffix.split(separator: "/") { root.deleteLastPathComponent() }
                break
            }
        }
        return root.appendingPathComponent(path ?? format.endpoint)
    }

    static func request(messages: [AIChatMessage], settings: AISettings, key: String,
                        tools: [AIToolDefinition], maxTokens: Int? = nil, providerID: UUID? = nil,
                        stream: Bool = false) throws -> URLRequest {
        guard settings.isValid else { throw AIClientError.invalidSettings }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIClientError.missingAPIKey }
        var request = URLRequest(url: endpoint(base: settings.baseURL, format: settings.responseFormat))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        authorize(&request, key: key, format: settings.responseFormat)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": settings.model]
        if stream {
            body["stream"] = true
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        switch settings.responseFormat {
        case .chatCompletions:
            body["messages"] = try object(messages)
            if let effort = settings.reasoningEffort { body["reasoning_effort"] = effort.rawValue }
            if !tools.isEmpty { body["tools"] = try object(tools) }
            if let maxTokens { body["max_tokens"] = maxTokens }
        case .responses:
            body["store"] = false
            body["include"] = ["reasoning.encrypted_content"]
            body["input"] = try responsesInput(messages, providerID: providerID ?? responseProviderID(settings: settings, key: key))
            if let effort = settings.reasoningEffort {
                var reasoning: [String: Any] = ["effort": effort.rawValue]
                if effort != .none { reasoning["summary"] = "auto" }
                body["reasoning"] = reasoning
            }
            if !tools.isEmpty {
                body["tools"] = try tools.map { tool in
                    ["type": "function", "name": tool.function.name,
                     "description": tool.function.description, "parameters": try object(tool.function.parameters),
                     "strict": false] as [String: Any]
                }
            }
            if let maxTokens { body["max_output_tokens"] = maxTokens }
        case .anthropic:
            body["max_tokens"] = maxTokens ?? 4096
            body["system"] = messages.filter { $0.role == "system" }.compactMap(\.content).joined(separator: "\n\n")
            body["messages"] = try anthropicMessages(messages)
            if !tools.isEmpty {
                body["tools"] = try tools.map { tool in
                    ["name": tool.function.name, "description": tool.function.description,
                     "input_schema": try object(tool.function.parameters)] as [String: Any]
                }
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func authorize(_ request: inout URLRequest, key: String, format: AIResponseFormat) {
        if format == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    static func decode(_ data: Data, format: AIResponseFormat, apiKey: String = "") throws -> AIChatResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse
        }
        if root["error"] != nil, !(root["error"] is NSNull) {
            throw AIClientError.providerResponseFailed(failureMessage(data, apiKey: apiKey))
        }
        switch format {
        case .chatCompletions:
            guard let choices = root["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
                throw AIClientError.invalidResponse
            }
            let calls = try (message["tool_calls"] as? [[String: Any]] ?? []).map { call in
                guard let id = call["id"] as? String, let type = call["type"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { throw AIClientError.invalidResponse }
                return AIToolCall(id: id, type: type,
                    function: .init(name: name, arguments: try toolArguments(function["arguments"])))
            }
            guard message["content"] is String || !calls.isEmpty else { throw AIClientError.invalidResponse }
            return AIChatResult(content: message["content"] as? String ?? "",
                reasoningContent: message["reasoning_content"] as? String, toolCalls: calls)
        case .responses:
            if let status = root["status"] as? String, status != "completed" {
                let reason = (root["incomplete_details"] as? [String: Any])?["reason"] as? String
                throw AIClientError.providerResponseFailed("响应未完成（\(safeDiagnostic([status, reason].compactMap { $0 }.joined(separator: ": "), apiKey: apiKey))）")
            }
            guard let output = root["output"] as? [[String: Any]] else { throw AIClientError.invalidResponse }
            var texts: [String] = [], summaries: [String] = [], calls: [AIToolCall] = []
            var hasReasoning = false
            for item in output {
                if let status = item["status"] as? String, status != "completed" {
                    throw AIClientError.providerResponseFailed("响应项目未完成（\(safeDiagnostic(status, apiKey: apiKey))）")
                }
                switch item["type"] as? String {
                case "function_call":
                    guard let id = item["call_id"] as? String, let name = item["name"] as? String else {
                        throw AIClientError.invalidResponse
                    }
                    calls.append(.init(id: id, type: "function",
                        function: .init(name: name, arguments: try toolArguments(item["arguments"]))))
                case "reasoning":
                    hasReasoning = true
                    for part in item["summary"] as? [[String: Any]] ?? [] where part["type"] as? String == "summary_text" {
                        if let text = part["text"] as? String, !text.isEmpty { summaries.append(text) }
                    }
                case "message":
                    guard item["role"] == nil || item["role"] as? String == "assistant" else { continue }
                    for part in item["content"] as? [[String: Any]] ?? [] {
                        switch part["type"] as? String {
                        case "output_text": if let text = part["text"] as? String { texts.append(text) }
                        case "refusal": if let refusal = part["refusal"] as? String { texts.append(refusal) }
                        default: break
                        }
                    }
                default: break
                }
            }
            guard !texts.isEmpty || !calls.isEmpty || hasReasoning else { throw AIClientError.invalidResponse }
            let items = try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: output))
            return AIChatResult(content: texts.joined(separator: "\n"),
                reasoningContent: summaries.isEmpty ? nil : summaries.joined(separator: "\n"), toolCalls: calls, responseItems: items)
        case .anthropic:
            guard let blocks = root["content"] as? [[String: Any]], root["stop_reason"] as? String != "max_tokens" else {
                throw AIClientError.invalidResponse
            }
            var texts: [String] = [], calls: [AIToolCall] = []
            for block in blocks {
                if let text = block["text"] as? String { texts.append(text) }
                if block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String,
                          let input = block["input"] as? [String: Any] else { throw AIClientError.invalidResponse }
                    let args = try JSONSerialization.data(withJSONObject: input)
                    calls.append(.init(id: id, type: "function", function: .init(name: name, arguments: String(decoding: args, as: UTF8.self))))
                }
            }
            guard !texts.isEmpty || !calls.isEmpty else { throw AIClientError.invalidResponse }
            return AIChatResult(content: texts.joined(separator: "\n"), toolCalls: calls)
        }
    }

    private static func toolArguments(_ value: Any?) throws -> String {
        if let text = value as? String { return text }
        guard let object = value as? [String: Any] else { throw AIClientError.invalidResponse }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func responseProviderID(settings: AISettings, key: String) -> UUID {
        // Direct callers have no saved profile UUID; scope opaque items to their actual route.
        let scope = [settings.baseURL.absoluteString, settings.responseFormat.rawValue, settings.model,
                     key.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\0")
        return SHA256.hash(data: Data(scope.utf8)).withUnsafeBytes { bytes in
            UUID(uuid: bytes.load(as: uuid_t.self))
        }
    }

    private static func responsesInput(_ messages: [AIChatMessage], providerID: UUID?) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            if message.role == "assistant", message.responseProviderID == providerID, let items = message.responseItems {
                input += try object(items) as? [[String: Any]] ?? []
                continue
            }
            if message.role == "tool" {
                input.append(["type": "function_call_output", "call_id": message.toolCallID ?? "", "output": message.content ?? ""])
                continue
            }
            var parts: [[String: Any]] = []
            if let text = message.content, !text.isEmpty {
                parts.append(["type": message.role == "assistant" ? "output_text" : "input_text", "text": text])
            }
            parts += message.imageURLs.map { ["type": "input_image", "image_url": $0] }
            if !parts.isEmpty { input.append(["role": message.role, "content": parts]) }
            for call in message.toolCalls ?? [] {
                input.append(["type": "function_call", "call_id": call.id, "name": call.function.name, "arguments": call.function.arguments])
            }
        }
        return input
    }

    private static func anthropicMessages(_ messages: [AIChatMessage]) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages where message.role != "system" {
            let role = message.role == "assistant" ? "assistant" : "user"
            var blocks: [[String: Any]] = []
            if message.role == "tool" {
                blocks.append(["type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": message.content ?? ""])
            } else {
                if let text = message.content, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for url in message.imageURLs {
                    if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
                        let mime = url.dropFirst(5).prefix { $0 != ";" }
                        blocks.append(["type": "image", "source": ["type": "base64", "media_type": String(mime), "data": String(url[url.index(after: comma)...])]])
                    } else {
                        blocks.append(["type": "image", "source": ["type": "url", "url": url]])
                    }
                }
                for call in message.toolCalls ?? [] {
                    let args = try JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.function.name, "input": args])
                }
            }
            if blocks.isEmpty { continue }
            // Tool results in a batch must share the user turn immediately following tool_use.
            if result.last?["role"] as? String == role {
                var last = result.removeLast()
                last["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
                result.append(last)
            } else { result.append(["role": role, "content": blocks]) }
        }
        return result
    }

    static func failureMessage(_ data: Data, apiKey: String = "") -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "供应商未能完成请求，请检查模型、协议、推理设置和 API Key"
        }
        let error = root["error"] as? [String: Any]
        let message = error?["message"] as? String ?? root["message"] as? String ?? root["error"] as? String
        let details = [message, error?["code"] as? String, error?["param"] as? String].compactMap { $0 }
        guard !details.isEmpty else { return "供应商未能完成请求，请检查模型、协议、推理设置和 API Key" }
        return safeDiagnostic(details.joined(separator: " · "), apiKey: apiKey)
    }

    private static func safeDiagnostic(_ text: String, apiKey: String = "") -> String {
        var text = text
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "[已隐藏]") }
        text = text.replacingOccurrences(of: #"(?i)\bBearer\s+\S+|\bsk-[A-Za-z0-9_-]+"#, with: "[已隐藏]", options: .regularExpression)
        text = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(text.prefix(500))
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
