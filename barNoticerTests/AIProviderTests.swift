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

    func testProviderEditorUsesAlignedFieldsAndRendersPlaceholdersInside() async throws {
        var draft = AISettingsDraft(defaults: defaults, keyStore: AIAPIKeyStore(defaults: defaults))
        draft.provider.name = "个人供应商"
        draft.baseURLText = "https://api.example.com/v1"
        draft.apiKey = "test-key"
        draft.model = "model-vision"
        for empty in [false, true] {
            if empty { draft.baseURLText = ""; draft.apiKey = ""; draft.model = "" }
            let host = NSHostingView(rootView: SettingsPage(title: "AI 设置") {
                AIProviderSettingsView(draft: .constant(draft), automaticallyDiscover: false)
            }.environment(\.colorScheme, empty ? .light : .dark))
            host.frame = CGRect(x: 0, y: 0, width: 720, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let inputs = fields(host).filter { $0.isEditable }
            XCTAssertGreaterThanOrEqual(inputs.count, 4)
            let widths = inputs.map { $0.bounds.width }
            if let min = widths.min(), let max = widths.max() { XCTAssertEqual(min, max, accuracy: 2) }
            if empty {
                XCTAssertTrue(inputs.contains { $0.placeholderString == "https://api.openai.com/v1" && $0.stringValue.isEmpty })
            }
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(empty ? "provider-settings-empty.png" : "provider-settings-dark.png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            print("PROVIDER_RENDER=\(url.path)")
        }
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
        let first = provider("first"), second = provider("second", format: .responses)
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
            .init(role: "user", content: "image", imageURLs: ["data:image/png;base64,aW1hZ2U="]),
            .init(role: "assistant", content: "", toolCalls: [call]),
            .init(role: "tool", content: "result", toolCallID: "call1")
        ]
        for format in AIResponseFormat.allCases {
            let p = provider("wire", format: format)
            let request = try AIProviderTransport.request(messages: messages, settings: p.settings, key: p.apiKey, tools: [AIToolSchema.readGlobalMemoryTool])
            let json = try body(request)
            XCTAssertEqual(request.url?.path, "/v1/" + format.endpoint)
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
            case .anthropic:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), p.apiKey)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(json["system"] as? String, "policy")
                let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertEqual((sent.last?["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String, "call1")
                XCTAssertEqual((sent[0]["content"] as? [[String: Any]])?.last?["type"] as? String, "image")
            }
        }
    }

    func testResponsesRetainsReasoningAndAnthropicDecodesCalls() throws {
        let response: [String: Any] = ["status": "completed", "output": [
            ["type": "reasoning", "id": "r1", "summary": [], "encrypted_content": "opaque"],
            ["type": "function_call", "id": "f1", "call_id": "c1", "name": "complete_todo", "arguments": "{}"]
        ]]
        let result = try AIProviderTransport.decode(JSONSerialization.data(withJSONObject: response), format: .responses)
        XCTAssertEqual(result.toolCalls.first?.id, "c1")
        let request = try AIProviderTransport.request(messages: [.init(role: "assistant", content: result.content,
            toolCalls: result.toolCalls, responseItems: result.responseItems), .init(role: "tool", content: "done", toolCallID: "c1")],
            settings: provider("wire", format: .responses).settings, key: "key", tools: [])
        let input = try XCTUnwrap(try body(request)["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input.first?["encrypted_content"] as? String, "opaque")
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
