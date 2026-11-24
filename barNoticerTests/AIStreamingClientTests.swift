import XCTest
@testable import barNoticer

@MainActor
final class AIStreamingClientTests: XCTestCase {
    override func tearDown() {
        StreamingClientURLProtocol.start = nil
        StreamingClientURLProtocol.resume = nil
        StreamingClientURLProtocol.close = nil
        super.tearDown()
    }

    private func client() -> AIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingClientURLProtocol.self]
        return AIClient(session: URLSession(configuration: configuration))
    }

    func testSSEDeliversSplitUTF8BeforeCompletionAndStopsAtTerminalMarker() async throws {
        let firstText = expectation(description: "Partial text arrives while response remains open")
        let complete = expectation(description: "Terminal marker completes without network EOF")
        let stopped = expectation(description: "Completed stream releases its network task")
        var events: [AIStreamEvent] = []
        StreamingClientURLProtocol.start = { transport in
            transport.headers(["Content-Type": "text/event-stream"])
            let payload = Data(": heartbeat\r\n\r\ndata: {\"choices\": [\r\ndata: {\"index\":0,\"delta\":{\"content\":\"你\"}}]}\r\n\r\n".utf8)
            let chinese = try! XCTUnwrap(payload.range(of: Data("你".utf8)))
            transport.push(payload.prefix(chinese.lowerBound + 1))
            transport.push(payload.dropFirst(chinese.lowerBound + 1))
            StreamingClientURLProtocol.resume = { transport.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\n\n") }
            StreamingClientURLProtocol.close = { transport.finish() }
            transport.onStop = { stopped.fulfill() }
        }
        let task = Task {
            let result = try await client().sendStreaming(messages: [.init(role: "user", content: "问候")], settings: AISettings(), apiKey: "test-key") { event in
                events.append(event)
                if event == .text("你") { firstText.fulfill() }
            }
            complete.fulfill()
            return result
        }
        defer { task.cancel() }
        await fulfillment(of: [firstText], timeout: 3)
        XCTAssertEqual(events, [.reset, .text("你")])
        StreamingClientURLProtocol.resume?()
        await fulfillment(of: [complete, stopped], timeout: 3)
        StreamingClientURLProtocol.close?()
        let result = try await task.value
        XCTAssertEqual(result.content, "你好")
        XCTAssertEqual(events, [.reset, .text("你"), .text("好")])
    }

    func testCancellationStopsOpenStreamWithoutPublishingMoreText() async throws {
        let firstText = expectation(description: "First delta")
        let cancelled = expectation(description: "Cancelled read returns")
        let stopped = expectation(description: "Underlying request cancelled")
        var events: [AIStreamEvent] = []
        StreamingClientURLProtocol.start = { transport in
            transport.headers(["Content-Type": "text/event-stream"])
            transport.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"部分\"}}]}\n\n")
            StreamingClientURLProtocol.close = { transport.finish() }
            transport.onStop = { stopped.fulfill() }
        }
        let task = Task {
            do {
                _ = try await client().sendStreaming(messages: [.init(role: "user", content: "继续")], settings: AISettings(), apiKey: "key") { event in
                    events.append(event)
                    if event == .text("部分") { firstText.fulfill() }
                }
                XCTFail("Cancellation must not produce a completed reply")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            cancelled.fulfill()
        }
        await fulfillment(of: [firstText], timeout: 3)
        task.cancel()
        await fulfillment(of: [cancelled, stopped], timeout: 3)
        StreamingClientURLProtocol.close?()
        await task.value
        XCTAssertEqual(events, [.reset, .text("部分")])
    }

    func testProviderFallbackSeparatesPartialOutputFromReplacementReply() async throws {
        var events: [AIStreamEvent] = []
        StreamingClientURLProtocol.start = { transport in
            transport.headers(["Content-Type": "text/event-stream"])
            if transport.request.url?.host == "first.example" {
                transport.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"未完成\"}}]}\n\n")
            } else {
                transport.push("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"完整答复\"},\"finish_reason\":\"stop\"}]}\n\n")
            }
            transport.finish()
        }
        var settings = AISettings()
        settings.providerRoutes = ["first", "second"].map {
            AIProviderConfiguration(name: $0, baseURL: "https://\($0).example/v1", apiKey: "key", model: "model")
        }
        let result = try await client().sendStreaming(messages: [.init(role: "user", content: "hello")], settings: settings, apiKey: "unused") { events.append($0) }
        XCTAssertEqual(result.content, "完整答复")
        XCTAssertEqual(events, [.reset, .text("未完成"), .reset, .text("完整答复")])
        XCTAssertEqual(result.responseProviderID, settings.providerRoutes?.last?.id)
    }

    func testProvidersIgnoringStreamReturnOneNormalReplyWithoutResendingRequest() async throws {
        let replies: [(AIResponseFormat, [String: Any])] = [
            (.chatCompletions, ["choices": [["message": ["content": "一次回复"]]]]),
            (.responses, ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "一次回复"]]]]]),
            (.anthropic, ["content": [["type": "text", "text": "一次回复"]], "stop_reason": "end_turn"]),
            (.gemini, ["candidates": [["content": ["role": "model", "parts": [["text": "一次回复"]]], "finishReason": "STOP"]]])
        ]
        for (format, reply) in replies {
            var events: [AIStreamEvent] = []
            var requests = 0
            StreamingClientURLProtocol.start = { transport in
                requests += 1
                transport.headers(["Content-Type": "application/json"])
                transport.push(try! JSONSerialization.data(withJSONObject: reply, options: .prettyPrinted))
                transport.finish()
            }
            let result = try await client().sendStreaming(messages: [.init(role: "user", content: "hello")], settings: AISettings(responseFormat: format), apiKey: "key") { events.append($0) }
            XCTAssertEqual(result.content, "一次回复")
            XCTAssertEqual(events, [.reset, .text("一次回复")])
            XCTAssertEqual(requests, 1)
        }
    }

    func testGeminiSSEDeliversSplitUTF8AndUsesAltSSEAndHeaderAuth() async throws {
        let firstText = expectation(description: "Partial Gemini text arrives")
        let complete = expectation(description: "Gemini terminal STOP finishes")
        var events: [AIStreamEvent] = []
        var capturedRequest: URLRequest?

        StreamingClientURLProtocol.start = { transport in
            capturedRequest = transport.request
            transport.headers(["Content-Type": "text/event-stream"])
            let payload = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"先想\",\"thought\":true},{\"text\":\"你\"}]}}]}\r\n\r\n".utf8)
            let chinese = try! XCTUnwrap(payload.range(of: Data("你".utf8)))
            transport.push(payload.prefix(chinese.lowerBound + 1))
            transport.push(payload.dropFirst(chinese.lowerBound + 1))
            StreamingClientURLProtocol.resume = {
                transport.push("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"好\"}]},\"finishReason\":\"STOP\"}]}\n\n")
            }
            StreamingClientURLProtocol.close = { transport.finish() }
        }

        let settings = AISettings(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            model: "gemini-2.5-flash",
            responseFormat: .gemini
        )
        let task = Task {
            let result = try await client().sendStreaming(
                messages: [.init(role: "user", content: "问候")],
                settings: settings,
                apiKey: "AIza-stream-test"
            ) { event in
                events.append(event)
                if event == .text("你") { firstText.fulfill() }
            }
            complete.fulfill()
            return result
        }
        defer { task.cancel() }
        await fulfillment(of: [firstText], timeout: 3)
        XCTAssertEqual(events, [.reset, .reasoning("先想"), .text("你")])
        StreamingClientURLProtocol.resume?()
        await fulfillment(of: [complete], timeout: 3)
        StreamingClientURLProtocol.close?()
        let result = try await task.value
        XCTAssertEqual(result.content, "你好")
        XCTAssertEqual(result.reasoningContent, "先想")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-stream-test")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }
}

private final class StreamingClientURLProtocol: URLProtocol {
    static var start: ((StreamingClientURLProtocol) -> Void)?
    static var resume: (() -> Void)?
    static var close: (() -> Void)?
    var onStop: (() -> Void)?
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.start?(self) }
    override func stopLoading() {
        finished = true
        onStop?()
        onStop = nil
    }
    func headers(_ fields: [String: String]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: fields)!, cacheStoragePolicy: .notAllowed)
    }
    func push(_ text: String) { push(Data(text.utf8)) }
    func push(_ data: Data) {
        guard !finished else { return }
        client?.urlProtocol(self, didLoad: data)
    }
    func finish() {
        guard !finished else { return }
        finished = true
        client?.urlProtocolDidFinishLoading(self)
    }
}
