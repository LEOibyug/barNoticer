import XCTest
import SwiftData
@testable import barNoticer

final class AITodoToolTests: XCTestCase {
    func testSnapshotGroupsTodosAndComputesCompletionStats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let work = TodoGroup(name: "工作", colorHex: "#3B82F6", sortOrder: 1)
        let items = [
            TodoItem(title: "High active", priority: .high, groupID: work.id, deadlineAt: now.addingTimeInterval(3_600), createdAt: now.addingTimeInterval(-7_200)),
            TodoItem(title: "Low active", priority: .low, createdAt: now.addingTimeInterval(-3_600)),
            TodoItem(title: "Done", priority: .medium, isCompleted: true, createdAt: now.addingTimeInterval(-10_800), updatedAt: now)
        ]

        let snapshot = AITodoContext.snapshot(items: items, groups: [work], dailySummaries: [], now: now)

        XCTAssertEqual(snapshot.activeByPriority[.high]?.map(\.title), ["High active"])
        XCTAssertEqual(snapshot.activeByPriority[.low]?.map(\.title), ["Low active"])
        XCTAssertEqual(snapshot.groups.map(\.name), ["默认分组", "工作"])
        XCTAssertEqual(snapshot.activeByGroup.last?.items.first?.groupName, "工作")
        XCTAssertEqual(snapshot.activeByGroup.last?.items.first?.deadlineAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(snapshot.completed.map(\.title), ["Done"])
        XCTAssertEqual(snapshot.stats.activeCount, 2)
        XCTAssertEqual(snapshot.stats.completedCount, 1)
        XCTAssertEqual(snapshot.stats.averageCompletionInterval, 10_800)
    }

    func testCreateAndModifyRequestsBecomePendingActionProposals() {
        let groupID = UUID()
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        let create = AIActionProposal.createTodo(title: "Plan v2", priority: .high)
        let id = UUID()
        let update = AIActionProposal.updateTodo(id: id, title: "Plan v2 carefully", priority: .medium, groupID: groupID, deadlineAt: deadline, clearsDeadline: false)
        let complete = AIActionProposal.completeTodo(id: id)
        let delete = AIActionProposal.deleteTodo(id: id)
        let createWithMetadata = AIActionProposal.createTodo(title: "Plan v3", priority: .high, groupID: groupID, deadlineAt: deadline)

        XCTAssertEqual(create.summary, "新增高重要性事项：Plan v2")
        XCTAssertEqual(createWithMetadata.groupID, groupID)
        XCTAssertEqual(createWithMetadata.deadlineAt, deadline)
        XCTAssertEqual(update.summary, "修改事项：Plan v2 carefully，重要性：中")
        XCTAssertEqual(complete.summary, "完成事项：\(id.uuidString)")
        XCTAssertEqual(delete.summary, "删除事项：\(id.uuidString)")
        XCTAssertTrue(create.requiresConfirmation)
        XCTAssertTrue(update.requiresConfirmation)
        XCTAssertTrue(complete.requiresConfirmation)
        XCTAssertTrue(delete.requiresConfirmation)
    }

    func testCompleteTodoProposalExposesTodoReferenceForRendering() {
        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let complete = AIActionProposal.completeTodo(id: id)
        let delete = AIActionProposal.deleteTodo(id: id)

        XCTAssertEqual(complete.referencedTodoID, id)
        XCTAssertEqual(delete.referencedTodoID, id)
    }

    @MainActor
    func testDeleteTodoToolCreatesPendingProposalAndAppliesDeletion() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let item = TodoItem(title: "Remove me", priority: .medium)
        container.mainContext.insert(item)
        try container.mainContext.save()

        let executor = AIToolExecutor(modelContext: container.mainContext)
        let call = AIToolCall(
            id: "delete-call",
            type: "function",
            function: .init(name: "delete_todo", arguments: #"{"id":"\#(item.id.uuidString)"}"#)
        )

        let result = try executor.handle(call)
        XCTAssertEqual(result, .proposal(.deleteTodo(id: item.id)))

        try executor.apply(.deleteTodo(id: item.id))
        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertTrue(items.isEmpty)
    }

    @MainActor
    func testAssistantAppliesProposalsImmediatelyWhenConfirmationIsDisabled() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = AIAssistantModel(modelContext: container.mainContext)

