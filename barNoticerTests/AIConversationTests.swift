import XCTest
import SwiftData
@testable import barNoticer

final class AIConversationTests: XCTestCase {
    func testConversationHistoryKeepsRecentTurnsAsChatMessages() {
        var history = AIConversationHistory(maxTurns: 2)
        history.appendUser("第一问")
        history.appendAssistant("第一答")
        history.appendUser("第二问")
        history.appendAssistant("第二答")
        history.appendUser("第三问")

        XCTAssertEqual(history.messages.map(\.role), ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(history.messages.map(\.content), ["第一问", "第一答", "第二问", "第二答", "第三问"])
    }

    func testConversationHistoryExposesVisibleUserAndAssistantEntries() {
        var history = AIConversationHistory(maxTurns: 3)
        history.appendUser("今天做什么")
        history.appendAssistant("")
        history.appendAssistant("先处理高优先级")

        XCTAssertEqual(history.visibleEntries.map(\.role), [.user, .assistant])
        XCTAssertEqual(history.visibleEntries.map(\.content), ["今天做什么", "先处理高优先级"])
    }

    func testConversationHistoryCanBeClearedWhenPanelCloses() {
        var history = AIConversationHistory(maxTurns: 3)
        history.appendUser("新增一个事项")
        history.appendAssistant("已提出新增事项")

        history.reset()

        XCTAssertTrue(history.messages.isEmpty)
        XCTAssertFalse(history.hasVisibleContent)
    }

    func testTodoReferenceParserSplitsModelTextIntoTextAndTodoReferences() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let parts = AITodoReferenceParser.parse("建议先处理 [[todo:\(id.uuidString)]]，再复盘。")

        XCTAssertEqual(parts, [
            .text("建议先处理"),
            .todo(id),
            .text("，再复盘。")
        ])
    }

    func testTodoReferenceParserRemovesMarkdownNoiseAroundReferences() {
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let parts = AITodoReferenceParser.parse("""
        根据当前记录，今天共新增了 **4 条事项**，均未完成：

        - [[todo:\(id.uuidString)]] (高)
        -
        """)

        XCTAssertEqual(parts, [
            .text("根据当前记录，今天共新增了 4 条事项，均未完成："),
            .todo(id)
        ])
    }

    func testTodoReferenceParserRemovesSeparatorTextBetweenAdjacentTodoCards() {
        let first = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let second = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let parts = AITodoReferenceParser.parse("[[todo:\(first.uuidString)]]、[[todo:\(second.uuidString)]]")

        XCTAssertEqual(parts, [
            .todo(first),
            .todo(second)
        ])
    }

    func testTodoReferenceParserAcceptsBareUUIDReferencesFromModelOutput() {
        let first = UUID(uuidString: "DA13451E-ADC7-485D-97D1-DCC56615875D")!
        let second = UUID(uuidString: "F64E0416-573E-4A83-B16F-0A4C005979C6")!

        let parts = AITodoReferenceParser.parse("明天最重要的事是[[\(first.uuidString)]]，之后可以着手[[\(second.uuidString)]]。")

        XCTAssertEqual(parts, [
            .text("明天最重要的事是"),
            .todo(first),
            .text("，之后可以着手"),
            .todo(second),
            .text("。")
        ])
    }

    func testTodoReferenceParserKeepsTextAndMultipleReferencesFromLoggedReply() {
        let first = UUID(uuidString: "56272897-7575-4190-8424-F3599BD5FCA7")!
        let second = UUID(uuidString: "F64E0416-573E-4A83-B16F-0A4C005979C6")!
        let third = UUID(uuidString: "1A571905-E64F-4D23-BD61-3371A9E4AFFE")!

        let parts = AITodoReferenceParser.parse("目前有 3 项未完成待办： 默认分组：[[todo:\(first.uuidString)]] 课程分组：[[todo:\(second.uuidString)]][[todo:\(third.uuidString)]]")

        XCTAssertEqual(parts, [
            .text("目前有 3 项未完成待办： 默认分组："),
            .todo(first),
            .text("课程分组："),
            .todo(second),
            .todo(third)
        ])
    }

