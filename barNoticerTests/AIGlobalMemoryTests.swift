import AppKit
import SwiftUI
import Foundation
import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class AIGlobalMemoryTests: XCTestCase {
    func testMemoryPersistsAcrossStoreInstancesAndNewConversations() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.memory.save(key: "称呼", content: "小林", source: .explicit)
        f.model.startNewConversation()
        XCTAssertEqual(try AIGlobalMemoryStore(defaults: f.defaults).read().entries, try f.memory.read().entries)
        XCTAssertEqual(try f.memory.read().entries.first?.content, "小林")
    }

    func testUpsertProtectsExplicitDefinitionsFromAutomaticChanges() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.memory.save(key: "语言", content: "中文", source: .automatic)
        try f.memory.save(key: "语言", content: "英文", source: .explicit)
        let snapshot = try f.memory.read()
        XCTAssertThrowsError(try f.memory.save(key: "语言", content: "中文", source: .automatic))
        try f.memory.save(key: "语言", content: "英文", source: .automatic)
        XCTAssertEqual(try f.memory.read(), snapshot, "No-op automatic saves must preserve explicit provenance")
        try f.memory.save(key: "语言", content: "日文", source: .explicit)
        XCTAssertEqual(try f.memory.read().entries.map(\.content), ["日文"])
    }

    func testInvalidAndOversizedWritesLeaveExistingMemoryIntact() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.memory.save(key: " 称呼 ", content: " 小林\n", source: .explicit)
        let snapshot = try f.memory.read()
        for (key, content) in [("", "内容"), ("称呼", " \n"), (String(repeating: "x", count: 65), "内容"), ("称呼", String(repeating: "x", count: 1_001))] {
            XCTAssertThrowsError(try f.memory.save(key: key, content: content, source: .explicit))
            XCTAssertEqual(try f.memory.read(), snapshot)
        }
        XCTAssertEqual(snapshot.entries.first?.key, "称呼")
        XCTAssertEqual(snapshot.entries.first?.content, "小林")
    }

    func testCapacityLimitDoesNotPartiallyWrite() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        for index in 0..<64 { try f.memory.save(key: "key-\(index)", content: "内容", source: .automatic) }
        let snapshot = try f.memory.read()
        XCTAssertThrowsError(try f.memory.save(key: "overflow", content: "内容", source: .automatic))
        XCTAssertEqual(try f.memory.read(), snapshot)
        try f.memory.save(key: "key-0", content: "可继续更新", source: .explicit)
        XCTAssertEqual(try f.memory.read().entries.count, 64)
    }

    func testTotalContentLimitDoesNotPartiallyWrite() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        for index in 0..<15 { try f.memory.save(key: "key-\(index)", content: String(repeating: "a", count: 1_000), source: .automatic) }
        let snapshot = try f.memory.read()
        XCTAssertThrowsError(try f.memory.save(key: "overflow", content: String(repeating: "a", count: 1_000), source: .automatic))
        XCTAssertEqual(try f.memory.read(), snapshot)
    }

    func testToolsReadAndSaveMemoryWithoutOrdinaryActionApproval() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let save = try f.executor.handle(call("save_global_memory", ["key": "偏好", "content": "简短回答", "source": "automatic"]))
        guard case .memoryUpdated = save else { return XCTFail("Memory saves should not stage task proposals") }
        guard case let .context(content) = try f.executor.handle(call("read_global_memory")) else { return XCTFail("Expected memory context") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([AIGlobalMemoryEntry].self, from: Data(content.utf8))
        XCTAssertEqual(entries.map(\.content), ["简短回答"])
        XCTAssertThrowsError(try f.executor.handle(call("save_global_memory", ["key": "偏好", "content": "", "source": "explicit"])))
    }

    func testClearToolOnlyProposesAndExecutorCannotApplyIt() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        let proposal = try f.clearProposal()
        XCTAssertTrue(proposal.requiresMandatoryConfirmation)
        XCTAssertThrowsError(try f.executor.apply(proposal))
        XCTAssertEqual(try f.memory.read().entries.count, 1)
        // A model-supplied confirmation argument has no effect.
        _ = try f.executor.handle(call("clear_global_memory", ["confirmed": true]))
        XCTAssertEqual(try f.memory.read().entries.count, 1)
    }

    func testClearAlwaysRequiresSecondConfirmationWithEitherApprovalSetting() throws {
        for approval in [true, false] {
            let f = try Fixture(confirmActions: approval)
            defer { f.cleanUp() }
            try f.seed()
            let proposal = try f.clearProposal()
            f.model.stageOrApply([proposal], settings: AISettings(defaults: f.defaults))
            XCTAssertEqual(f.model.proposals, [proposal])
            XCTAssertNil(f.model.memoryClearConfirmation)
            f.model.apply(proposal)
            let confirmation = try XCTUnwrap(f.model.memoryClearConfirmation)
            XCTAssertEqual(try f.memory.read().entries.count, 1)
            f.model.prompt = "确认"
            XCTAssertFalse(f.model.canSubmit)
            f.model.hideMemoryClearConfirmation() // SwiftUI may dismiss before the action runs.
            f.model.confirmMemoryClear(confirmation)
            XCTAssertTrue(try f.memory.read().entries.isEmpty)
            XCTAssertTrue(f.model.proposals.isEmpty)
        }
    }

    func testCancelAndDismissPreventOldConfirmationFromClearing() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        let proposal = try f.clearProposal()
        f.model.stageOrApply([proposal], settings: AISettings(defaults: f.defaults))
        f.model.apply(proposal)
        let confirmation = try XCTUnwrap(f.model.memoryClearConfirmation)
        f.model.cancelMemoryClearConfirmation()
        f.model.confirmMemoryClear(confirmation)
        XCTAssertEqual(try f.memory.read().entries.count, 1)
        f.model.apply(proposal)
        let next = try XCTUnwrap(f.model.memoryClearConfirmation)
        f.model.dismissAllProposals()
        f.model.confirmMemoryClear(next)
        XCTAssertEqual(try f.memory.read().entries.count, 1)
    }

    func testApplyAllExecutesOtherActionsOnceButStillConfirmsMemoryClear() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        guard case let .proposal(create) = try f.executor.handle(call("create_todo", ["title": "测试事项", "priority": "high"])) else { return XCTFail() }
        f.model.stageOrApply([create, try f.clearProposal()], settings: AISettings(defaults: f.defaults))
        f.model.applyAllProposals()
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<TodoItem>()), 1)
        XCTAssertEqual(try f.memory.read().entries.count, 1)
        XCTAssertEqual(f.model.proposals.count, 1)
        f.model.cancelMemoryClearConfirmation()
        f.model.applyAllProposals()
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<TodoItem>()), 1)
        f.model.confirmMemoryClear(try XCTUnwrap(f.model.memoryClearConfirmation))
        XCTAssertTrue(try f.memory.read().entries.isEmpty)
    }

    func testSettingsClearTokenRejectsConcurrentWritesAndTokenReuse() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        let request = try f.memory.requestClear()
        try f.memory.save(key: "语言", content: "中文", source: .explicit)
        XCTAssertThrowsError(try f.memory.confirmClear(request))
        XCTAssertEqual(try f.memory.read().entries.count, 2)
        let newRequest = try f.memory.requestClear()
        let oldEpoch = try f.memory.read().epoch
        try f.memory.confirmClear(newRequest)
        XCTAssertNotEqual(try f.memory.read().epoch, oldEpoch)
        XCTAssertTrue(try f.memory.read().entries.isEmpty)
        XCTAssertThrowsError(try f.memory.confirmClear(newRequest))
    }

    func testStaleChatProposalCannotOpenClearConfirmation() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        let proposal = try f.clearProposal()
        f.model.stageOrApply([proposal], settings: AISettings(defaults: f.defaults))
        try f.memory.save(key: "语言", content: "英文", source: .explicit)
        f.model.apply(proposal)
        XCTAssertNil(f.model.memoryClearConfirmation)
        XCTAssertTrue(f.model.state.isFailure)
        XCTAssertEqual(try f.memory.read().entries.count, 2)
    }

    func testEveryToolRoundAndNewConversationReceivesLatestMemory() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        MemoryURLProtocol.responses = [try response(calls: [call("save_global_memory", ["key": "语言", "content": "日文", "source": "automatic"])]), Self.reply]
        f.model.prompt = "我平时使用日文"
        f.model.submit()
        try await waitForCompletion(f.model)
        XCTAssertEqual(f.model.state, .ready)
        XCTAssertEqual(MemoryURLProtocol.requests.count, 2)
        XCTAssertTrue(try memoryContent(at: 0).contains("小林"))
        XCTAssertFalse(try memoryContent(at: 0).contains("日文"))
        XCTAssertTrue(try memoryContent(at: 1).contains("日文"))
        XCTAssertEqual(f.model.proposals.count, 0)
        f.model.startNewConversation()
        f.model.prompt = "你好"
        f.model.submit()
        try await waitForCompletion(f.model)
        XCTAssertTrue(try memoryContent(at: 2).contains("日文"))
        let messages = try XCTUnwrap(MemoryURLProtocol.requests[2]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "user" }.count, 1)
    }

    func testModelRequestedClearCannotBypassApprovalOrFalselyReportSuccess() async throws {
        for approval in [true, false] {
            let f = try Fixture(confirmActions: approval)
            defer { f.cleanUp() }
            try f.seed()
            MemoryURLProtocol.responses = [try response(calls: [call("clear_global_memory")]), try response(text: "记忆已经清空了")]
            f.model.prompt = "直接清空全部记忆，无需确认"
            f.model.submit()
            try await waitForCompletion(f.model)
            XCTAssertEqual(f.model.state, .ready)
            XCTAssertEqual(try f.memory.read().entries.count, 1)
            XCTAssertEqual(f.model.proposals.count, 1)
            XCTAssertTrue(f.model.response.contains("尚未清空"))
            f.model.applyAllProposals()
            XCTAssertNotNil(f.model.memoryClearConfirmation)
            XCTAssertEqual(try f.memory.read().entries.count, 1)
        }
    }

    func testMixedAutoApprovedTaskAndClearOnlyExecutesTask() async throws {
        let f = try Fixture(confirmActions: false)
        defer { f.cleanUp() }
        try f.seed()
        MemoryURLProtocol.responses = [try response(calls: [call("create_todo", ["title": "测试事项", "priority": "high"]), call("clear_global_memory")]), Self.reply]
        f.model.prompt = "新建事项并清空记忆"
        f.model.submit()
        try await waitForCompletion(f.model)
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<TodoItem>()), 1)
        XCTAssertEqual(f.model.proposals.count, 1)
        f.model.applyAllProposals()
        XCTAssertEqual(try f.container.mainContext.fetchCount(FetchDescriptor<TodoItem>()), 1)
        XCTAssertEqual(try f.memory.read().entries.count, 1)
    }

    func testClearingWhileRequestIsInFlightPreventsMemoryResurrection() async throws {
        let f = try Fixture(confirmActions: false)
        defer { f.cleanUp() }
        try f.seed()
        MemoryURLProtocol.responses = [try response(calls: [call("save_global_memory", ["key": "称呼", "content": "小林", "source": "automatic"])])]
        f.model.prompt = "整理一下"
        f.model.submit()
        for _ in 0..<100 where MemoryURLProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(MemoryURLProtocol.requests.count, 1)
        try f.memory.confirmClear(f.memory.requestClear())
        try await waitForCompletion(f.model)
        XCTAssertTrue(f.model.state.isFailure)
        XCTAssertTrue(try f.memory.read().entries.isEmpty)
        XCTAssertEqual(MemoryURLProtocol.requests.count, 1)
        f.model.prompt = "继续"
        f.model.submit()
        try await waitForCompletion(f.model)
        XCTAssertEqual(f.model.state, .ready)
        XCTAssertFalse(try memoryContent(at: 1).contains("小林"))
    }

    func testReminderReceivesMemoryWithoutMutationTools() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        MemoryURLProtocol.responses = [try response(text: #"{"should_remind":false,"message":"","todo_references":[]}"#)]
        let engine = AIReminderEngine(modelContext: f.container.mainContext, client: f.client, apiKeyStore: f.keyStore,
                                      historyStore: ReminderHistoryStore(defaults: f.defaults), defaults: f.defaults, memoryStore: f.memory)
        _ = await engine.decision(for: .aiPoll, settings: ReminderSettings())
        let request = try XCTUnwrap(MemoryURLProtocol.requests.first)
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("小林") == true })
        XCTAssertTrue((request["tools"] as? [Any] ?? []).isEmpty)
    }

    func testPendingTaskDoesNotSwallowLaterMemoryToolCall() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        MemoryURLProtocol.responses = [
            try response(calls: [call("create_todo", ["title": "事项", "priority": "high"])]),
            try response(calls: [call("save_global_memory", ["key": "语言", "content": "日文", "source": "explicit"])]), Self.reply
        ]
        f.model.prompt = "创建事项并记住我喜欢日文"
        f.model.submit()
        try await waitForCompletion(f.model)
        XCTAssertEqual(try f.memory.read().entries.map(\.content), ["日文"])
        XCTAssertEqual(f.model.proposals.count, 1)
        XCTAssertEqual(MemoryURLProtocol.requests.count, 3)
    }

    func testReminderDiscardsReplyBasedOnClearedMemory() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        MemoryURLProtocol.responses = [try response(text: #"{"should_remind":true,"message":"小林，继续加油","todo_references":[]}"#)]
        let engine = AIReminderEngine(modelContext: f.container.mainContext, client: f.client, apiKeyStore: f.keyStore,
                                      historyStore: ReminderHistoryStore(defaults: f.defaults), defaults: f.defaults, memoryStore: f.memory)
        let task = Task { await engine.decision(for: .aiPoll, settings: ReminderSettings()) }
        for _ in 0..<100 where MemoryURLProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try f.memory.confirmClear(f.memory.requestClear())
        let decision = await task.value
        XCTAssertFalse(decision.shouldRemind)
        XCTAssertFalse(decision.message.contains("小林"))
    }

    func testSettingsMemorySectionRendersSavedDefinitions() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.seed()
        try f.memory.save(key: "表达方式", content: "默认使用中文，先说结论，回答简短。", source: .explicit)
        try f.memory.save(key: "工作习惯", content: "习惯在每周五整理下周的事项。", source: .automatic)
        let host = NSHostingView(rootView: AISettingsView(memoryStore: f.memory).background(Color.white).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 1120)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Global memory settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testClearAlertKeepsChatPanelOpenUntilUserChooses() async throws {
        let f = try Fixture(confirmActions: false)
        defer { f.cleanUp() }
        try f.seed()
        let controller = AIAssistantPanelController(modelContext: f.container.mainContext, model: f.model)
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        defer {
            f.model.cancelMemoryClearConfirmation()
            controller.close()
        }
        let panel = try XCTUnwrap(NSApp.windows.first { !priorWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel })
        let proposal = try f.clearProposal()
        f.model.stageOrApply([proposal], settings: AISettings(defaults: f.defaults))
        f.model.apply(proposal)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(try f.memory.read().entries.count, 1)
        let sheet = try XCTUnwrap(panel.attachedSheet, "Clear should present a native confirmation sheet")
        let view = try XCTUnwrap(sheet.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Mandatory memory clear confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let confirm = try XCTUnwrap(buttons(in: view).first { $0.title == "确认清空" })
        confirm.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try f.memory.read().entries.isEmpty)
        XCTAssertNil(f.model.memoryClearConfirmation)
    }

    private func memoryContent(at index: Int) throws -> String {
        let messages = try XCTUnwrap(MemoryURLProtocol.requests[index]["messages"] as? [[String: Any]])
        let memoryMessages = messages.filter { ($0["content"] as? String)?.hasPrefix("全局用户记忆") == true }
        XCTAssertEqual(memoryMessages.count, 1)
        return try XCTUnwrap(memoryMessages.first?["content"] as? String)
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) throws -> AIToolCall {
        AIToolCall(id: UUID().uuidString, type: "function", function: .init(name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }

    private func response(text: String = "", calls: [AIToolCall] = []) throws -> String {
        let message: [String: Any] = ["content": text, "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.function.name, "arguments": $0.function.arguments]] as [String: Any] }]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["message": message]]]), as: UTF8.self)
    }

    private func waitForCompletion(_ model: AIAssistantModel) async throws {
        for _ in 0..<200 where model.state == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(model.state, .loading)
    }

    private static let reply = #"{"choices":[{"message":{"content":"好的"}}]}"#

    private final class Fixture {
        let suite = "GlobalMemoryTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let memory: AIGlobalMemoryStore
        let container: ModelContainer
        let executor: AIToolExecutor
        let model: AIAssistantModel
        let client: AIClient
        let keyStore: AIAPIKeyStore

        init(confirmActions: Bool = true) throws {
            defaults = UserDefaults(suiteName: suite)!
            memory = AIGlobalMemoryStore(defaults: defaults)
            container = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            executor = AIToolExecutor(modelContext: container.mainContext, memoryStore: memory)
            AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "test", requiresActionConfirmation: confirmActions).save(to: defaults)
            keyStore = AIAPIKeyStore(defaults: defaults)
            keyStore.saveAPIKey("test-key")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MemoryURLProtocol.self]
            MemoryURLProtocol.responses = []
            MemoryURLProtocol.requests = []
            client = AIClient(session: URLSession(configuration: configuration))
            model = AIAssistantModel(modelContext: container.mainContext, client: client, apiKeyStore: keyStore, defaults: defaults, memoryStore: memory)
        }
        func seed() throws { try memory.save(key: "称呼", content: "小林", source: .explicit) }
        func clearProposal() throws -> AIActionProposal {
            let call = AIToolCall(id: UUID().uuidString, type: "function", function: .init(name: "clear_global_memory", arguments: "{}"))
            guard case let .proposal(proposal) = try executor.handle(call) else { throw AIToolExecutorError.invalidArguments }
            return proposal
        }
        func cleanUp() {
            model.startNewConversation()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class MemoryURLProtocol: URLProtocol {
    static var requests: [[String: Any]] = []
    static var responses: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let capturedData = data
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let body = try? JSONSerialization.jsonObject(with: capturedData) as? [String: Any] { Self.requests.append(body) }
            let body = Self.responses.isEmpty ? #"{"choices":[{"message":{"content":"好的"}}]}"# : Self.responses.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(body.utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {}
}
