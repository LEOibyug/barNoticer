import AppKit
import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class AIAssistantSessionTests: XCTestCase {
    func testCloseAndReopenPreservesDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show()
        fixture.model.prompt = "稍后继续写的内容"
        fixture.controller.close()
        try await Task.sleep(for: .milliseconds(250))
        fixture.controller.show()
        XCTAssertEqual(fixture.model.prompt, "稍后继续写的内容")
        XCTAssertEqual(fixture.model.state, .idle)
    }

    func testClosingDuringRequestAllowsBackgroundReplyAndFollowUpWithHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show()
        fixture.model.prompt = "第一问"
        fixture.model.submit()
        // Losing focus follows the same path as clicking another window.
        NSApp.keyWindow?.resignKey()
        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertEqual(fixture.model.state, .loading)
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(fixture.model.response, "回复内容")
        XCTAssertEqual(fixture.presenter.replies.count, 1)
        XCTAssertEqual(fixture.presenter.replies.first?.message, "回复内容")
        fixture.presenter.openChat?()
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertEqual(fixture.model.response, "回复内容")
        fixture.model.prompt = "接着说"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        let messages = try XCTUnwrap(SessionURLProtocol.requests.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }, ["第一问", "接着说"])
        XCTAssertEqual(fixture.presenter.replies.count, 1, "Visible replies should not show a second popup")
    }

    func testHiddenToolRequestExecutesAndNotifiesOnce() async throws {
        let fixture = try Fixture(confirmActions: false)
        defer { fixture.cleanUp() }
        SessionURLProtocol.responses = [Self.createTodoResponse, Self.replyResponse]
        fixture.controller.show()
        fixture.model.prompt = "添加任务"
        fixture.model.submit()
        fixture.controller.close()
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).map(\.title), ["后台任务"])
        XCTAssertEqual(fixture.presenter.replies.count, 1)
        fixture.controller.show()
        fixture.controller.close()
        fixture.controller.show()
        XCTAssertEqual(fixture.presenter.replies.count, 1)
    }

    func testCompletingTodoRespectsConfirmationSettingAndReportsExecution() async throws {
        for needsConfirmation in [false, true] {
            let fixture = try Fixture(confirmActions: needsConfirmation)
            defer { fixture.cleanUp() }
            let item = TodoItem(title: "需要完成的事项")
            fixture.container.mainContext.insert(item)
            try fixture.container.mainContext.save()
            let args = String(data: try JSONSerialization.data(withJSONObject: ["id": item.id.uuidString]), encoding: .utf8)!
            let toolResponse: [String: Any] = ["choices": [["message": ["content": "", "tool_calls": [
                ["id": "complete", "type": "function", "function": ["name": "complete_todo", "arguments": args]]
            ]]]]]
            SessionURLProtocol.responses = [String(data: try JSONSerialization.data(withJSONObject: toolResponse), encoding: .utf8)!,
                #"{"choices":[{"message":{"content":""}}]}"#]
            fixture.model.prompt = "标记事项已经完成"
            fixture.model.submit()
            try await waitForCompletion(fixture.model)
            XCTAssertEqual(item.isCompleted, !needsConfirmation)
            XCTAssertEqual(fixture.model.proposals.count, needsConfirmation ? 1 : 0)
            let messages = try XCTUnwrap(SessionURLProtocol.requests.first?["messages"] as? [[String: Any]])
            let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(system.contains(needsConfirmation ? "当前普通操作需要确认" : "当前普通操作无需确认"))
            if !needsConfirmation {
                XCTAssertFalse(fixture.model.response.contains("待确认"))
                XCTAssertTrue(fixture.model.response.contains("已执行"))
            }
        }
    }

    func testPendingActionsSurviveCloseAndReopenUntilConfirmed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        SessionURLProtocol.responses = [Self.createTodoResponse, Self.replyResponse]
        fixture.controller.show()
        fixture.model.prompt = "添加任务"
        fixture.model.submit()
        fixture.controller.close()
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(fixture.model.proposals.count, 1)
        XCTAssertEqual(fixture.presenter.replies.first?.pendingActionCount, 1)
        XCTAssertEqual(fixture.presenter.replies.first?.openButtonTitle, "查看待确认操作")
        XCTAssertEqual(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 0)
        fixture.controller.show()
        XCTAssertEqual(fixture.model.proposals.count, 1)
        fixture.model.applyAllProposals()
        XCTAssertEqual(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 1)
    }

    func testNewConversationCancelsOldRequestAndSuppressesStaleReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.prompt = "旧问题"
        let oldSession = fixture.model.sessionID
        fixture.model.submit()
        try await Task.sleep(for: .milliseconds(20))
        fixture.controller.startNewConversation()
        XCTAssertNotEqual(fixture.model.sessionID, oldSession)
        XCTAssertEqual(fixture.model.state, .idle)
        XCTAssertTrue(fixture.model.conversation.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(fixture.model.response.isEmpty)
        XCTAssertTrue(fixture.presenter.replies.isEmpty)
        fixture.model.prompt = "新问题"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        let messages = try XCTUnwrap(SessionURLProtocol.requests.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }, ["新问题"])
        XCTAssertEqual(fixture.presenter.replies.count, 1)
    }

    func testReopeningDuringCloseAnimationDoesNotHideTheReopenedWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        fixture.controller.show()
        let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible })
        fixture.controller.close()
        fixture.controller.show()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
    }

    func testBackgroundFailureNotifiesAndKeepsDraftForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        AIAPIKeyStore(defaults: fixture.defaults).saveAPIKey("")
        fixture.model.prompt = "重试这句话"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        XCTAssertTrue(fixture.model.state.isFailure)
        XCTAssertEqual(fixture.model.prompt, "重试这句话")
        XCTAssertEqual(fixture.presenter.replies.count, 1)
        XCTAssertEqual(fixture.presenter.replies.first?.isFailure, true)
        fixture.controller.show()
        XCTAssertTrue(fixture.model.state.isFailure)
        XCTAssertEqual(fixture.model.prompt, "重试这句话")
    }

    func testReplyPresenterUsesReminderPanelWithoutStealingFocusAndCanDismissPendingReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let history = ReminderHistoryStore(defaults: fixture.defaults)
        let presenter = ReminderPresenter(modelContext: fixture.container.mainContext, historyStore: history, defaults: fixture.defaults)
        defer { presenter.dismissAssistantReply() }
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let reply = AIAssistantReply(sessionID: UUID(), message: "已在后台整理好今天的待办，可以继续对话。", pendingActionCount: 0, isFailure: false)
        presenter.presentAssistantReply(reply, onOpenChat: {})
        try await Task.sleep(for: .seconds(ReminderPresentationTiming.panelDelayAfterFlash + ReminderPresentationTiming.panelExpansionDuration + 0.1))
        let panel = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.ignoresMouseEvents && $0.level == .statusBar
        })
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(history.entries().isEmpty, "Chat replies should not affect deadline reminder deduplication")
        let view = try XCTUnwrap(panel.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Background AI reply"
        attachment.lifetime = .keepAlways
        add(attachment)
        presenter.dismissAssistantReply()
        XCTAssertFalse(panel.isVisible)

        presenter.presentAssistantReply(reply, onOpenChat: {})
        presenter.dismissAssistantReply()
        try await Task.sleep(for: .seconds(ReminderPresentationTiming.panelDelayAfterFlash + 0.1))
        XCTAssertFalse(NSApp.windows.contains {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.ignoresMouseEvents && $0.level == .statusBar
        })
    }

    func testReminderAndReplyAreQueuedInBothArrivalOrders() async throws {
        for replyFirst in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let settings = ReminderSettings(systemNotificationsEnabled: false, reminderPanelAutoCloseDelay: 2)
            settings.save(to: fixture.defaults)
            let presenter = ReminderPresenter(modelContext: fixture.container.mainContext,
                                               historyStore: ReminderHistoryStore(defaults: fixture.defaults), defaults: fixture.defaults)
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            let reply = AIAssistantReply(sessionID: UUID(), message: "后台回复", pendingActionCount: 0, isFailure: false)
            let decision = ReminderDecision(shouldRemind: true, message: "事项提醒", todoReferences: [], snoozeSuggestion: nil)
            let presentReply = { presenter.presentAssistantReply(reply, onOpenChat: {}) }
            let presentReminder = { presenter.present(decision: decision, trigger: .aiPoll, settings: settings) }
            (replyFirst ? presentReply : presentReminder)()
            try await Task.sleep(for: .milliseconds(50))
            (replyFirst ? presentReminder : presentReply)()
            try await Task.sleep(for: .seconds(ReminderPresentationTiming.panelDelayAfterFlash + 0.2))
            let first = try XCTUnwrap(NSApp.windows.first {
                !existing.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.ignoresMouseEvents && $0.level == .statusBar
            })
            XCTAssertEqual(first.title, replyFirst ? "AI 回复" : "提醒")
            try await Task.sleep(for: .seconds(2 + ReminderPresentationTiming.panelExpansionDuration + ReminderPresentationTiming.panelCollapseDuration + 0.1))
            let second = try XCTUnwrap(NSApp.windows.first {
                !existing.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.ignoresMouseEvents && $0.level == .statusBar
            })
            XCTAssertFalse(first === second)
            XCTAssertEqual(second.title, replyFirst ? "提醒" : "AI 回复")
            presenter.dismissAssistantReply()
            second.orderOut(nil)
        }
    }

    private func waitForCompletion(_ model: AIAssistantModel) async throws {
        for _ in 0..<150 where model.state == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(model.state, .loading)
    }

    static let replyResponse = #"{"choices":[{"message":{"content":"回复内容"}}]}"#
    static let createTodoResponse = #"{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"create_todo","arguments":"{\"title\":\"后台任务\",\"priority\":\"high\"}"}}]}}]}"#

    private final class Fixture {
        let suite = "AssistantSessionTests-\(UUID().uuidString)"
        let container: ModelContainer
        let defaults: UserDefaults
        let model: AIAssistantModel
        let controller: AIAssistantPanelController
        let presenter = RecordingReplyPresenter()

        init(confirmActions: Bool = true) throws {
            defaults = UserDefaults(suiteName: suite)!
            AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "test", requiresActionConfirmation: confirmActions).save(to: defaults)
            let keyStore = AIAPIKeyStore(defaults: defaults)
            keyStore.saveAPIKey("test-key")
            container = try TestSupport.makeInMemoryContainer()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SessionURLProtocol.self]
            SessionURLProtocol.responses = []
            SessionURLProtocol.requests = []
            model = AIAssistantModel(modelContext: container.mainContext,
                                     client: AIClient(session: URLSession(configuration: configuration)),
                                     apiKeyStore: keyStore, defaults: defaults)
            controller = AIAssistantPanelController(modelContext: container.mainContext, model: model, replyPresenter: presenter)
        }

        func cleanUp() {
            controller.close()
            controller.startNewConversation()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class RecordingReplyPresenter: AIAssistantReplyPresenting {
    var replies: [AIAssistantReply] = []
    var openChat: (() -> Void)?
    func presentAssistantReply(_ reply: AIAssistantReply, onOpenChat: @escaping () -> Void) {
        replies.append(reply)
        openChat = onOpenChat
    }
    func dismissAssistantReply() { openChat = nil }
}

private final class SessionURLProtocol: URLProtocol {
    static var responses: [String] = []
    static var requests: [[String: Any]] = []
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
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.requests.append(body)
        }
        let body = Self.responses.isEmpty ? #"{"choices":[{"message":{"content":"回复内容"}}]}"# : Self.responses.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
