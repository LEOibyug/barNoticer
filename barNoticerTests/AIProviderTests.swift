import AppKit
import SwiftUI
import XCTest
@testable import barNoticer

@MainActor
final class AIProviderTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    override func setUp() {
        super.setUp()
        suite = "ProviderTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        ProviderURLProtocol.handler = nil
        ProviderURLProtocol.requests = []
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func provider(_ name: String, format: AIResponseFormat = .chatCompletions) -> AIProviderConfiguration {
        .init(name: name, baseURL: "https://\(name).example/v1", responseFormat: format, apiKey: "key-\(name)", model: "model-\(name)")
    }
    private func client() -> AIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderURLProtocol.self]
        return AIClient(session: URLSession(configuration: config))
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }


    func testMigrationPersistsIndependentProfilesAndEditingDoesNotChangeActiveRoute() throws {
        AISettings(baseURL: URL(string: "https://legacy.example/v1")!, model: "legacy", requiresActionConfirmation: false).save(to: defaults)
        AIAPIKeyStore(defaults: defaults).saveAPIKey("legacy-key")
        var draft = AISettingsDraft(defaults: defaults, keyStore: AIAPIKeyStore(defaults: defaults))
        XCTAssertEqual(draft.apiKey, "legacy-key")
        let firstID = draft.provider.id
        draft.provider.name = "第一套"
        draft.addProvider()
        let secondID = draft.provider.id
        draft.baseURLText = "https://second.example/v1"
        draft.apiKey = "second-key"
        draft.model = "second-model"
        draft.provider.responseFormat = .responses
        XCTAssertEqual(AISettings(defaults: defaults).providerRoutes?.first?.id, firstID)
        draft.setMode(.ordered)
        draft.moveProvider(by: -1)
        let restored = AIProviderCollection.load(from: defaults)
        XCTAssertEqual(restored.providers.map(\.id), [secondID, firstID])
        XCTAssertEqual(restored.providers.map(\.apiKey), ["second-key", "legacy-key"])
        XCTAssertEqual(restored.providers.first?.responseFormat, .responses)
        draft.setMode(.single)
        draft.setActive(secondID)
        XCTAssertEqual(AISettings(defaults: defaults).providerRoutes?.map(\.id), [secondID])
        XCTAssertFalse(AISettings(defaults: defaults).requiresActionConfirmation)
        draft.removeProvider()
        XCTAssertEqual(AISettings(defaults: defaults).providerRoutes?.map(\.id), [firstID])
    }

    func testInvalidProviderURLIsNotReplacedWithDefaultOrSent() async throws {
        for value in ["", "file:///tmp/key", "https://", "https://name:secret@example.com/v1", "https://example.com/v1?key=secret"] {
            var p = provider("bad"); p.baseURL = value
            XCTAssertFalse(p.canDiscover)
            var settings = AISettings(); settings.providerRoutes = [p]
            do { _ = try await client().send(messages: [.init(role: "user", content: "hello")], settings: settings, apiKey: "unused"); XCTFail("Expected rejection") }
            catch { }
        }
        XCTAssertTrue(ProviderURLProtocol.requests.isEmpty)
    }

    func testOrderedFallbackUsesEachProfilesOwnURLKeyModelAndProtocol() async throws {
        let first = provider("first")
        var second = provider("second", format: .responses); second.reasoningEffort = .high
        var settings = AISettings(); settings.providerRoutes = [first, second]
        ProviderURLProtocol.handler = { request in
            if request.url?.host == "first.example" { return (401, ["error": "unauthorized"]) }
            return (200, ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "success"]]]]])
        }
        let result = try await client().send(messages: [.init(role: "user", content: "hello")], settings: settings, apiKey: "wrong-key", tools: [])
        XCTAssertEqual(result.content, "success")
        XCTAssertEqual(ProviderURLProtocol.requests.map { $0.url?.path }, ["/v1/chat/completions", "/v1/responses"])
        XCTAssertEqual(ProviderURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer key-first", "Bearer key-second"])
        XCTAssertEqual(try body(ProviderURLProtocol.requests[1])["model"] as? String, "model-second")
        XCTAssertEqual((try body(ProviderURLProtocol.requests[1])["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    }

    func testResponsesReasoningOnlyResultsRemainUsableWithoutInventedText() async throws {
        let api = client()
        let settings = AISettings(responseFormat: .responses)
        for summary in [[], [["type": "summary_text", "text": "returned summary"]]] as [[[String: String]]] {
            ProviderURLProtocol.handler = { _ in
                (200, ["status": "completed", "error": NSNull(), "output": [
                    ["type": "reasoning", "id": "r1", "summary": summary, "encrypted_content": "opaque-only"]
                ]])
            }
            let result = try await api.send(messages: [.init(role: "user", content: "question")], settings: settings, apiKey: "key", tools: [])
            XCTAssertTrue(result.content.isEmpty)
            XCTAssertTrue(result.toolCalls.isEmpty)
            XCTAssertEqual(result.reasoningContent, summary.isEmpty ? nil : "returned summary")
            XCTAssertEqual(result.responseItems?.count, 1)
        }
    }

    func testResponsesRejectsNonterminalAndPartialResultsAtClientBoundary() async throws {
        let api = client()
        let output: [[String: Any]] = [
            ["type": "message", "content": [["type": "output_text", "text": "partial"]]],
            ["type": "function_call", "call_id": "c1", "name": "complete_todo", "arguments": "{}"]
        ]
        for status in ["failed", "incomplete", "in_progress", "queued", "cancelled"] {
            ProviderURLProtocol.handler = { _ in
                (200, ["status": status, "output": output, "incomplete_details": ["reason": "max_output_tokens"]])
            }
            do {
                _ = try await api.send(messages: [], settings: AISettings(responseFormat: .responses), apiKey: "key", tools: [])
                XCTFail("Must reject \(status), including partial tool calls")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(status))
                if status == "incomplete" { XCTAssertTrue(error.localizedDescription.contains("max_output_tokens")) }
            }
        }
        ProviderURLProtocol.handler = { _ in
            (200, ["status": "completed", "output": [["type": "message", "status": "incomplete",
                "content": [["type": "output_text", "text": "partial"]]]]])
        }
        do {
            _ = try await api.send(messages: [], settings: AISettings(responseFormat: .responses), apiKey: "key", tools: [])
            XCTFail("Must reject incomplete output items")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
    }

    func testDirectResponsesReplayIsScopedToActualProviderRoute() async throws {
        let api = client()
        let first = AISettings(baseURL: URL(string: "https://first.example/v1")!, responseFormat: .responses)
        let second = AISettings(baseURL: URL(string: "https://second.example/v1")!, responseFormat: .responses)
        ProviderURLProtocol.handler = { _ in
            (200, ["status": "completed", "output": [
                ["type": "reasoning", "id": "r1", "summary": [], "encrypted_content": "route-private"],
                ["type": "function_call", "id": "f1", "call_id": "c1", "name": "list_active_todos", "arguments": "{}"]
            ]])
        }
        let result = try await api.send(messages: [.init(role: "user", content: "tasks")], settings: first, apiKey: "key", tools: [])
        let history: [AIChatMessage] = [.init(role: "assistant", content: result.content, toolCalls: result.toolCalls,
            responseItems: result.responseItems, responseProviderID: result.responseProviderID),
            .init(role: "tool", content: "list", toolCallID: "c1")]
        ProviderURLProtocol.handler = { _ in
            (200, ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "done"]]]]])
        }
        _ = try await api.send(messages: history, settings: first, apiKey: "key", tools: [])
        _ = try await api.send(messages: history, settings: second, apiKey: "key", tools: [])
        let same = String(decoding: try JSONSerialization.data(withJSONObject: body(ProviderURLProtocol.requests[1])), as: UTF8.self)
        let other = String(decoding: try JSONSerialization.data(withJSONObject: body(ProviderURLProtocol.requests[2])), as: UTF8.self)
        XCTAssertTrue(same.contains("route-private"))
        XCTAssertFalse(other.contains("route-private"))
        XCTAssertTrue(other.contains("function_call_output"))
        XCTAssertTrue(other.contains("c1"))
    }

    func testHTTPFailureSurfacesBoundedProviderDiagnosticWithoutCredentialsOrRequestBody() async throws {
        let secret = "actual-provider-secret"
        ProviderURLProtocol.handler = { _ in
            (400, ["error": ["message": "Unsupported reasoning_effort high; \(secret); Bearer hidden-token; sk-other-secret " + String(repeating: "detail ", count: 150),
                "code": "unsupported_parameter", "param": "reasoning_effort"], "request": ["prompt": "private user prompt"]])
        }
        do {
            _ = try await client().send(messages: [.init(role: "user", content: "private user prompt")],
                settings: AISettings(reasoningEffort: .high), apiKey: secret, tools: [])
            XCTFail("Expected provider rejection")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("400"))
            XCTAssertTrue(message.contains("Unsupported reasoning_effort high"))
            XCTAssertFalse(message.contains(secret))
            XCTAssertFalse(message.contains("hidden-token"))
            XCTAssertFalse(message.contains("sk-other-secret"))
            XCTAssertFalse(message.contains("private user prompt"))
            XCTAssertLessThan(message.count, 600)
        }
    }

    func testCompatibleObjectArgumentsReachConsumerAndMalformedStringsRemainIntact() async throws {
        let api = client()
        let cases: [(arguments: Any, accepted: Bool)] = [
            (["title": 17], true), ("{broken", true), (NSNull(), false), (42, false), (["array"], false)
        ]
        for format in [AIResponseFormat.chatCompletions, .responses] {
            for entry in cases {
                ProviderURLProtocol.handler = { _ in
                    if format == .chatCompletions {
                        return (200, ["choices": [["message": ["tool_calls": [
                            ["id": "c1", "type": "function", "function": ["name": "create_todo", "arguments": entry.arguments]]
                        ]]]]])
                    }
                    return (200, ["status": "completed", "output": [
                        ["type": "function_call", "call_id": "c1", "name": "create_todo", "arguments": entry.arguments]
                    ]])
                }
                let result: AIChatResult
                do {
                    result = try await api.send(messages: [.init(role: "user", content: "create")],
                        settings: AISettings(responseFormat: format), apiKey: "key", tools: [])
                } catch {
                    if entry.accepted { XCTFail("Expected usable arguments: \(error)") }
                    continue
                }
                guard entry.accepted else { XCTFail("Invalid argument shape must not become an empty object"); continue }
                let call = try XCTUnwrap(result.toolCalls.first)
                XCTAssertEqual(call.id, "c1")
                XCTAssertEqual(call.function.name, "create_todo")
                if let string = entry.arguments as? String {
                    XCTAssertEqual(call.function.arguments, string)
                } else {
                    let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any])
                    XCTAssertEqual(arguments["title"] as? Int, 17, "Invalid field value must reach executor feedback unchanged")
                }
            }
        }
    }

    func testDirectClientPreservesSelectedEffortAndUsesOnlyNativeProtocolParameters() async throws {
        let efforts: [AIReasoningEffort?] = [nil] + AIReasoningEffort.allCases.map { Optional($0) }
        let api = client()
        for format in AIResponseFormat.allCases {
            for effort in efforts {
                ProviderURLProtocol.handler = { _ in
                    switch format {
                    case .chatCompletions: return (200, ["choices": [["message": ["content": "ok"]]]])
                    case .responses: return (200, ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]]])
                    case .anthropic: return (200, ["content": [["type": "text", "text": "ok"]], "stop_reason": "end_turn"])
                    case .gemini: return (200, ["candidates": [["content": ["role": "model", "parts": [["text": "ok"]]], "finishReason": "STOP"]]])
                    }
                }
                _ = try await api.send(messages: [.init(role: "user", content: "hello")],
                    settings: AISettings(responseFormat: format, reasoningEffort: effort), apiKey: "key", tools: [])
                let json = try body(XCTUnwrap(ProviderURLProtocol.requests.last))
                switch format {
                case .chatCompletions:
                    XCTAssertEqual(json["reasoning_effort"] as? String, effort?.rawValue)
                    XCTAssertNil(json["reasoning"])
                case .responses:
                    if let effort {
                        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
                        XCTAssertEqual(reasoning["effort"] as? String, effort.rawValue)
                        XCTAssertEqual(reasoning["summary"] as? String, effort == .none ? nil : "auto")
                    } else {
                        XCTAssertNil(json["reasoning"], "Unconfigured reasoning must not break compatible providers")
                    }
                    XCTAssertNil(json["reasoning_effort"])
                case .anthropic:
                    XCTAssertNil(json["reasoning"])
                    XCTAssertNil(json["reasoning_effort"])
                case .gemini:
                    XCTAssertNil(json["reasoning"])
                    XCTAssertNil(json["reasoning_effort"])
                    XCTAssertNil(json["generationConfig"])
                }
            }
        }
    }

    func testSingleModeDoesNotTryOtherSavedProviderAndCancellationDoesNotFallback() async throws {
        let first = provider("first"), second = provider("second")
        AIProviderCollection(providers: [first, second], activeID: first.id).save(to: defaults)
        ProviderURLProtocol.handler = { _ in (503, ["error": "unavailable"]) }
        do { _ = try await client().send(messages: [], settings: AISettings(defaults: defaults), apiKey: ""); XCTFail() } catch { }
        XCTAssertEqual(ProviderURLProtocol.requests.count, 1)
        ProviderURLProtocol.requests = []
        var settings = AISettings(); settings.providerRoutes = [first, second]
        ProviderURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await client().send(messages: [], settings: settings, apiKey: ""); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ProviderURLProtocol.requests.count, 1)
    }

    func testProtocolsCarryImagesToolCallsAndToolResults() throws {
        let call = AIToolCall(id: "call1", type: "function", function: .init(name: "list_active_todos", arguments: "{}"))
        let messages: [AIChatMessage] = [
            .init(role: "system", content: "policy"),
            .init(role: "user", content: nil, imageURLs: ["data:image/png;base64,aW1hZ2U="]),
            .init(role: "assistant", content: "", toolCalls: [call]),
            .init(role: "tool", content: "result", toolCallID: "call1")
        ]
        for format in AIResponseFormat.allCases {
            let p = provider("wire", format: format)
            let request = try AIProviderTransport.request(messages: messages, settings: p.settings, key: p.apiKey, tools: [AIToolSchema.readGlobalMemoryTool])
            let json = try body(request)
            XCTAssertEqual(
                request.url?.path,
                format == .gemini ? "/v1/models/model-wire:generateContent" : "/v1/" + format.endpoint
            )
            XCTAssertEqual((json["tools"] as? [[String: Any]])?.count, 1)
            switch format {
            case .chatCompletions:
                let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertEqual(sent.last?["tool_call_id"] as? String, "call1")
                XCTAssertEqual((sent[1]["content"] as? [[String: Any]])?.last?["type"] as? String, "image_url")
            case .responses:
                let input = try XCTUnwrap(json["input"] as? [[String: Any]])
                XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
                XCTAssertEqual(input.last?["call_id"] as? String, "call1")
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertEqual((input[1]["content"] as? [[String: Any]])?.first?["type"] as? String, "input_image")
            case .anthropic:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), p.apiKey)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(json["system"] as? String, "policy")
                let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertEqual((sent.last?["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String, "call1")
                XCTAssertEqual((sent[0]["content"] as? [[String: Any]])?.last?["type"] as? String, "image")
            case .gemini:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), p.apiKey)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let systemParts = try XCTUnwrap((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])
                XCTAssertEqual(systemParts.first?["text"] as? String, "policy")
                let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
                let userParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
                XCTAssertEqual((userParts.first?["inlineData"] as? [String: Any])?["mimeType"] as? String, "image/png")
                let toolResponseParts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
                let fnResponse = try XCTUnwrap(toolResponseParts.first?["functionResponse"] as? [String: Any])
                XCTAssertEqual(fnResponse["name"] as? String, "list_active_todos")
                XCTAssertEqual(fnResponse["id"] as? String, "call1")
                XCTAssertEqual((fnResponse["response"] as? [String: Any])?["result"] as? String, "result")
            }
        }
    }

    func testResponsesExtractsTypedAssistantTextAndSummariesAndReplaysCompleteOutput() async throws {
        let p = provider("wire", format: .responses)
        var settings = AISettings(); settings.providerRoutes = [p]
        let output: [[String: Any]] = [
            ["type": "reasoning", "id": "r1", "summary": [
                ["type": "summary_text", "text": "summary one"],
                ["type": "unknown", "text": "not a summary"],
                ["type": "summary_text", "text": "summary two"]
            ], "encrypted_content": "opaque", "provider_extension": ["tokens": [1, 2, 3]]],
            ["type": "provider_trace", "content": [["type": "output_text", "text": "not a message"]]],
            ["type": "message", "role": "user", "content": [["type": "output_text", "text": "not assistant"]]],
            ["type": "message", "role": "assistant", "id": "m1", "status": "completed", "content": [
                ["type": "output_text", "text": "visible", "annotations": [["type": "custom", "value": "retained"]]],
                ["type": "input_text", "text": "not output"],
                ["type": "refusal", "refusal": "refusal"]
            ]],
            ["type": "function_call", "id": "f1", "call_id": "c1", "name": "list_active_todos", "arguments": "{}"]
        ]
        ProviderURLProtocol.handler = { _ in (200, ["status": "completed", "error": NSNull(), "output": output]) }
        let api = client()
        let result = try await api.send(messages: [.init(role: "user", content: "tasks")], settings: settings, apiKey: "", tools: [])
        XCTAssertEqual(result.content, "visible\nrefusal")
        XCTAssertEqual(result.reasoningContent, "summary one\nsummary two")
        XCTAssertEqual(result.toolCalls.first?.id, "c1")
        ProviderURLProtocol.handler = { _ in
            (200, ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "done"]]]]])
        }
        _ = try await api.send(messages: [.init(role: "assistant", content: result.content,
            reasoningContent: result.reasoningContent, toolCalls: result.toolCalls, responseItems: result.responseItems,
            responseProviderID: result.responseProviderID), .init(role: "tool", content: "list", toolCallID: "c1")],
            settings: settings, apiKey: "", tools: [])
        let input = try XCTUnwrap(try body(ProviderURLProtocol.requests[1])["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, output.count + 1)
        XCTAssertTrue(NSArray(array: Array(input.prefix(output.count))).isEqual(to: output))
        XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
    }

    func testAnthropicDecodesToolCalls() throws {
        let anthropic: [String: Any] = ["content": [["type": "tool_use", "id": "c2", "name": "complete_todo", "input": ["id": "todo"]]], "stop_reason": "tool_use"]
        let decoded = try AIProviderTransport.decode(JSONSerialization.data(withJSONObject: anthropic), format: .anthropic)
        XCTAssertEqual(decoded.toolCalls.first?.function.name, "complete_todo")
        XCTAssertTrue(decoded.toolCalls.first?.function.arguments.contains("todo") == true)
    }

    func testResponsesFallbackRebuildsToolHistoryWithoutOtherProvidersOpaqueItems() async throws {
        let first = provider("first", format: .responses), second = provider("second", format: .responses)
        var settings = AISettings(); settings.providerRoutes = [first, second]
        ProviderURLProtocol.handler = { _ in
            (200, ["status": "completed", "output": [
                ["type": "reasoning", "id": "private-id", "summary": [], "encrypted_content": "first-only-secret"],
                ["type": "function_call", "id": "private-function", "call_id": "c1", "name": "list_active_todos", "arguments": "{}"]
            ]])
        }
        let api = client()
        let result = try await api.send(messages: [.init(role: "user", content: "tasks")], settings: settings, apiKey: "")
        XCTAssertEqual(result.responseProviderID, first.id)
        ProviderURLProtocol.handler = { request in
            if request.url?.host == "first.example" { return (503, [:]) }
            return (200, ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "done"]]]]])
        }
        let next = try await api.send(messages: [.init(role: "assistant", content: result.content,
            toolCalls: result.toolCalls, responseItems: result.responseItems, responseProviderID: result.responseProviderID),
            .init(role: "tool", content: "task list", toolCallID: "c1")], settings: settings, apiKey: "")
        XCTAssertEqual(next.content, "done")
        let sameProvider = String(data: try JSONSerialization.data(withJSONObject: body(ProviderURLProtocol.requests[1])), encoding: .utf8)!
        let otherProvider = String(data: try JSONSerialization.data(withJSONObject: body(ProviderURLProtocol.requests[2])), encoding: .utf8)!
        XCTAssertTrue(sameProvider.contains("first-only-secret"))
        XCTAssertFalse(otherProvider.contains("first-only-secret"))
        XCTAssertFalse(otherProvider.contains("private-function"))
        XCTAssertTrue(otherProvider.contains("function_call_output"))
        XCTAssertTrue(otherProvider.contains("c1"))
    }

    func testDiscoveryCandidatesAndBalance() async throws {
        ProviderURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("models") == true { return (200, ["data": [["id": "gpt-b"], ["id": "gpt-a"], ["id": "claude"], ["id": "gpt-a"]]]) }
            return (200, ["balance_infos": [["currency": "CNY", "total_balance": "18.25"]]])
        }
        let diagnostics = AIProviderDiagnostics(session: client().session)
        let names = try await diagnostics.models(for: provider("models"))
        XCTAssertEqual(names, ["claude", "gpt-a", "gpt-b"])
        XCTAssertEqual(AIProviderDiagnostics.candidates(in: names, prefix: "GPT-"), ["gpt-a", "gpt-b"])
        let balance = await diagnostics.balance(for: provider("models"))
        XCTAssertEqual(balance, "18.25 CNY")
        XCTAssertNil(AIProviderDiagnostics.parseBalance(["message": "no balance", "quota": 300]))
        ProviderURLProtocol.handler = { _ in (404, [:]) }
        let unavailable = await diagnostics.balance(for: provider("models"))
        XCTAssertNil(unavailable)
    }

    func testModelCandidatesSupportSubstringSegmentTokenAndFuzzyRanking() {
        let models = [
            "claude-sonnet-4",
            "flash-preview",
            "g-1-2-3-4-5-f",
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gpt-4o",
            "gpt-4o-mini",
            "myflash-model",
            "openai/gpt-4o"
        ]

        // 片段与边界匹配，且优先级为 前缀 > 边界词 > 普通子串
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "flash"),
            ["flash-preview", "gemini-2.5-flash", "myflash-model"]
        )
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "mini"),
            ["gpt-4o-mini", "gemini-2.5-pro", "gemini-2.5-flash"]
        )
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "gpt"),
            ["gpt-4o", "gpt-4o-mini", "openai/gpt-4o"]
        )

        // 多词匹配（顺序和乱序均可命中）
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "2.5 flash"),
            ["gemini-2.5-flash"]
        )
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "flash 2.5"),
            ["gemini-2.5-flash"]
        )

        // 模糊子序列匹配，且跨度更紧凑者排前面
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "g25f"),
            ["gemini-2.5-flash", "g-1-2-3-4-5-f"]
        )

        // 空输入返回初始候选；完全相等（忽略大小写）被排除
        XCTAssertEqual(
            AIProviderDiagnostics.candidates(in: models, query: "   ", limit: 3),
            ["claude-sonnet-4", "flash-preview", "g-1-2-3-4-5-f"]
        )
        XCTAssertFalse(
            AIProviderDiagnostics.candidates(in: models, query: "GPT-4O").contains("gpt-4o")
        )
    }

    func testProbeTestsOnlyCurrentConfigAndActuallyValidatesImageContents() async throws {
        let diagnostics = AIProviderDiagnostics(session: client().session)
        ProviderURLProtocol.handler = { request in
            let isVision = String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("image_url")
            return (200, ["choices": [["message": ["content": isVision ? "4321" : "OK"]]]])
        }
        let result = await diagnostics.probe(provider("current"), imageURL: "data:image/png;base64,YQ==", expectedCode: "4321")
        XCTAssertEqual(result.text, "连接可用")
        XCTAssertEqual(result.vision, "已验证，可识别图片")
        XCTAssertEqual(ProviderURLProtocol.requests.count, 2)
        XCTAssertTrue(ProviderURLProtocol.requests.allSatisfy { $0.url?.host == "current.example" })
        let imageRequest = try body(ProviderURLProtocol.requests[1])
        XCTAssertNil(imageRequest["tools"])
        let serialized = String(data: try JSONSerialization.data(withJSONObject: imageRequest), encoding: .utf8)!
        XCTAssertFalse(serialized.contains("4321"), "The answer cannot be disclosed in the text prompt")
        ProviderURLProtocol.handler = { _ in (200, ["choices": [["message": ["content": "OK"]]]]) }
        let noVision = await diagnostics.probe(provider("current"), imageURL: "data:image/png;base64,YQ==", expectedCode: "4321")
        XCTAssertTrue(noVision.vision.hasPrefix("未通过"))
    }

    func testGeminiEndpointNormalizationAndToolSchemaRules() throws {
        let baseURLs = [
            "https://generativelanguage.googleapis.com",
            "https://generativelanguage.googleapis.com/v1beta",
            "https://generativelanguage.googleapis.com/v1beta/models",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent"
        ]
        for rawBase in baseURLs {
            let base = try XCTUnwrap(URL(string: rawBase))
            let unary = AIProviderTransport.endpoint(base: base, format: .gemini, model: "models/gemini-2.5-flash", stream: false)
            XCTAssertEqual(unary.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
            let stream = AIProviderTransport.endpoint(base: base, format: .gemini, model: "models/gemini-2.5-flash", stream: true)
            XCTAssertEqual(stream.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        }

        let settings = AISettings(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            model: "gemini-2.5-flash",
            responseFormat: .gemini
        )
        let request = try AIProviderTransport.request(
            messages: [.init(role: "user", content: "列出事项")],
            settings: settings,
            key: "AIza-schema-test",
            tools: AIToolSchema.openAICompatibleTools
        )
        let json = try body(request)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        let readMemory = try XCTUnwrap(declarations.first { $0["name"] as? String == "read_global_memory" })
        XCTAssertNil(readMemory["parameters"], "Parameterless Gemini functions must omit empty OBJECT parameters")
        let createTodo = try XCTUnwrap(declarations.first { $0["name"] as? String == "create_todo" })
        let params = try XCTUnwrap(createTodo["parameters"] as? [String: Any])
        XCTAssertNotNil(params["properties"])
    }

    func testGeminiEnvironmentAPIKeyResolutionManualFallbackAndSecretRedaction() async throws {
        let envSecret = "AIzaSyEnvSecretValue999"
        let manualSecret = "AIzaSyManualSecretValue111"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderURLProtocol.self]

        var envProvider = AIProviderConfiguration(
            name: "Gemini Env",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            responseFormat: .gemini,
            apiKeySource: .environment,
            apiKey: manualSecret,
            model: "gemini-2.5-flash"
        )
        var settings = AISettings()
        settings.providerRoutes = [envProvider]

        ProviderURLProtocol.handler = { _ in
            (200, ["candidates": [["content": ["role": "model", "parts": [["text": "env ok"]]], "finishReason": "STOP"]]])
        }
        let envClient = AIClient(
            session: URLSession(configuration: config),
            environment: [AIEnvironmentAPIKey.geminiVariableName: " \(envSecret) "]
        )
        let envResult = try await envClient.send(messages: [.init(role: "user", content: "hi")], settings: settings, apiKey: "", tools: [])
        XCTAssertEqual(envResult.content, "env ok")
        XCTAssertEqual(ProviderURLProtocol.requests.last?.value(forHTTPHeaderField: "x-goog-api-key"), envSecret)
        XCTAssertNil(ProviderURLProtocol.requests.last?.url?.query)

        // 手动输入模式优先使用手动 Key，即使环境变量也存在
        envProvider.apiKeySource = .manual
        settings.providerRoutes = [envProvider]
        let manualResult = try await envClient.send(messages: [.init(role: "user", content: "hi")], settings: settings, apiKey: "", tools: [])
        XCTAssertEqual(manualResult.content, "env ok")
        XCTAssertEqual(ProviderURLProtocol.requests.last?.value(forHTTPHeaderField: "x-goog-api-key"), manualSecret)

        // 缺少环境变量时报错且不发请求
        ProviderURLProtocol.requests = []
        envProvider.apiKeySource = .environment
        settings.providerRoutes = [envProvider]
        let missingClient = AIClient(session: URLSession(configuration: config), environment: [:])
        do {
            _ = try await missingClient.send(messages: [.init(role: "user", content: "hi")], settings: settings, apiKey: "", tools: [])
            XCTFail("Expected missingEnvironmentAPIKey")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("GEMINI_API_KEY"))
        }
        XCTAssertTrue(ProviderURLProtocol.requests.isEmpty)

        // HTTP 错误支持 JSON 数组包裹响应，且隐藏 AIza... 与当前 Key
        ProviderURLProtocol.handler = { _ in
            (400, ["error": ["message": "API key \(envSecret) invalid; also AIzaSyOtherLeak123", "status": "INVALID_ARGUMENT"]])
        }
        do {
            _ = try await envClient.send(messages: [.init(role: "user", content: "hi")], settings: settings, apiKey: "", tools: [])
            XCTFail("Expected error")
        } catch {
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("400"))
            XCTAssertTrue(msg.contains("INVALID_ARGUMENT"))
            XCTAssertFalse(msg.contains(envSecret))
            XCTAssertFalse(msg.contains("AIzaSyOtherLeak123"))
        }

        let arrayErrorData = try JSONSerialization.data(withJSONObject: [["error": ["message": "bad AIzaSyArrayKey888", "status": "PERMISSION_DENIED"]]])
        let arrayMessage = AIProviderTransport.failureMessage(arrayErrorData, apiKey: envSecret)
        XCTAssertTrue(arrayMessage.contains("PERMISSION_DENIED"))
        XCTAssertFalse(arrayMessage.contains("AIzaSyArrayKey888"))
    }

    func testGeminiThoughtPartsSignatureReplayAndCrossProviderFallback() async throws {
        let first = provider("first", format: .gemini)
        let second = provider("second", format: .gemini)
        var settings = AISettings()
        settings.providerRoutes = [first, second]

        ProviderURLProtocol.handler = { _ in
            (200, ["candidates": [[
                "content": ["role": "model", "parts": [
                    ["text": "内部思考", "thought": true],
                    ["thoughtSignature": "opaque-thought-sig", "functionCall": ["name": "list_active_todos", "args": [:]]]
                ]],
                "finishReason": "STOP"
            ]]])
        }
        let api = client()
        let firstResult = try await api.send(messages: [.init(role: "user", content: "tasks")], settings: settings, apiKey: "")
        XCTAssertEqual(firstResult.reasoningContent, "内部思考")
        XCTAssertEqual(firstResult.toolCalls.first?.function.name, "list_active_todos")
        XCTAssertEqual(firstResult.responseProviderID, first.id)

        ProviderURLProtocol.handler = { request in
            if request.url?.host == "first.example" { return (503, ["error": ["message": "down"]]) }
            return (200, ["candidates": [["content": ["role": "model", "parts": [["text": "done"]]], "finishReason": "STOP"]]])
        }
        let toolCallID = try XCTUnwrap(firstResult.toolCalls.first?.id)
        let followUp: [AIChatMessage] = [
            .init(role: "user", content: "tasks"),
            .init(
                role: "assistant",
                content: firstResult.content,
                reasoningContent: firstResult.reasoningContent,
                toolCalls: firstResult.toolCalls,
                responseItems: firstResult.responseItems,
                responseProviderID: firstResult.responseProviderID
            ),
            .init(role: "tool", content: "list", toolCallID: toolCallID)
        ]
        let nextResult = try await api.send(messages: followUp, settings: settings, apiKey: "")
        XCTAssertEqual(nextResult.content, "done")

        let sameProviderBody = String(decoding: try JSONSerialization.data(withJSONObject: body(ProviderURLProtocol.requests[1])), as: UTF8.self)
        let fallbackProviderBody = String(decoding: try JSONSerialization.data(withJSONObject: body(ProviderURLProtocol.requests[2])), as: UTF8.self)
        XCTAssertTrue(sameProviderBody.contains("opaque-thought-sig"))
        XCTAssertFalse(fallbackProviderBody.contains("opaque-thought-sig"))
        XCTAssertTrue(fallbackProviderBody.contains("functionResponse"))
        XCTAssertTrue(fallbackProviderBody.contains("list_active_todos"))
        // 原始 functionCall 未提供 id 时，不发送伪造 id
        let fallbackJSON = try body(ProviderURLProtocol.requests[2])
        let contents = try XCTUnwrap(fallbackJSON["contents"] as? [[String: Any]])
        let toolPart = try XCTUnwrap((contents.last?["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])
        XCTAssertNil(toolPart["id"])
    }

    func testGeminiDiscoveryAndBalanceBehavior() async throws {
        var pageCount = 0
        ProviderURLProtocol.handler = { request in
            pageCount += 1
            if pageCount == 1 {
                return (200, [
                    "models": [
                        ["name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent", "countTokens"]],
                        ["name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]]
                    ],
                    "nextPageToken": "page-2"
                ])
            }
            return (200, [
                "models": [
                    ["name": "models/gemini-2.5-pro", "supportedGenerationMethods": ["generateContent"]]
                ]
            ])
        }
        let diagnostics = AIProviderDiagnostics(
            session: client().session,
            environment: [AIEnvironmentAPIKey.geminiVariableName: "AIza-discover-env"]
        )
        let geminiProvider = AIProviderConfiguration(
            name: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            responseFormat: .gemini,
            apiKeySource: .environment,
            model: "gemini-2.5-flash"
        )
        let names = try await diagnostics.models(for: geminiProvider)
        XCTAssertEqual(names, ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertEqual(ProviderURLProtocol.requests.count, 2)
        XCTAssertTrue(ProviderURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-discover-env" })
        XCTAssertTrue(ProviderURLProtocol.requests[1].url?.query?.contains("pageToken=page-2") == true)

        ProviderURLProtocol.requests = []
        let balance = await diagnostics.balance(for: geminiProvider)
        XCTAssertNil(balance)
        XCTAssertTrue(ProviderURLProtocol.requests.isEmpty)
    }

    func testGeminiProbeTextAndVision() async throws {
        let diagnostics = AIProviderDiagnostics(
            session: client().session,
            environment: [AIEnvironmentAPIKey.geminiVariableName: "AIza-probe-env"]
        )
        ProviderURLProtocol.handler = { request in
            let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let isVision = text.contains("inlineData")
            return (200, ["candidates": [["content": ["role": "model", "parts": [["text": isVision ? "8765" : "OK"]]], "finishReason": "STOP"]]])
        }
        let geminiProvider = AIProviderConfiguration(
            name: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            responseFormat: .gemini,
            apiKeySource: .environment,
            model: "gemini-2.5-flash"
        )
        let result = await diagnostics.probe(geminiProvider, imageURL: "data:image/png;base64,YQ==", expectedCode: "8765")
        XCTAssertEqual(result.text, "连接可用")
        XCTAssertEqual(result.vision, "已验证，可识别图片")
        XCTAssertEqual(ProviderURLProtocol.requests.count, 2)
        XCTAssertEqual(ProviderURLProtocol.requests[0].value(forHTTPHeaderField: "x-goog-api-key"), "AIza-probe-env")
        XCTAssertEqual(ProviderURLProtocol.requests[0].url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
    }
}

private final class ProviderURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; data.append(buffer, count: n)
            }
            request.httpBody = data
        }
        Self.requests.append(request)
        do {
            let (status, body) = try Self.handler?(request) ?? (500, [:])
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
