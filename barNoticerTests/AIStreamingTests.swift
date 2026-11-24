import XCTest
@testable import barNoticer

final class AIStreamingTests: XCTestCase {
    private func consume(_ payload: [String: Any], with decoder: inout AIProviderStreamDecoder,
                         event: String? = nil) throws -> [AIStreamEvent] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try decoder.consume(data: String(decoding: data, as: UTF8.self), event: event)
    }

    private func chat(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return ["choices": [choice]]
    }

    private func responseItem(_ item: [String: Any], index: Int = 0, done: Bool = true) -> [String: Any] {
        ["type": done ? "response.output_item.done" : "response.output_item.added", "output_index": index, "item": item]
    }

    private func responseText(_ value: String, type: String = "response.output_text.delta",
                              index: Int = 0, part: Int = 0) -> [String: Any] {
        let reasoning = type.contains("reasoning_summary_text")
        let field = type.hasSuffix("delta") ? "delta" : (type.contains("refusal") ? "refusal" : "text")
        return ["type": type, "output_index": index, reasoning ? "summary_index" : "content_index": part, field: value]
    }

    private var anthropicStart: [String: Any] {
        ["type": "message_start", "message": ["type": "message", "role": "assistant", "content": []]]
    }

    private func blockStart(_ block: [String: Any], index: Int = 0) -> [String: Any] {
        ["type": "content_block_start", "index": index, "content_block": block]
    }

    private func blockDelta(_ delta: [String: Any], index: Int = 0) -> [String: Any] {
        ["type": "content_block_delta", "index": index, "delta": delta]
    }

    private func blockStop(_ index: Int = 0) -> [String: Any] {
        ["type": "content_block_stop", "index": index]
    }

    private func messageDelta(_ reason: String = "end_turn") -> [String: Any] {
        ["type": "message_delta", "delta": ["stop_reason": reason]]
    }

    func testChatUnicodeDeltasKeepReasoningSeparateAndFinishWithoutDoneSentinel() throws {
        var decoder = AIProviderStreamDecoder(format: .chatCompletions)
        var events: [AIStreamEvent] = []
        events += try consume(chat(["reasoning_content": "先想🧠"]), with: &decoder)
        events += try consume(chat(["reasoning": "再答"]), with: &decoder)
        for text in ["你好", "👩🏽‍💻", "，世界"] {
            events += try consume(chat(["content": text]), with: &decoder)
        }
        XCTAssertFalse(decoder.isComplete)
        XCTAssertThrowsError(try decoder.finish())
        events += try consume(chat([:], finish: "stop"), with: &decoder)
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(events, [.reasoning("先想🧠"), .reasoning("再答"), .text("你好"), .text("👩🏽‍💻"), .text("，世界")])
        let result = try decoder.finish()
        XCTAssertEqual(result.content, "你好👩🏽‍💻，世界")
        XCTAssertEqual(result.reasoningContent, "先想🧠再答")
        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertEqual(try decoder.consume(data: "[DONE]", event: nil), [])
    }

    func testChatInterleavedToolFragmentsPreserveIdentityAndMalformedArgumentString() throws {
        var decoder = AIProviderStreamDecoder(format: .chatCompletions)
        let first = chat(["tool_calls": [
            ["index": 1, "id": "call-", "type": "function", "function": ["name": "complete_", "arguments": "{\"id\":"]],
            ["index": 0, "id": "first", "function": ["name": "list_", "arguments": "{"]]
        ]])
        XCTAssertEqual(try consume(first, with: &decoder), [])
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertEqual(try consume(chat(["tool_calls": [
            ["index": 0, "function": ["name": "todos", "arguments": "}"]],
            ["index": 1, "id": "second", "function": ["name": "todo", "arguments": "not-json"]]
        ]]), with: &decoder), [])
        XCTAssertFalse(decoder.isComplete)
        XCTAssertEqual(try consume(chat([:], finish: "tool_calls"), with: &decoder), [.toolCall("list_todos"), .toolCall("complete_todo")])
        let result = try decoder.finish()
        XCTAssertEqual(result.toolCalls.map(\.id), ["first", "call-second"])
        XCTAssertEqual(result.toolCalls.map(\.function.name), ["list_todos", "complete_todo"])
        XCTAssertEqual(result.toolCalls.map(\.function.arguments), ["{}", "{\"id\":not-json"])
    }

    func testChatDoneSentinelCanTerminateButCannotRepairMissingToolArguments() throws {
        var decoder = AIProviderStreamDecoder(format: .chatCompletions)
        _ = try consume(chat(["content": "ok"]), with: &decoder)
        _ = try decoder.consume(data: "[DONE]", event: nil)
        XCTAssertEqual(try decoder.finish().content, "ok")

        var missing = AIProviderStreamDecoder(format: .chatCompletions)
        _ = try consume(chat(["tool_calls": [["index": 0, "id": "call", "function": ["name": "list_todos"]]]]), with: &missing)
        XCTAssertThrowsError(try missing.consume(data: "[DONE]", event: nil))
        XCTAssertFalse(missing.isComplete)
        XCTAssertThrowsError(try missing.finish())
    }

    func testResponsesCanonicalCompletionOwnsOpaqueReplayAndDoesNotRepeatDeltas() throws {
        var decoder = AIProviderStreamDecoder(format: .responses)
        var events: [AIStreamEvent] = []
        events += try consume(responseText("思考", type: "response.reasoning_summary_text.delta"), with: &decoder)
        events += try consume(responseText("思考", type: "response.reasoning_summary_text.done"), with: &decoder)
        events += try consume(responseText("你好", index: 1), with: &decoder)
        events += try consume(responseText("🙂", index: 1), with: &decoder)
        events += try consume(responseText("你好🙂", type: "response.output_text.done", index: 1), with: &decoder)
        events += try consume(responseText("无法", type: "response.refusal.delta", index: 1, part: 1), with: &decoder)
        events += try consume(responseText("无法", type: "response.refusal.done", index: 1, part: 1), with: &decoder)
        let tool: [String: Any] = ["type": "function_call", "id": "item-tool", "call_id": "call", "name": "list_todos", "arguments": "{broken", "status": "completed"]
        events += try consume(responseItem(tool, index: 2, done: false), with: &decoder)
        XCTAssertFalse(decoder.isComplete)
        XCTAssertThrowsError(try decoder.finish())
        let output: [[String: Any]] = [
            ["type": "reasoning", "id": "reason", "encrypted_content": "opaque-ciphertext", "summary": [["type": "summary_text", "text": "思考"]]],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "你好🙂"], ["type": "refusal", "refusal": "无法"]]],
            tool,
            ["type": "provider_extension", "opaque": ["nested": [1, 2, 3]]]
        ]
        events += try consume(["type": "response.completed", "response": ["status": "completed", "output": output]], with: &decoder)
        XCTAssertEqual(events, [.reasoning("思考"), .text("你好"), .text("🙂"), .text("无法"), .toolCall("list_todos")])
        let result = try decoder.finish()
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(result.content, "你好🙂\n无法")
        XCTAssertEqual(result.reasoningContent, "思考")
        XCTAssertEqual(result.toolCalls.first?.function.arguments, "{broken")
        let expectedItems = try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: output))
        XCTAssertEqual(result.responseItems, expectedItems)
    }

    func testResponsesTerminalOutputOverridesEarlierCompletedItems() throws {
        var decoder = AIProviderStreamDecoder(format: .responses)
        _ = try consume(responseItem(["type": "function_call", "call_id": "old", "name": "old", "arguments": "{}"]), with: &decoder)
        let authoritative: [[String: Any]] = [["type": "function_call", "call_id": "new", "name": "new", "arguments": "{\"id\":1}"]]
        _ = try consume(["type": "response.completed", "response": ["output": authoritative]], with: &decoder)
        XCTAssertEqual(try decoder.finish().toolCalls.map(\.id), ["new"])
        XCTAssertEqual(try decoder.finish().toolCalls.first?.function.arguments, "{\"id\":1}")
    }

    func testResponsesCompatibleTerminalUsesOnlyCompletedItemsWithoutInventingParameters() throws {
        let valid: [String: Any] = ["type": "function_call", "call_id": "call", "name": "list_todos", "arguments": "{}"]
        for done in [false, true] {
            for hasArguments in [false, true] {
                var decoder = AIProviderStreamDecoder(format: .responses)
                var item = valid
                if !hasArguments { item.removeValue(forKey: "arguments") }
                _ = try consume(responseItem(item, done: done), with: &decoder)
                let terminal: [String: Any] = ["type": "response.completed", "response": ["status": "completed"]]
                if done && hasArguments {
                    _ = try consume(terminal, with: &decoder)
                    XCTAssertEqual(try decoder.finish().toolCalls.first?.function.arguments, "{}")
                } else {
                    XCTAssertThrowsError(try consume(terminal, with: &decoder))
                    XCTAssertThrowsError(try decoder.finish())
                }
            }
        }
    }

    func testAnthropicInterleavedBlocksSeparateThinkingAndPreserveToolArgumentDeltas() throws {
        var decoder = AIProviderStreamDecoder(format: .anthropic)
        _ = try consume(anthropicStart, with: &decoder, event: "message_start")
        var events: [AIStreamEvent] = []
        events += try consume(blockStart(["type": "thinking", "thinking": "先"]), with: &decoder)
        events += try consume(blockDelta(["type": "thinking_delta", "thinking": "想🧠"]), with: &decoder)
        _ = try consume(blockDelta(["type": "signature_delta", "signature": "opaque"]), with: &decoder)
        _ = try consume(blockStop(), with: &decoder)
        events += try consume(blockStart(["type": "text", "text": "你好"], index: 1), with: &decoder)
        events += try consume(blockStart(["type": "tool_use", "id": "second", "name": "complete_todo", "input": [:]], index: 3), with: &decoder)
        events += try consume(blockStart(["type": "tool_use", "id": "first", "name": "list_todos", "input": [:]], index: 2), with: &decoder)
        _ = try consume(blockDelta(["type": "input_json_delta", "partial_json": "{\"id\":"], index: 3), with: &decoder)
        events += try consume(blockDelta(["type": "text_delta", "text": "🙂"], index: 1), with: &decoder)
        _ = try consume(blockDelta(["type": "input_json_delta", "partial_json": "{}"], index: 2), with: &decoder)
        _ = try consume(blockDelta(["type": "input_json_delta", "partial_json": "bad"], index: 3), with: &decoder)
        for index in 1...3 { _ = try consume(blockStop(index), with: &decoder) }
        _ = try consume(messageDelta("tool_use"), with: &decoder)
        XCTAssertFalse(decoder.isComplete)
        XCTAssertThrowsError(try decoder.finish())
        _ = try consume(["type": "message_stop"], with: &decoder)
        XCTAssertEqual(events, [.reasoning("先"), .reasoning("想🧠"), .text("你好"), .toolCall("complete_todo"), .toolCall("list_todos"), .text("🙂")])
        let result = try decoder.finish()
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(result.content, "你好🙂")
        XCTAssertEqual(result.reasoningContent, "先想🧠")
        XCTAssertEqual(result.toolCalls.map(\.id), ["first", "second"])
        XCTAssertEqual(result.toolCalls.map(\.function.arguments), ["{}", "{\"id\":bad"])
    }

    func testGeminiStreamSeparatesThoughtsAndPreservesThoughtSignatureAndToolCalls() throws {
        var decoder = AIProviderStreamDecoder(format: .gemini)
        var events: [AIStreamEvent] = []
        let chunk1: [String: Any] = ["candidates": [[
            "content": ["role": "model", "parts": [["text": "先想🧠", "thought": true]]]
        ]]]
        let chunk2: [String: Any] = ["candidates": [[
            "content": ["role": "model", "parts": [["text": "你好"]]]
        ]]]
        let chunk3: [String: Any] = ["candidates": [[
            "content": ["role": "model", "parts": [
                ["text": "🙂"],
                ["thoughtSignature": "sig-stream-123", "functionCall": ["id": "fc-1", "name": "list_active_todos", "args": ["filter": "all"]]]
            ]],
            "finishReason": "STOP"
        ]]]
        events += try consume(chunk1, with: &decoder)
        XCTAssertFalse(decoder.isComplete)
        events += try consume(chunk2, with: &decoder)
        XCTAssertFalse(decoder.isComplete)
        events += try consume(chunk3, with: &decoder)
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(events, [.reasoning("先想🧠"), .text("你好"), .text("🙂"), .toolCall("list_active_todos")])
        let result = try decoder.finish()
        XCTAssertEqual(result.content, "你好🙂")
        XCTAssertEqual(result.reasoningContent, "先想🧠")
        XCTAssertEqual(result.toolCalls.map(\.id), ["fc-1"])
        XCTAssertEqual(result.toolCalls.map(\.function.name), ["list_active_todos"])
        let encodedParts = String(decoding: try JSONEncoder().encode(result.responseItems), as: UTF8.self)
        XCTAssertTrue(encodedParts.contains("sig-stream-123"))
    }

    func testRejectedTerminalAndMalformedEnvelopesNeverProduceFinalResults() throws {
        let cases: [(AIResponseFormat, [[String: Any]])] = [
            (.chatCompletions, [chat(["content": "partial"], finish: "length")]),
            (.chatCompletions, [chat(["content": "partial"], finish: "content_filter")]),
            (.chatCompletions, [["choices": NSNull()]]),
            (.chatCompletions, [chat(["content": 42])]),
            (.responses, [["type": "response.failed", "response": ["status": "failed"]]]),
            (.responses, [["type": "response.incomplete", "response": ["status": "incomplete"]]]),
            (.responses, [["type": "response.completed", "response": ["status": "incomplete", "output": []]]]),
            (.responses, [["type": "response.completed", "response": ["output": NSNull()]]]),
            (.responses, [["type": "response.output_text.delta", "delta": NSNull()]]),
            (.anthropic, [anthropicStart, blockStart(["type": "text", "text": "partial"]), messageDelta("max_tokens")]),
            (.anthropic, [anthropicStart, blockStart(["type": "text", "text": "partial"]), messageDelta(), ["type": "message_stop"]]),
            (.anthropic, [anthropicStart, blockStart(["type": "text", "text": "partial"]), blockStop(), ["type": "message_stop"]]),
            (.gemini, [["candidates": [["content": ["parts": [["text": "partial"]]], "finishReason": "MAX_TOKENS"]]]]),
            (.gemini, [["candidates": [["content": ["parts": [["text": "partial"]]], "finishReason": "SAFETY"]]]]),
            (.gemini, [["promptFeedback": ["blockReason": "SAFETY"]]]),
            (.gemini, [["candidates": NSNull()]]),
            (.gemini, [["candidates": [["content": ["parts": [["functionCall": ["args": [String: Any]()]]]]]]]])
        ]
        for (format, payloads) in cases {
            var decoder = AIProviderStreamDecoder(format: format)
            XCTAssertThrowsError(try payloads.forEach { _ = try consume($0, with: &decoder) }, "\(format): \(payloads)")
            XCTAssertFalse(decoder.isComplete)
            XCTAssertThrowsError(try decoder.finish())
        }
        for format in AIResponseFormat.allCases {
            var decoder = AIProviderStreamDecoder(format: format)
            XCTAssertThrowsError(try decoder.consume(data: "null", event: nil))
            XCTAssertThrowsError(try decoder.finish())
        }
    }

    func testPrematureEOFRejectsPartialOutputForEveryProtocol() throws {
        let cases: [(AIResponseFormat, [[String: Any]])] = [
            (.chatCompletions, [chat(["content": "partial"])]),
            (.responses, [responseText("partial"), responseItem(["type": "message", "content": [["type": "output_text", "text": "partial"]]])]),
            (.anthropic, [anthropicStart, blockStart(["type": "text", "text": "partial"]), blockStop(), messageDelta()]),
            (.gemini, [["candidates": [["content": ["role": "model", "parts": [["text": "partial"]]]]]]])
        ]
        for (format, payloads) in cases {
            var decoder = AIProviderStreamDecoder(format: format)
            for payload in payloads { _ = try consume(payload, with: &decoder) }
            XCTAssertFalse(decoder.isComplete)
            XCTAssertThrowsError(try decoder.finish())
        }
    }

    func testProviderFailuresRedactSecretsAndPoisonPartialResults() throws {
        for format in AIResponseFormat.allCases {
            var decoder = AIProviderStreamDecoder(format: format, apiKey: "private-token")
            let payload: [String: Any] = ["type": "error", "error": ["message": "bad private-token Bearer abc sk-secret-key AIzaSyDummySecret123"]]
            XCTAssertThrowsError(try consume(payload, with: &decoder)) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-token"))
                XCTAssertFalse(error.localizedDescription.contains("sk-secret-key"))
                XCTAssertFalse(error.localizedDescription.contains("AIzaSyDummySecret123"))
                XCTAssertFalse(error.localizedDescription.contains("Bearer abc"))
            }
            XCTAssertFalse(decoder.isComplete)
            XCTAssertThrowsError(try decoder.finish())
        }
    }
}