        model.stageOrApply(
            [.createTodo(title: "Write paper", priority: .high)],
            settings: AISettings(requiresActionConfirmation: false)
        )

        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(items.map(\.title), ["Write paper"])
        XCTAssertTrue(model.proposals.isEmpty)
    }

    @MainActor
    func testApplyingCreateTodoUsesProposalIDAndReturnsCreatedReference() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let result = try executor.apply(.createTodo(id: id, title: "Read paper", priority: .high))

        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(items.first?.id, id)
        XCTAssertEqual(result, .createdTodo(id: id, title: "Read paper"))
        XCTAssertTrue(result.toolMessage.contains("[[todo:\(id.uuidString)]]"))
    }

    @MainActor
    func testAssistantKeepsProposalsPendingWhenConfirmationIsEnabled() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = AIAssistantModel(modelContext: container.mainContext)
        let proposal = AIActionProposal.createTodo(title: "Write paper", priority: .high)

        model.stageOrApply([proposal], settings: AISettings(requiresActionConfirmation: true))

        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(model.proposals, [proposal])
    }

    @MainActor
    func testAssistantCanApplyAndDismissProposalBatches() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let model = AIAssistantModel(modelContext: container.mainContext)
        let proposals: [AIActionProposal] = [
            .createTodo(title: "First batch item", priority: .high),
            .createTodo(title: "Second batch item", priority: .medium)
        ]

        model.stageOrApply(proposals, settings: AISettings(requiresActionConfirmation: true))
        model.applyAllProposals()

        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(items.map(\.title).sorted(), ["First batch item", "Second batch item"])
        XCTAssertTrue(model.proposals.isEmpty)

        model.stageOrApply([.createTodo(title: "Ignored item", priority: .low)], settings: AISettings(requiresActionConfirmation: true))
        model.dismissAllProposals()

        XCTAssertTrue(model.proposals.isEmpty)
    }

    func testAssistantProgressTextReflectsToolActivity() {
        XCTAssertEqual(AIAssistantProgress.idle.displayText, "")
        XCTAssertEqual(AIAssistantProgress.thinking.displayText, "思考中...")
        XCTAssertEqual(AIAssistantProgress.readingTodos.displayText, "阅览事项中...")
        XCTAssertEqual(AIAssistantProgress.preparingActions.displayText, "整理操作建议中...")

        XCTAssertEqual(AIAssistantProgress.progress(forToolName: "list_active_todos"), .readingTodos)
        XCTAssertEqual(AIAssistantProgress.progress(forToolName: "create_todo"), .preparingActions)
        XCTAssertEqual(AIAssistantProgress.progress(forToolName: "delete_todo"), .preparingActions)
    }

    @MainActor
    func testCreateTodoToolAcceptsGroupAndDeadline() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let group = TodoGroup(name: "工作", colorHex: "#3B82F6", sortOrder: 1)
        container.mainContext.insert(group)
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let deadline = ISO8601DateFormatter().date(from: "2026-05-23T18:30:00Z")
        let call = AIToolCall(
            id: "create-call",
            type: "function",
            function: .init(name: "create_todo", arguments: #"{"title":"写周报","priority":"high","group_id":"\#(group.id.uuidString)","deadline_at":"2026-05-23T18:30:00Z"}"#)
        )

        let result = try executor.handle(call)

        guard case let .proposal(.createTodo(_, title, priority, groupID, deadlineAt, _, _, _)) = result else {
            return XCTFail("Expected create todo proposal")
        }
        XCTAssertEqual(title, "写周报")
        XCTAssertEqual(priority, .high)
        XCTAssertEqual(groupID, group.id)
        XCTAssertEqual(deadlineAt, deadline)
    }

    @MainActor
    func testCreateTodoToolAcceptsMultipleTimesAndRecurrence() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let call = AIToolCall(
            id: "create-schedule-call",
            type: "function",
            function: .init(
                name: "create_todo",
                arguments: #"{"title":"喝水","priority":"medium","scheduled_times":["2026-05-24T09:00:00Z","2026-05-24T15:00:00Z"],"recurrence_rule":"daily","recurrence_anchor":"2026-05-24T09:00:00Z"}"#
            )
        )

        let result = try executor.handle(call)

        guard case let .proposal(.createTodo(_, title, priority, _, deadlineAt, scheduledTimes, recurrenceRule, recurrenceAnchor)) = result else {
            return XCTFail("Expected scheduled create todo proposal")
        }
        XCTAssertEqual(title, "喝水")
        XCTAssertEqual(priority, .medium)
        XCTAssertNil(deadlineAt)
        XCTAssertEqual(scheduledTimes.count, 2)
        XCTAssertEqual(recurrenceRule, .daily)
        XCTAssertEqual(recurrenceAnchor, ISO8601DateFormatter().date(from: "2026-05-24T09:00:00Z"))
    }

    @MainActor
    func testRecurringTodoCompletionProposalRollsForwardInsteadOfCompleting() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let anchor = ISO8601DateFormatter().date(from: "2026-05-24T09:00:00Z")!
        let item = TodoItem(title: "每日站会", recurrenceRule: .daily, recurrenceAnchor: anchor)
        container.mainContext.insert(item)
        try container.mainContext.save()
        let executor = AIToolExecutor(modelContext: container.mainContext)

        try executor.apply(.completeTodo(id: item.id))

        XCTAssertFalse(item.isCompleted)
        XCTAssertNotNil(item.lastCompletedOccurrenceAt)
        XCTAssertGreaterThan(item.nextOccurrence(after: anchor)!, anchor)
    }

    @MainActor
    func testGroupToolsCreateUpdateListAndDeleteGroups() throws {
        let container = try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let create = AIToolCall(
            id: "group-create",
            type: "function",
            function: .init(name: "create_group", arguments: ##"{"name":"工作","color_hex":"#3B82F6"}"##)
        )

        guard case let .proposal(.createGroup(_, name, colorHex)) = try executor.handle(create) else {
            return XCTFail("Expected create group proposal")
        }

        XCTAssertEqual(name, "工作")
        XCTAssertEqual(colorHex, "#3B82F6")

        try executor.apply(.createGroup(name: name, colorHex: colorHex))
        let groups = try container.mainContext.fetch(FetchDescriptor<TodoGroup>())
        XCTAssertEqual(groups.map(\.name), ["工作"])
    }
}
