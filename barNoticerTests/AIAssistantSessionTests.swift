import AppKit
import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class AIAssistantSessionTests: XCTestCase {
    func testEscapeResetsConversationThenClosesEmptyWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.prompt = "第一问"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        fixture.controller.show()
        let priorSession = fixture.model.sessionID

        fixture.controller.handleEscape()

        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertNotEqual(fixture.model.sessionID, priorSession)
        XCTAssertTrue(fixture.model.conversation.messages.isEmpty)
        XCTAssertTrue(fixture.model.prompt.isEmpty)
        XCTAssertTrue(fixture.model.response.isEmpty)
        let emptySession = fixture.model.sessionID

        fixture.controller.handleEscape()

        XCTAssertFalse(fixture.controller.isPresented)
        XCTAssertEqual(fixture.model.sessionID, emptySession)
    }

    func testEscapeClearsDraftAndCancelsLoadingWithoutPublishingStaleReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show()
        fixture.model.prompt = "尚未发送"
        fixture.controller.handleEscape()
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertTrue(fixture.model.prompt.isEmpty)

        fixture.model.prompt = "正在发送"
        fixture.model.submit()
        XCTAssertEqual(fixture.model.state, .loading)
        fixture.controller.handleEscape()
        XCTAssertEqual(fixture.model.state, .idle)
        XCTAssertTrue(fixture.controller.isPresented)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(fixture.presenter.replies.isEmpty)
        XCTAssertTrue(fixture.model.response.isEmpty)
    }

    func testNativeWindowEscapeUsesResetThenCloseAndImageDraftIsNotEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        fixture.model.addImages([try AIImageAttachment(data: XCTUnwrap(image.tiffRepresentation), name: "图片")])
        XCTAssertFalse(fixture.model.isConversationEmpty)
        let previousWindows = NSApp.windows
        fixture.controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first { window in
            !previousWindows.contains(where: { $0 === window }) && window.isVisible
        })
        panel.cancelOperation(nil)
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertTrue(fixture.model.images.isEmpty)
        panel.cancelOperation(nil)
        XCTAssertFalse(fixture.controller.isPresented)
    }

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

    func testCompletedStreamKeepsExpandedPanelAndReplyScrollable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        SessionURLProtocol.streamBody = Self.partialStreamResponse
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        fixture.controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first { !previous.contains(ObjectIdentifier($0)) && $0.isVisible })
        fixture.model.prompt = "显示完整长回复"
        fixture.model.submit()
        try await waitForResponse(fixture.model, containing: "部分答复")
        let replyHeight = AIAssistantPanelChrome.size(outputKind: .response, hasImages: false,
            hasImageError: false, hasActivity: true).height
        for _ in 0..<100 where abs(panel.frame.height - replyHeight) > 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(panel.frame.height, replyHeight, accuracy: 1)

        let tail = "\n" + (1...40).map { "结果第\($0)行：完成后仍应保留完整回复，可滚动阅读。" }.joined(separator: "\n")
        let chunk = ["choices": [["delta": ["content": tail]]]]
        SessionURLProtocol.sendStreamChunk("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
            + "\n\n" + Self.streamStop, finish: true)
        try await waitForCompletion(fixture.model)
        try await waitForStableFrame(panel)

        XCTAssertEqual(fixture.model.state, .ready)
        XCTAssertEqual(fixture.model.response, "部分答复" + tail)
        XCTAssertTrue(fixture.controller.isPresented)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.height, replyHeight, accuracy: 1)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let reply = try XCTUnwrap(scrollViews(in: content).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
        let document = try XCTUnwrap(reply.documentView)
        XCTAssertTrue(content.bounds.contains(reply.convert(reply.bounds, to: content)))
        XCTAssertGreaterThan(reply.contentView.bounds.height, AIAssistantPanelStyle.activityHeight)
        XCTAssertGreaterThan(document.bounds.height, reply.contentView.bounds.height)
        reply.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.minY))
        reply.reflectScrolledClipView(reply.contentView)
        let start = reply.documentVisibleRect.minY
        reply.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.maxY - reply.contentView.bounds.height))
        reply.reflectScrolledClipView(reply.contentView)
        XCTAssertGreaterThan(reply.documentVisibleRect.minY, start)
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
            if !needsConfirmation {
                XCTAssertFalse(fixture.model.response.contains("待确认"))
                XCTAssertTrue(fixture.model.response.contains("已执行"))
            }
        }
    }

    func testHiddenCreateIsPersistedAsActiveAndVisibleInIndependentContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundCreate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        let fixture = try Fixture(confirmActions: false, configuration: configuration)
        defer { fixture.cleanUp() }
        SessionURLProtocol.responses = [Self.createTodoResponse, Self.replyResponse]
        fixture.controller.show()
        fixture.model.prompt = "添加任务"
        fixture.model.submit()
        fixture.controller.close()
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(fixture.model.state, .ready)
        XCTAssertEqual(fixture.presenter.replies.count, 1)
        let reopened = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self, configurations: configuration)
        let items = try reopened.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(items.map(\.title), ["后台任务"])
        XCTAssertFalse(try XCTUnwrap(items.first).isCompleted)
        XCTAssertTrue(fixture.model.proposals.isEmpty)
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
        SessionURLProtocol.streamBody = Self.partialStreamResponse
        fixture.model.prompt = "旧问题"
        let oldSession = fixture.model.sessionID
        fixture.model.submit()
        try await waitForResponse(fixture.model, containing: "部分答复")
        fixture.controller.startNewConversation()
        XCTAssertNotEqual(fixture.model.sessionID, oldSession)
        XCTAssertEqual(fixture.model.state, .idle)
        XCTAssertTrue(fixture.model.conversation.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(fixture.model.response.isEmpty)
        XCTAssertTrue(fixture.model.activityLines.isEmpty)
        SessionURLProtocol.streamBody = nil
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

    func testInvalidToolArgumentsAreReturnedToModelWithoutReplayingSuccessfulBatchCalls() async throws {
        for confirmActions in [false, true] {
            let fixture = try Fixture(confirmActions: confirmActions)
            defer { fixture.cleanUp() }
            let good: [String: Any] = ["id": "good", "type": "function", "function": [
                "name": "create_todo", "arguments": #"{"title":"后台任务","priority":"high"}"#]]
            let bad: [String: Any] = ["id": "bad", "type": "function", "function": [
                "name": "create_todo", "arguments": #"{"priority":"medium"}"#]]
            let corrected: [String: Any] = ["id": "fixed", "type": "function", "function": [
                "name": "create_todo", "arguments": #"{"title":"修正任务","priority":"medium"}"#]]
            SessionURLProtocol.responses = [try Self.toolResponse([good, bad]), try Self.toolResponse([corrected]), Self.replyResponse]
            fixture.model.prompt = "创建两个任务"
            fixture.model.submit()
            try await waitForCompletion(fixture.model)

            XCTAssertEqual(fixture.model.state, .ready)
            XCTAssertEqual(SessionURLProtocol.requests.count, 3)
            let retryMessages = try XCTUnwrap(SessionURLProtocol.requests[1]["messages"] as? [[String: Any]])
            let outputs = retryMessages.filter { $0["role"] as? String == "tool" }
            XCTAssertEqual(outputs.compactMap { $0["tool_call_id"] as? String }, ["good", "bad"])
            XCTAssertTrue(try XCTUnwrap(outputs.last?["content"] as? String).contains("title"))
            if confirmActions {
                XCTAssertTrue(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).isEmpty)
                XCTAssertEqual(fixture.model.proposals.count, 2)
                fixture.model.applyAllProposals()
            }
            XCTAssertEqual(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).map(\.title).sorted(), ["后台任务", "修正任务"].sorted())
            fixture.model.startNewConversation()
            XCTAssertTrue(fixture.model.activityLines.isEmpty)
        }
    }

    func testRepeatedMalformedArgumentsStopAtToolRoundLimitAndKeepDraft() async throws {
        let fixture = try Fixture(confirmActions: false)
        defer { fixture.cleanUp() }
        let malformed = try Self.toolResponse([["id": "bad", "type": "function", "function": [
            "name": "create_todo", "arguments": "{broken"]]])
        SessionURLProtocol.responses = Array(repeating: malformed, count: 10)
        fixture.model.prompt = "需要修正"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)

        guard case let .failed(message) = fixture.model.state else { return XCTFail("Expected bounded failure") }
        XCTAssertTrue(message.contains("上限"))
        XCTAssertEqual(SessionURLProtocol.requests.count, 6)
        XCTAssertEqual(fixture.model.prompt, "需要修正")
        XCTAssertTrue(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).isEmpty)
    }

    func testOpaqueReasoningWithoutAnswerDoesNotClaimWorkCompleted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let provider = AIProviderConfiguration(name: "Responses", baseURL: "https://example.com/v1",
            responseFormat: .responses, apiKey: "test-key", model: "test")
        AIProviderCollection(providers: [provider], activeID: provider.id).save(to: fixture.defaults)
        SessionURLProtocol.responses = [#"{"status":"completed","output":[{"type":"reasoning","id":"r1","encrypted_content":"opaque","summary":[]}]}"#]
        fixture.model.prompt = "整理事项"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(fixture.model.state, .ready)
        XCTAssertTrue(fixture.model.response.contains("未返回答复"))
        XCTAssertTrue(fixture.model.proposals.isEmpty)
        XCTAssertTrue(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).isEmpty)
    }

    func testInterruptedStreamUpdatesInPlaceAndRestoresDraftWithoutSavingPartialAnswer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        SessionURLProtocol.streamBody = Self.partialStreamResponse
        fixture.model.prompt = "请完整回答"
        fixture.model.submit()
        try await waitForResponse(fixture.model, containing: "部分答复")
        XCTAssertEqual(fixture.model.state, .loading)
        XCTAssertTrue(fixture.model.hasTransientOutput)
        XCTAssertFalse(fixture.model.conversation.messages.contains { $0.role == "assistant" })

        SessionURLProtocol.sendStreamChunk(
            #"data: {"choices":[{"delta":{"content":"继续","reasoning_content":"再想"}}]}"# + "\n\n")
        try await waitForResponse(fixture.model, containing: "继续")
        XCTAssertEqual(fixture.model.activityLines.filter { $0.hasPrefix("思考摘要") }, ["思考摘要 · 先看再想"])
        SessionURLProtocol.sendStreamChunk("", finish: true)
        try await waitForCompletion(fixture.model)

        XCTAssertTrue(fixture.model.state.isFailure)
        XCTAssertTrue(fixture.model.response.contains("回复未完成"))
        XCTAssertTrue(fixture.model.response.contains("部分答复继续"))
        XCTAssertEqual(fixture.model.prompt, "请完整回答")
        XCTAssertTrue(fixture.model.conversation.messages.isEmpty)
        XCTAssertEqual(fixture.presenter.replies.last?.isFailure, true)
    }

    func testMemoryClearSuppressesRemainingStreamOutputAndPreservesRetryDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        SessionURLProtocol.streamBody = Self.partialStreamResponse
        fixture.model.prompt = "读取旧记忆"
        fixture.model.submit()
        try await waitForResponse(fixture.model, containing: "部分答复")
        let memory = AIGlobalMemoryStore(defaults: fixture.defaults)
        try memory.confirmClear(memory.requestClear())

        SessionURLProtocol.sendStreamChunk(
            #"data: {"choices":[{"delta":{"content":"清空后的旧内容"}}]}"# + "\n\n" + Self.streamStop, finish: true)
        try await waitForCompletion(fixture.model)

        XCTAssertTrue(fixture.model.state.isFailure)
        XCTAssertTrue(fixture.model.response.isEmpty)
        XCTAssertFalse(fixture.model.activityLines.contains { $0.contains("先看") })
        XCTAssertEqual(fixture.model.prompt, "读取旧记忆")
        XCTAssertTrue(fixture.model.conversation.messages.isEmpty)
    }

    func testPreparedSummaryRequiresIndividualSaveWithEitherApprovalSetting() async throws {
        for confirmActions in [false, true] {
            let fixture = try Fixture(confirmActions: confirmActions)
            defer { fixture.cleanUp() }
            SessionURLProtocol.responses = [try Self.toolResponse([Self.summaryCall()])]
            fixture.model.prompt = "总结上周并保存"
            fixture.model.submit()
            try await waitForCompletion(fixture.model)
            XCTAssertEqual(fixture.model.state, .ready)
            XCTAssertEqual(SessionURLProtocol.requests.count, 1, "A prepared draft must not need another model reply")
            XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
            XCTAssertTrue(SummaryStore(directoryURL: fixture.summaryStore.directoryURL).summaries.isEmpty)
            XCTAssertTrue(fixture.model.response.contains("一周回顾"))
            XCTAssertTrue(fixture.model.response.contains("完成调研，下一步撰写报告。"))
            XCTAssertTrue(fixture.model.response.contains("尚未保存"))
            XCTAssertTrue(fixture.model.response.contains("是否保存这份总结？"))
            let proposal = try XCTUnwrap(fixture.model.proposals.first)
            fixture.model.applyAllProposals()
            XCTAssertEqual(fixture.model.proposals, [proposal])
            XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
            if case let .saveSummary(id, title, start, end, _) = proposal {
                fixture.model.apply(.saveSummary(id: id, title: title, periodStart: start, periodEnd: end, content: "未展示的正文"))
            } else { XCTFail("Expected summary proposal") }
            XCTAssertTrue(fixture.summaryStore.summaries.isEmpty, "Only the exact pending draft can be saved")
            let beforeSave = Date()
            fixture.model.apply(proposal, sessionID: fixture.model.sessionID)
            let saved = try XCTUnwrap(fixture.summaryStore.summaries.first)
            XCTAssertEqual(saved.id, proposal.id)
            XCTAssertEqual(saved.title, "一周回顾")
            XCTAssertEqual(saved.periodStart, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00+08:00"))
            XCTAssertEqual(saved.periodEnd, ISO8601DateFormatter().date(from: "2026-11-08T00:00:00+08:00"))
            XCTAssertEqual(saved.content, "完成调研，下一步撰写报告。")
            XCTAssertGreaterThanOrEqual(saved.createdAt, beforeSave)
            XCTAssertLessThanOrEqual(saved.createdAt, Date())
            XCTAssertTrue(fixture.model.response.contains(saved.periodDescription))
            XCTAssertTrue(fixture.model.response.contains("已保存"))
            XCTAssertFalse(fixture.model.response.contains("是否保存"))
            XCTAssertEqual(fixture.model.conversation.messages.last?.content, fixture.model.response)
            XCTAssertEqual(SummaryStore(directoryURL: fixture.summaryStore.directoryURL).summaries, [saved])
            fixture.model.apply(proposal)
            fixture.model.applyAllProposals()
            XCTAssertEqual(fixture.summaryStore.summaries, [saved], "Duplicate decisions must not save twice")
        }
    }

    func testDismissedAndStaleSummaryDecisionsNeverSave() async throws {
        let fixture = try Fixture(confirmActions: false)
        defer { fixture.cleanUp() }
        SessionURLProtocol.responses = [try Self.toolResponse([Self.summaryCall()])]
        fixture.model.prompt = "生成总结"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        let proposal = try XCTUnwrap(fixture.model.proposals.first)
        let oldSession = fixture.model.sessionID
        fixture.model.dismiss(proposal, sessionID: oldSession)
        fixture.model.apply(proposal, sessionID: oldSession)
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        XCTAssertTrue(fixture.model.proposals.isEmpty)
        XCTAssertTrue(fixture.model.response.contains("未保存"))
        XCTAssertEqual(fixture.model.conversation.messages.last?.content, fixture.model.response)
        fixture.model.startNewConversation()
        fixture.model.stageOrApply([proposal], settings: AISettings(requiresActionConfirmation: false))
        fixture.model.apply(proposal, sessionID: oldSession)
        fixture.model.dismiss(proposal, sessionID: oldSession)
        XCTAssertEqual(fixture.model.proposals, [proposal], "An old callback cannot decide a new conversation's draft")
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        fixture.model.dismissAllProposals()
        fixture.model.apply(proposal)
        XCTAssertTrue(SummaryStore(directoryURL: fixture.summaryStore.directoryURL).summaries.isEmpty)
    }

    func testSummarySaveFailureKeepsExactDraftPendingForRetry() async throws {
        let fixture = try Fixture(confirmActions: false)
        defer { fixture.cleanUp() }
        SessionURLProtocol.responses = [try Self.toolResponse([Self.summaryCall()])]
        fixture.model.prompt = "生成总结"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        let proposal = try XCTUnwrap(fixture.model.proposals.first)
        let directory = fixture.summaryStore.directoryURL
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        fixture.model.apply(proposal)
        XCTAssertTrue(fixture.model.state.isFailure)
        XCTAssertEqual(fixture.model.proposals, [proposal])
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        XCTAssertTrue(fixture.model.response.contains("保存失败，尚未保存"))
        XCTAssertEqual(fixture.model.conversation.messages.last?.content, fixture.model.response)
        try FileManager.default.removeItem(at: directory)
        fixture.model.apply(proposal)
        XCTAssertEqual(fixture.model.state, .ready)
        XCTAssertTrue(fixture.model.proposals.isEmpty)
        XCTAssertEqual(SummaryStore(directoryURL: directory).summaries.count, 1)
    }

    func testSummaryBatchPreservesDraftsOtherActionsErrorsAndMemoryClearBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let memory = AIGlobalMemoryStore(defaults: fixture.defaults)
        try memory.save(key: "称呼", content: "小明", source: .explicit)
        let create: [String: Any] = ["id": "create", "type": "function", "function": [
            "name": "create_todo", "arguments": #"{"title":"后续事项","priority":"high"}"#]]
        let invalid: [String: Any] = ["id": "bad", "type": "function", "function": [
            "name": "create_todo", "arguments": #"{"priority":"medium"}"#]]
        let clear: [String: Any] = ["id": "clear", "type": "function", "function": [
            "name": "clear_global_memory", "arguments": "{}"]]
        let calls = [Self.summaryCall(), create, invalid, Self.summaryCall(id: "second", title: "第二份回顾", content: "另一份完整正文。"), clear]
        let response: [String: Any] = ["choices": [["message": ["content": "已保存所有总结。", "tool_calls": calls]]]]
        SessionURLProtocol.responses = [String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)]
        fixture.model.prompt = "准备两份总结、新建事项，并清空记忆"
        fixture.model.submit()
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(SessionURLProtocol.requests.count, 1)
        XCTAssertEqual(fixture.model.proposals.count, 4)
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        XCTAssertTrue(fixture.model.response.contains("完成调研，下一步撰写报告。"))
        XCTAssertTrue(fixture.model.response.contains("另一份完整正文。"))
        XCTAssertTrue(fixture.model.response.contains("工具调用失败"))
        XCTAssertFalse(fixture.model.response.contains("已保存所有总结"))
        XCTAssertTrue(fixture.model.response.contains("目前尚未清空"))
        fixture.model.applyAllProposals()
        XCTAssertEqual(try fixture.container.mainContext.fetch(FetchDescriptor<TodoItem>()).map(\.title), ["后续事项"])
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        XCTAssertEqual(try memory.read().entries.count, 1)
        let confirmation = try XCTUnwrap(fixture.model.memoryClearConfirmation)
        fixture.model.confirmMemoryClear(confirmation)
        XCTAssertTrue(try memory.read().entries.isEmpty)
        XCTAssertEqual(fixture.model.proposals.count, 2, "Memory confirmation must not discard summary drafts")
        XCTAssertTrue(fixture.model.response.contains("另一份完整正文。"))
        XCTAssertTrue(fixture.model.response.contains("是否保存这份总结？"))
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
    }

    func testStreamingSummaryDoesNotBecomeReadyBeforeValidCompletion() async throws {
        let fixture = try Fixture(confirmActions: false)
        defer { fixture.cleanUp() }
        let delta: [String: Any] = ["choices": [["delta": ["content": "正在生成草稿", "tool_calls": [[
            "index": 0, "id": "summary", "type": "function", "function": Self.summaryCall()["function"]!
        ]]]]]]
        SessionURLProtocol.streamBody = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: delta), as: UTF8.self) + "\n\n"
        fixture.model.prompt = "生成总结"
        fixture.model.submit()
        try await waitForResponse(fixture.model, containing: "正在生成草稿")
        XCTAssertEqual(fixture.model.state, .loading)
        XCTAssertTrue(fixture.model.proposals.isEmpty)
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        XCTAssertFalse(fixture.model.response.contains("是否保存这份总结？"))
        SessionURLProtocol.sendStreamChunk(#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n", finish: true)
        try await waitForCompletion(fixture.model)
        XCTAssertEqual(fixture.model.state, .ready)
        XCTAssertEqual(fixture.model.proposals.count, 1)
        XCTAssertTrue(fixture.model.response.contains("是否保存这份总结？"))
        XCTAssertTrue(fixture.summaryStore.summaries.isEmpty)
        XCTAssertEqual(SessionURLProtocol.requests.count, 1)
    }

    private static func summaryCall(id: String = "summary", title: String = "一周回顾", content: String = "完成调研，下一步撰写报告。") -> [String: Any] {
        let arguments = ["title": title, "period_start": "2026-11-01T00:00:00+08:00", "period_end": "2026-11-08T00:00:00+08:00", "content": content]
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return ["id": id, "type": "function", "function": ["name": "prepare_summary", "arguments": String(decoding: data, as: UTF8.self)]]
    }

    private func waitForStableFrame(_ panel: NSWindow) async throws {
        var previous = panel.frame
        var unchanged = 0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if panel.frame == previous { unchanged += 1 }
            else { previous = panel.frame; unchanged = 0 }
            if unchanged == 8 { return }
        }
        XCTFail("Panel frame never settled")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func waitForResponse(_ model: AIAssistantModel, containing text: String) async throws {
        for _ in 0..<150 where !model.response.contains(text) && model.state == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.response.contains(text))
    }

    private static let partialStreamResponse =
        #"data: {"choices":[{"delta":{"content":"部分答复","reasoning_content":"先看"}}]}"# + "\n\n"
    private static let streamStop =
        #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"

    private static func toolResponse(_ calls: [[String: Any]]) throws -> String {
        let body: [String: Any] = ["choices": [["message": ["content": "", "tool_calls": calls]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
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
        let directory: URL
        let summaryStore: SummaryStore

        init(confirmActions: Bool = true, configuration: ModelConfiguration? = nil) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AssistantSessionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            summaryStore = SummaryStore(directoryURL: directory.appendingPathComponent("Summaries", isDirectory: true))
            defaults = UserDefaults(suiteName: suite)!
            AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "test", requiresActionConfirmation: confirmActions).save(to: defaults)
            let keyStore = AIAPIKeyStore(defaults: defaults)
            keyStore.saveAPIKey("test-key")
            if let configuration {
                container = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self, configurations: configuration)
            } else {
                container = try TestSupport.makeInMemoryContainer()
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SessionURLProtocol.self]
            SessionURLProtocol.responses = []
            SessionURLProtocol.requests = []
            SessionURLProtocol.streamBody = nil
            SessionURLProtocol.pendingStream = nil
            model = AIAssistantModel(modelContext: container.mainContext,
                                     client: AIClient(session: URLSession(configuration: configuration)),
                                     apiKeyStore: keyStore, defaults: defaults,
                                     logStore: AppDebugLogStore(directory: directory.appendingPathComponent("Logs")),
                                     summaryStore: summaryStore)
            controller = AIAssistantPanelController(modelContext: container.mainContext, model: model, replyPresenter: presenter)
        }

        func cleanUp() {
            controller.close()
            controller.startNewConversation()
            SessionURLProtocol.streamBody = nil
            SessionURLProtocol.pendingStream = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
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
    static var streamBody: String?
    static var pendingStream: SessionURLProtocol?

    static func sendStreamChunk(_ chunk: String, finish: Bool = false) {
        guard let stream = pendingStream else { return }
        if !chunk.isEmpty { stream.client?.urlProtocol(stream, didLoad: Data(chunk.utf8)) }
        if finish {
            pendingStream = nil
            stream.client?.urlProtocolDidFinishLoading(stream)
        }
    }

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
        let streamBody = Self.streamBody
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
                headerFields: streamBody == nil ? nil : ["Content-Type": "text/event-stream"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let streamBody {
                Self.pendingStream = self
                self.client?.urlProtocol(self, didLoad: Data(streamBody.utf8))
            } else {
                self.client?.urlProtocol(self, didLoad: Data(body.utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {
        if Self.pendingStream === self { Self.pendingStream = nil }
    }
}