    func testSanitizedResponseCanDetectInvisibleModelOutput() {
        XCTAssertFalse(AIVisibleResponse.hasVisibleContent("   \n\n"))
        XCTAssertFalse(AIVisibleResponse.hasVisibleContent("- **"))
        XCTAssertTrue(AIVisibleResponse.hasVisibleContent("已更新任务"))
    }

    func testFallbackResponseForPendingProposalIsVisible() {
        let fallback = AIVisibleResponse.fallbackText(toolCallCount: 1, proposalCount: 1)

        XCTAssertEqual(fallback, "已整理出 1 项待确认操作。")
        XCTAssertTrue(AIVisibleResponse.hasVisibleContent(fallback))
    }

    func testFallbackResponseForPlainEmptyReplyIsVisible() {
        let fallback = AIVisibleResponse.fallbackText(toolCallCount: 0, proposalCount: 0)

        XCTAssertEqual(fallback, "已完成。")
        XCTAssertTrue(AIVisibleResponse.hasVisibleContent(fallback))
    }

    func testFallbackResponseForStatsToolMentionsSummaryResult() {
        let fallback = AIVisibleResponse.fallbackText(toolNames: ["get_completion_stats"], proposalCount: 0)

        XCTAssertEqual(fallback, "已读取今日任务统计。")
        XCTAssertTrue(AIVisibleResponse.hasVisibleContent(fallback))
    }

    func testFallbackResponseForCompletedListToolMentionsCompletedTodos() {
        let fallback = AIVisibleResponse.fallbackText(toolNames: ["list_completed_todos"], proposalCount: 0)

        XCTAssertEqual(fallback, "已读取已完成事项。")
        XCTAssertTrue(AIVisibleResponse.hasVisibleContent(fallback))
    }

    func testSystemPromptDescribesTodoReferenceSyntax() {
        XCTAssertTrue(AISystemPrompt.text.contains("[[todo:"))
    }

    func testSystemPromptAvoidsDuplicatingRenderedTodoDetails() {
        XCTAssertTrue(AISystemPrompt.text.contains("不要在标记之外重复"))
    }

    func testSystemPromptAvoidsSeparatorsBetweenEnumeratedTodoReferences() {
        XCTAssertTrue(AISystemPrompt.text.contains("连续列举多个事项引用时"))
        XCTAssertTrue(AISystemPrompt.text.contains("引用标记之间不要插入任何文字或标点"))
    }

    func testSystemPromptKeepsAssistantInsideTaskManagementRole() {
        XCTAssertTrue(AISystemPrompt.text.contains("只负责管理事项"))
        XCTAssertTrue(AISystemPrompt.text.contains("不要向用户询问是否需要"))
    }

    func testSystemPromptRequiresPlainTextInsteadOfMarkdown() {
        XCTAssertTrue(AISystemPrompt.text.contains("不要使用 Markdown"))
    }

    func testSystemPromptUsesCurrentContextForRelativeDates() {
        XCTAssertTrue(AISystemPrompt.text.contains("相对日期"))
        XCTAssertTrue(AISystemPrompt.text.contains("今天、明天、下周"))
        XCTAssertTrue(AISystemPrompt.text.contains("当前本地时间"))
        XCTAssertTrue(AISystemPrompt.text.contains("deadlineLocal"))
    }

    func testRequestBuilderIncludesInlineTodoContextBeforeConversation() {
        var history = AIConversationHistory(maxTurns: 3)
        history.appendUser("帮我分析")

        let messages = AIAssistantRequestBuilder.makeMessages(
            systemPrompt: "system",
            inlineContext: AITodoInlineContext(content: "context"),
            conversation: history
        )

        XCTAssertEqual(messages.map(\.role), ["system", "system", "user"])
        XCTAssertEqual(messages.map(\.content), ["system", "context", "帮我分析"])
    }

