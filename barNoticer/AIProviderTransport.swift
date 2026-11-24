import CryptoKit
import Foundation

/// Wire adapters keep vendor payloads out of task execution and approval policy.
enum AIProviderTransport {
    static func endpoint(base: URL, format: AIResponseFormat, model: String = "", path: String? = nil, stream: Bool = false) -> URL {
        var root = base
        let trimmedPath = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = trimmedPath.split(separator: "/")
        if pathComponents.count >= 2,
           pathComponents[pathComponents.count - 2] == "models",
           let last = pathComponents.last,
           last.hasSuffix(":generateContent") || last.hasSuffix(":streamGenerateContent") {
            root.deleteLastPathComponent()
            root.deleteLastPathComponent()
        } else {
            for suffix in ["chat/completions", "responses", "messages", "models"] {
                if trimmedPath == suffix || trimmedPath.hasSuffix("/" + suffix) {
                    for _ in suffix.split(separator: "/") { root.deleteLastPathComponent() }
                    break
                }
            }
        }
        if format == .gemini,
           root.host?.lowercased() == "generativelanguage.googleapis.com",
           root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            root = root.appendingPathComponent("v1beta")
        }
        if let path {
            return root.appendingPathComponent(path)
        }
        if format == .gemini {
            var normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedModel.hasPrefix("models/") {
                normalizedModel.removeFirst("models/".count)
            }
            let action = stream ? "streamGenerateContent" : "generateContent"
            var url = root
                .appendingPathComponent("models")
                .appendingPathComponent("\(normalizedModel):\(action)")
            if stream, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: "alt", value: "sse"))
                components.queryItems = items
                url = components.url ?? url
            }
            return url
        }
        return root.appendingPathComponent(format.endpoint)
    }

    static func request(messages: [AIChatMessage], settings: AISettings, key: String,
                        tools: [AIToolDefinition], maxTokens: Int? = nil, providerID: UUID? = nil,
                        stream: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URLRequest {
        guard settings.isValid else { throw AIClientError.invalidSettings }
        var resolvedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedKey.isEmpty, settings.responseFormat == .gemini, settings.apiKeySource == .environment {
            resolvedKey = AIEnvironmentAPIKey.geminiAPIKey(in: environment)
        }
        guard !resolvedKey.isEmpty else {
            throw settings.responseFormat == .gemini && settings.apiKeySource == .environment
                ? AIClientError.missingEnvironmentAPIKey(AIEnvironmentAPIKey.geminiVariableName)
                : AIClientError.missingAPIKey
        }
        var request = URLRequest(url: endpoint(base: settings.baseURL, format: settings.responseFormat, model: settings.model, stream: stream))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        authorize(&request, key: resolvedKey, format: settings.responseFormat)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if settings.responseFormat != .gemini {
            body["model"] = settings.model
            if stream { body["stream"] = true }
        }
        if stream {
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
            body["input"] = try responsesInput(messages, providerID: providerID ?? responseProviderID(settings: settings, key: resolvedKey))
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
        case .gemini:
            let systemText = messages.filter { $0.role == "system" }
                .compactMap(\.content)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if !systemText.isEmpty {
                body["systemInstruction"] = ["parts": [["text": systemText]]]
            }
            body["contents"] = try geminiContents(
                messages,
                providerID: providerID ?? responseProviderID(settings: settings, key: resolvedKey)
            )
            if !tools.isEmpty {
                let declarations = try tools.map { tool -> [String: Any] in
                    var declaration: [String: Any] = [
                        "name": tool.function.name,
                        "description": tool.function.description
                    ]
                    if var parameters = try object(tool.function.parameters) as? [String: Any],
                       let properties = parameters["properties"] as? [String: Any],
                       !properties.isEmpty {
                        if let required = parameters["required"] as? [Any], required.isEmpty {
                            parameters.removeValue(forKey: "required")
                        }
                        declaration["parameters"] = parameters
                    }
                    return declaration
                }
                body["tools"] = [["functionDeclarations": declarations]]
            }
            if let maxTokens {
                body["generationConfig"] = ["maxOutputTokens": maxTokens]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func authorize(_ request: inout URLRequest, key: String, format: AIResponseFormat) {
        switch format {
        case .chatCompletions, .responses:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
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
        case .gemini:
            guard let candidates = root["candidates"] as? [[String: Any]], let candidate = candidates.first else {
                if let blockReason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String,
                   !blockReason.isEmpty {
                    throw AIClientError.providerResponseFailed("请求被安全策略拦截（\(safeDiagnostic(blockReason, apiKey: apiKey))）")
                }
                throw AIClientError.invalidResponse
            }
            if let finishReason = candidate["finishReason"] as? String,
               !finishReason.isEmpty,
               finishReason != "STOP",
               finishReason != "FINISH_REASON_UNSPECIFIED" {
                if finishReason == "MAX_TOKENS" {
                    throw AIClientError.providerResponseFailed("达到输出长度限制，请提高输出上限或缩短请求后重试")
                }
                throw AIClientError.providerResponseFailed("输出被供应商中止（\(safeDiagnostic(finishReason, apiKey: apiKey))）")
            }
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw AIClientError.invalidResponse
            }
            var texts: [String] = []
            var thoughts: [String] = []
            var calls: [AIToolCall] = []
            var hasReasoning = false
            for part in parts {
                if part["thought"] as? Bool == true {
                    hasReasoning = true
                    if let text = part["text"] as? String, !text.isEmpty {
                        thoughts.append(text)
                    }
                } else if let text = part["text"] as? String {
                    texts.append(text)
                }
                if let functionCall = part["functionCall"] as? [String: Any] {
                    guard let name = functionCall["name"] as? String, !name.isEmpty else {
                        throw AIClientError.invalidResponse
                    }
                    let explicitID = (functionCall["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let callID = explicitID ?? "gemini-call-\(calls.count)"
                    let args: String
                    if functionCall["args"] == nil || functionCall["args"] is NSNull {
                        args = "{}"
                    } else {
                        args = try toolArguments(functionCall["args"])
                    }
                    calls.append(.init(id: callID, type: "function", function: .init(name: name, arguments: args)))
                }
            }
            guard !texts.isEmpty || !calls.isEmpty || hasReasoning else { throw AIClientError.invalidResponse }
            let items = try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: parts))
            return AIChatResult(
                content: texts.joined(),
                reasoningContent: thoughts.isEmpty ? nil : thoughts.joined(),
                toolCalls: calls,
                responseItems: items
            )
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

    private static func geminiContents(_ messages: [AIChatMessage], providerID: UUID?) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var toolCallMetadata: [String: (name: String, includeID: Bool)] = [:]

        for message in messages where message.role != "system" {
            let role = message.role == "assistant" ? "model" : "user"
            var parts: [[String: Any]] = []

            if message.role == "assistant", message.responseProviderID == providerID, let items = message.responseItems {
                let rawParts = try object(items) as? [[String: Any]] ?? []
                parts += rawParts
                var callIndex = 0
                for rawPart in rawParts {
                    guard let functionCall = rawPart["functionCall"] as? [String: Any],
                          let name = functionCall["name"] as? String else { continue }
                    let explicitID = (functionCall["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let callID = explicitID ?? (callIndex < (message.toolCalls?.count ?? 0) ? message.toolCalls?[callIndex].id : nil)
                    if let callID {
                        toolCallMetadata[callID] = (name: name, includeID: explicitID != nil)
                    }
                    callIndex += 1
                }
            } else if message.role == "tool" {
                let callID = message.toolCallID ?? ""
                let metadata = toolCallMetadata[callID]
                var functionResponse: [String: Any] = [
                    "name": metadata?.name ?? (callID.isEmpty ? "tool" : callID),
                    "response": ["result": message.content ?? ""]
                ]
                if metadata?.includeID == true, !callID.isEmpty {
                    functionResponse["id"] = callID
                }
                parts.append(["functionResponse": functionResponse])
            } else {
                if let text = message.content, !text.isEmpty {
                    parts.append(["text": text])
                }
                for url in message.imageURLs {
                    if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
                        let header = url.dropFirst(5)[..<comma]
                        let mime = header.prefix { $0 != ";" }
                        parts.append([
                            "inlineData": [
                                "mimeType": String(mime),
                                "data": String(url[url.index(after: comma)...])
                            ]
                        ])
                    } else {
                        parts.append(["fileData": ["fileUri": url]])
                    }
                }
                for call in message.toolCalls ?? [] {
                    let parsedArgs = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]
                    var functionCall: [String: Any] = ["name": call.function.name, "args": parsedArgs]
                    let includeID = !call.id.isEmpty && !call.id.hasPrefix("gemini-call-")
                    if includeID {
                        functionCall["id"] = call.id
                    }
                    toolCallMetadata[call.id] = (name: call.function.name, includeID: includeID)
                    parts.append(["functionCall": functionCall])
                }
            }

            if parts.isEmpty { continue }
            if result.last?["role"] as? String == role {
                var last = result.removeLast()
                last["parts"] = (last["parts"] as? [[String: Any]] ?? []) + parts
                result.append(last)
            } else {
                result.append(["role": role, "parts": parts])
            }
        }
        return result
    }

    static func failureMessage(_ data: Data, apiKey: String = "") -> String {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        guard let root = (parsed as? [String: Any]) ?? (parsed as? [[String: Any]])?.first else {
            return "供应商未能完成请求，请检查模型、协议、推理设置和 API Key"
        }
        let error = root["error"] as? [String: Any]
        let message = error?["message"] as? String ?? root["message"] as? String ?? root["error"] as? String
        let details = [message, error?["status"] as? String, error?["code"] as? String, error?["param"] as? String].compactMap { $0 }
        guard !details.isEmpty else { return "供应商未能完成请求，请检查模型、协议、推理设置和 API Key" }
        return safeDiagnostic(details.joined(separator: " · "), apiKey: apiKey)
    }

    private static func safeDiagnostic(_ text: String, apiKey: String = "") -> String {
        var text = text
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "[已隐藏]") }
        text = text.replacingOccurrences(of: #"(?i)\bBearer\s+\S+|\bsk-[A-Za-z0-9_-]+|\bAIza[A-Za-z0-9_-]+"#, with: "[已隐藏]", options: .regularExpression)
        text = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(text.prefix(500))
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
