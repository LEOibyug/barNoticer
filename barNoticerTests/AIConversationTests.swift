import XCTest
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
        let item = TodoItem(id: id, title: "准备周报", priority: .high)
        let snapshot = AITodoContext.snapshot(items: [item])

        let context = snapshot.inlineContext().content

        XCTAssertTrue(context.contains(id.uuidString))
        XCTAssertTrue(context.contains("高重要性"))
        XCTAssertTrue(context.contains("[[todo:<UUID>]]"))
    }
}