    func testInlineTodoContextContainsReferenceableIDsAndGroupedPriorities() {
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let group = TodoGroup(name: "工作", colorHex: "#3B82F6", sortOrder: 1)
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TodoItem(id: id, title: "准备周报", priority: .high, groupID: group.id, deadlineAt: deadline)
        let snapshot = AITodoContext.snapshot(items: [item], groups: [group])

        let context = snapshot.inlineContext().content

        XCTAssertTrue(context.contains(id.uuidString))
        XCTAssertTrue(context.contains("高重要性"))
        XCTAssertTrue(context.contains("group=工作"))
        XCTAssertTrue(context.contains("deadlineAt="))
        XCTAssertTrue(context.contains("scheduleKind="))
        XCTAssertTrue(context.contains("nextOccurrenceAt="))
        XCTAssertTrue(context.contains("[[todo:<UUID>]]"))
    }

    func testInlineTodoContextIncludesRecurringScheduleFields() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TodoItem(title: "隔三天复盘", priority: .medium, recurrenceRule: .everyNDays(3), recurrenceAnchor: anchor)
        let snapshot = AITodoContext.snapshot(items: [item], groups: [], now: anchor.addingTimeInterval(60))

        let context = snapshot.inlineContext(now: anchor.addingTimeInterval(60)).content

        XCTAssertTrue(context.contains("scheduleKind=recurring"))
        XCTAssertTrue(context.contains("recurrenceRule=every_n_days:3"))
        XCTAssertTrue(context.contains("recurrenceAnchor="))
        XCTAssertTrue(context.contains("nextOccurrenceAt="))
    }

    func testInlineTodoContextContainsCurrentDateAndTimezoneForRelativeDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AITodoContext.snapshot(items: [], groups: [], now: now)

        let context = snapshot.inlineContext(now: now, timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!).content

        XCTAssertTrue(context.contains("当前本地时间："))
        XCTAssertTrue(context.contains("当前 ISO8601："))
        XCTAssertTrue(context.contains("时区：GMT+08:00"))
        XCTAssertTrue(context.contains("相对日期"))
    }

    func testInlineTodoContextUsesLocalDeadlineIndependentOfCreationDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 26, hour: 9, minute: 0))!
        let createdAt = calendar.date(from: DateComponents(year: 2026, month: 5, day: 25, hour: 20, minute: 0))!
        let updatedAt = calendar.date(from: DateComponents(year: 2026, month: 5, day: 26, hour: 8, minute: 50))!
        let deadline = calendar.date(from: DateComponents(year: 2026, month: 5, day: 26, hour: 14, minute: 0))!
        let item = TodoItem(
            title: "打印信息论电子版作业",
            priority: .high,
            deadlineAt: deadline,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let snapshot = AITodoContext.snapshot(items: [item], groups: [], now: now)

        let context = snapshot.inlineContext(now: now, timeZone: calendar.timeZone).content

        XCTAssertTrue(context.contains("当前本地时间：2026-05-26 09:00"))
        XCTAssertTrue(context.contains("deadlineLocal=2026-05-26 14:00"))
        XCTAssertTrue(context.contains("nextOccurrenceLocal=2026-05-26 14:00"))
        XCTAssertTrue(context.contains("不要根据 createdAt 或 updatedAt 推断截止日期"))
    }

    @MainActor
    func testAssistantWritesUserPromptAndVisibleReplyToDebugLog() async throws {
        let suiteName = "AIConversationLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model").save(to: defaults)
        let keyStore = AIAPIKeyStore(defaults: defaults)
        keyStore.saveAPIKey("test-api-key")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIConversationLogTests-\(UUID().uuidString)")
        let logStore = AppDebugLogStore(directory: directory, retentionDays: 7, maxFileSize: 8_192)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIConversationLogURLProtocol.self]
        AIConversationLogURLProtocol.responseBody = #"{"choices":[{"message":{"content":"建议先完成高优先级事项。"}}]}"#

        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = AIAssistantModel(
            modelContext: container.mainContext,
            client: AIClient(session: URLSession(configuration: sessionConfiguration)),
            apiKeyStore: keyStore,
            defaults: defaults,
            logStore: logStore
        )

        model.prompt = "今天该做什么"
        model.submit()

        try await waitUntil {
            if case .ready = model.state {
                return true
            }
            return false
        }

        let content = try String(contentsOf: logStore.logFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[AIChat] User"))
        XCTAssertTrue(content.contains("content=今天该做什么"))
        XCTAssertTrue(content.contains("[AIChat] Assistant"))
        XCTAssertTrue(content.contains("content=建议先完成高优先级事项。"))
    }

    @MainActor
    func testAssistantClearsVisibleOutputWhileWaitingForNextReply() async throws {
        let suiteName = "AIConversationLoadingStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model").save(to: defaults)
        let keyStore = AIAPIKeyStore(defaults: defaults)
        keyStore.saveAPIKey("test-api-key")

        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIConversationLogURLProtocol.self]
        let model = AIAssistantModel(
            modelContext: container.mainContext,
            client: AIClient(session: URLSession(configuration: sessionConfiguration)),
            apiKeyStore: keyStore,
            defaults: defaults,
            logStore: AppDebugLogStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("AIConversationLoadingStateTests-\(UUID().uuidString)"))
        )

        AIConversationLogURLProtocol.responseBody = #"{"choices":[{"message":{"content":"上一轮回复"}}]}"#
        AIConversationLogURLProtocol.responseDelay = 0
        model.prompt = "第一问"
        model.submit()

        try await waitUntil {
            model.response == "上一轮回复"
        }

        AIConversationLogURLProtocol.responseBody = #"{"choices":[{"message":{"content":"新回复"}}]}"#
        AIConversationLogURLProtocol.responseDelay = 0.25
        model.prompt = "第二问"
        model.submit()

        XCTAssertEqual(model.response, "")
        XCTAssertFalse(model.hasTransientOutput)
        XCTAssertEqual(model.state, .loading)

        try await waitUntil {
            model.response == "新回复"
        }

        AIConversationLogURLProtocol.responseDelay = 0
    }

    @MainActor
    func testAssistantContinuesToolLoopAcrossMultipleModelResponses() async throws {
        let suiteName = "AIConversationToolLoopTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model", requiresActionConfirmation: false).save(to: defaults)
        let keyStore = AIAPIKeyStore(defaults: defaults)
        keyStore.saveAPIKey("test-api-key")

        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        AIConversationSequenceURLProtocol.responseBodies = [
            #"{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"create_todo","arguments":"{\"title\":\"第一项\",\"priority\":\"high\"}"}}]}}]}"#,
            #"{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-2","type":"function","function":{"name":"create_todo","arguments":"{\"title\":\"第二项\",\"priority\":\"medium\"}"}}]}}]}"#,
            #"{"choices":[{"message":{"content":"已连续新增两项。"}}]}"#
        ]
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIConversationSequenceURLProtocol.self]
        let model = AIAssistantModel(
            modelContext: container.mainContext,
            client: AIClient(session: URLSession(configuration: sessionConfiguration)),
            apiKeyStore: keyStore,
            defaults: defaults,
            logStore: AppDebugLogStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("AIConversationToolLoopTests-\(UUID().uuidString)"))
        )

        model.prompt = "新增两个事项"
        model.submit()

        try await waitUntil {
            model.response == "已连续新增两项。"
        }

        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(items.map(\.title).sorted(), ["第一项", "第二项"])
        XCTAssertTrue(model.proposals.isEmpty)
    }
}

private final class AIConversationLogURLProtocol: URLProtocol {
    static var responseBody = #"{"choices":[{"message":{"content":"OK"}}]}"#
    static var responseDelay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let sendResponse = { [weak self] in
            guard let self else { return }
            let data = Data(Self.responseBody.utf8)
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if Self.responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay, execute: sendResponse)
        } else {
            sendResponse()
        }
    }

    override func stopLoading() {}
}

private final class AIConversationSequenceURLProtocol: URLProtocol {
    static var responseBodies: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.responseBodies.isEmpty ? #"{"choices":[{"message":{"content":"OK"}}]}"# : Self.responseBodies.removeFirst()
        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @MainActor @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for condition")
}
