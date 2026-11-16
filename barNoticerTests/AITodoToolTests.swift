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

        let snapshot = AITodoContext.snapshot(items: items, groups: [work], summaries: [], now: now)

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


    func testCompleteTodoProposalExposesTodoReferenceForRendering() {
        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let complete = AIActionProposal.completeTodo(id: id)
        let delete = AIActionProposal.deleteTodo(id: id)

        XCTAssertEqual(complete.referencedTodoID, id)
        XCTAssertEqual(delete.referencedTodoID, id)
    }

    @MainActor
    func testDeleteTodoToolCreatesPendingProposalAndAppliesDeletion() throws {
        let container = try TestSupport.makeInMemoryContainer()
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
        let container = try TestSupport.makeInMemoryContainer()
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
        let container = try TestSupport.makeInMemoryContainer()
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
        let container = try TestSupport.makeInMemoryContainer()
        let model = AIAssistantModel(modelContext: container.mainContext)
        let proposal = AIActionProposal.createTodo(title: "Write paper", priority: .high)

        model.stageOrApply([proposal], settings: AISettings(requiresActionConfirmation: true))

        let items = try container.mainContext.fetch(FetchDescriptor<TodoItem>())
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(model.proposals, [proposal])
    }

    @MainActor
    func testAssistantCanApplyAndDismissProposalBatches() throws {
        let container = try TestSupport.makeInMemoryContainer()
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


    @MainActor
    func testMalformedOptionalFieldsAreRejectedRatherThanSilentlyDiscarded() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let invalidFields: [(String, String)] = [
            (#""deadline_at":"tomorrow""#, "deadline_at"),
            (#""group_id":"work""#, "group_id"),
            (#""scheduled_times":["2026-05-24T09:00:00Z","invalid"]"#, "scheduled_times"),
            (#""recurrence_rule":"yearly""#, "recurrence_rule"),
            (#""recurrence_rule":"every_n_days","recurrence_interval_days":1.5"#, "recurrence_interval_days"),
            (#""recurrence_rule":"every_n_days""#, "recurrence_interval_days"),
            (#""reminder_minutes_before":true"#, "reminder_minutes_before"),
            (#""deadline":"2026-05-24T09:00:00Z""#, "deadline")
        ]
        for (field, expectedField) in invalidFields {
            let call = AIToolCall(id: "invalid", type: "function", function: .init(name: "create_todo",
                arguments: #"{"title":"保留原意","priority":"high",\#(field)}"#))
            XCTAssertThrowsError(try executor.handle(call)) { error in
                XCTAssertTrue(error.localizedDescription.contains(expectedField), error.localizedDescription)
            }
        }
    }

    @MainActor
    func testCreateTodoToolAcceptsGroupAndDeadline() throws {
        let container = try TestSupport.makeInMemoryContainer()
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

        guard case let .proposal(.createTodo(_, title, _, priority, groupID, deadlineAt, _, _, _, _)) = result else {
            return XCTFail("Expected create todo proposal")
        }
        XCTAssertEqual(title, "写周报")
        XCTAssertEqual(priority, .high)
        XCTAssertEqual(groupID, group.id)
        XCTAssertEqual(deadlineAt, deadline)
    }

    @MainActor
    func testCreateTodoToolAcceptsMultipleTimesAndRecurrence() throws {
        let container = try TestSupport.makeInMemoryContainer()
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

        guard case let .proposal(.createTodo(_, title, _, priority, _, deadlineAt, scheduledTimes, recurrenceRule, recurrenceAnchor, _)) = result else {
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
    func testCreateTodoToolAcceptsCustomDailyRecurrence() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let call = AIToolCall(
            id: "create-custom-recurrence-call",
            type: "function",
            function: .init(
                name: "create_todo",
                arguments: #"{"title":"隔三天训练","priority":"medium","recurrence_rule":"every_n_days","recurrence_interval_days":3,"recurrence_anchor":"2026-05-24T09:00:00Z"}"#
            )
        )

        let result = try executor.handle(call)

        guard case let .proposal(.createTodo(_, _, _, _, _, _, _, recurrenceRule, recurrenceAnchor, _)) = result else {
            return XCTFail("Expected scheduled create todo proposal")
        }
        XCTAssertEqual(recurrenceRule, .everyNDays(3))
        XCTAssertEqual(recurrenceAnchor, ISO8601DateFormatter().date(from: "2026-05-24T09:00:00Z"))
    }

    @MainActor
    func testRecurringTodoCompletionProposalRollsForwardInsteadOfCompleting() throws {
        let container = try TestSupport.makeInMemoryContainer()
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
        let container = try TestSupport.makeInMemoryContainer()
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

    @MainActor
    func testPrepareSummaryOnlyProposesAndApplyPersistsTheProposalID() throws {
        let directory = summaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let container = try TestSupport.makeInMemoryContainer()
        let executor = AIToolExecutor(modelContext: container.mainContext, summaryStore: store)
        let call = AIToolCall(id: "summary", type: "function", function: .init(
            name: "prepare_summary",
            arguments: #"{"title":"本周回顾","period_start":"2026-05-18T00:00:00Z","period_end":"2026-05-25T00:00:00Z","content":"完成设计。\n下周继续实现。"}"#
        ))

        guard case let .proposal(proposal) = try executor.handle(call),
              case let .saveSummary(id, title, start, end, content) = proposal else {
            return XCTFail("Expected a summary proposal")
        }
        XCTAssertTrue(proposal.requiresMandatoryConfirmation)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let result = try executor.apply(proposal)
        let saved = try XCTUnwrap(store.summaries.first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.title, "本周回顾")
        XCTAssertEqual(saved.periodStart, ISO8601DateFormatter().date(from: "2026-05-18T00:00:00Z"))
        XCTAssertEqual(saved.periodEnd, ISO8601DateFormatter().date(from: "2026-05-25T00:00:00Z"))
        XCTAssertEqual(saved.content, "完成设计。\n下周继续实现。")
        XCTAssertEqual(result, .savedSummary(id: id, title: title))
        XCTAssertTrue(result.toolMessage.contains(title))
        XCTAssertEqual(SummaryStore(directoryURL: directory).summaries, [saved])

        XCTAssertEqual(try executor.apply(proposal), result)
        XCTAssertEqual(store.summaries, [saved])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertThrowsError(try executor.apply(.saveSummary(
            id: id, title: title, periodStart: start, periodEnd: end, content: content + "修改"
        )))
        XCTAssertEqual(SummaryStore(directoryURL: directory).summaries, [saved])

        let statsCall = AIToolCall(id: "stats", type: "function", function: .init(name: "get_completion_stats", arguments: "{}"))
        guard case let .context(stats) = try executor.handle(statsCall),
              let payload = try JSONSerialization.jsonObject(with: Data(stats.utf8)) as? [String: Any],
              let summaries = payload["summaries"] as? [[String: Any]] else {
            return XCTFail("Expected saved summaries in completion stats")
        }
        XCTAssertEqual(summaries.first?["title"] as? String, title)
        XCTAssertEqual(summaries.first?["content"] as? String, content)
        XCTAssertEqual(summaries.first?["periodStart"] as? String, "2026-05-18T00:00:00Z")
        XCTAssertEqual(summaries.first?["periodEnd"] as? String, "2026-05-25T00:00:00Z")
        XCTAssertNotNil(summaries.first?["createdAt"] as? String)
    }

    @MainActor
    func testSummaryMetadataErrorsAreRecoverableToolErrors() throws {
        let directory = summaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let container = try TestSupport.makeInMemoryContainer()
        let executor = AIToolExecutor(modelContext: container.mainContext, summaryStore: store)
        let valid: [String: Any] = [
            "title": "回顾", "content": "正文",
            "period_start": "2026-05-18T00:00:00Z", "period_end": "2026-05-25T00:00:00Z"
        ]
        var cases: [[String: Any]] = []
        for field in ["title", "content", "period_start", "period_end"] {
            var missing = valid
            missing.removeValue(forKey: field)
            cases.append(missing)
            var blank = valid
            blank[field] = " \n"
            cases.append(blank)
        }
        for end in ["2026-05-18T00:00:00Z", "2026-05-17T00:00:00Z", "tomorrow"] {
            var invalid = valid
            invalid["period_end"] = end
            cases.append(invalid)
        }
        var confirmed = valid
        confirmed["confirmed"] = true
        cases.append(confirmed)
        for arguments in cases {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            let call = AIToolCall(id: "invalid-summary", type: "function", function: .init(name: "prepare_summary", arguments: json))
            XCTAssertThrowsError(try executor.handle(call)) { error in
                XCTAssertTrue(error is AIToolExecutorError)
            }
        }
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testApplyingSummaryPropagatesDiskFailureWithoutReportingSuccess() throws {
        let directory = summaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocker)
        let store = SummaryStore(directoryURL: blocker)
        let container = try TestSupport.makeInMemoryContainer()
        let executor = AIToolExecutor(modelContext: container.mainContext, summaryStore: store)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertThrowsError(try executor.apply(.saveSummary(
            title: "回顾", periodStart: start, periodEnd: start.addingTimeInterval(60), content: "正文"
        )))
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "blocked")
    }

    @MainActor
    func testInlineContextIncludesOnlyRecentSummaryTitlesRangesAndBodies() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let summaries = (0..<4).map { index in
            SavedSummary(title: "总结\(index)", periodStart: start, periodEnd: start.addingTimeInterval(60),
                         content: "正文\(index)", createdAt: start.addingTimeInterval(Double(index)))
        }
        let context = AITodoContext.snapshot(items: [], summaries: summaries).inlineContext(now: start).content

        XCTAssertFalse(context.contains("总结0"))
        for index in 1..<4 {
            XCTAssertTrue(context.contains("title=总结\(index)"))
            XCTAssertTrue(context.contains("正文\(index)"))
        }
        XCTAssertTrue(context.contains("periodStart=2023-11-14T22:13:20Z"))
        XCTAssertTrue(context.contains("periodEnd=2023-11-14T22:14:20Z"))
        XCTAssertTrue(context.contains("createdAt=2023-11-14T22:13:23Z"))
    }

    @MainActor
    func testUpdateToolCanEditCompletedTaskAndRestoreItsStateAfterConfirmation() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TodoItem(title: "旧任务", note: "保留要求", priority: .high, deadlineAt: deadline,
            isCompleted: true, createdAt: deadline.addingTimeInterval(-86_400), reminderMinutesBefore: 30)
        let untouched = TodoItem(title: "其他任务", isCompleted: true)
        container.mainContext.insert(item)
        container.mainContext.insert(untouched)
        try container.mainContext.save()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let model = AIAssistantModel(modelContext: container.mainContext)
        let proposal = try updateProposal(id: item.id, fields: ["title": "继续旧任务", "is_completed": false], executor: executor)
        model.stageOrApply([proposal], settings: AISettings(requiresActionConfirmation: true))
        XCTAssertTrue(item.isCompleted)
        XCTAssertEqual(item.title, "旧任务")
        model.apply(proposal)

        let context = ModelContext(container)
        let saved = try XCTUnwrap(AITodoLookup.todo(id: item.id, in: context))
        XCTAssertFalse(saved.isCompleted)
        XCTAssertEqual(saved.title, "继续旧任务")
        XCTAssertEqual(saved.note, "保留要求")
        XCTAssertEqual(saved.priority, .high)
        XCTAssertEqual(saved.deadlineAt, deadline)
        XCTAssertEqual(saved.reminderMinutesBefore, 30)
        XCTAssertEqual(saved.createdAt, deadline.addingTimeInterval(-86_400))
        XCTAssertTrue(try XCTUnwrap(AITodoLookup.todo(id: untouched.id, in: context)).isCompleted)

        let finish = try updateProposal(id: item.id, fields: ["is_completed": true], executor: executor)
        model.stageOrApply([finish], settings: AISettings(requiresActionConfirmation: false))
        XCTAssertTrue(item.isCompleted)
        XCTAssertEqual(item.title, "继续旧任务")
        XCTAssertTrue(model.proposals.isEmpty)
    }

    @MainActor
    func testUpdateToolPreservesUnspecifiedRecurrenceFieldsAndCanEndWholeRecurringTask() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let anchor = ISO8601DateFormatter().date(from: "2033-05-18T09:00:00Z")!
        let item = TodoItem(title: "周期任务", recurrenceRule: .everyNDays(3), recurrenceAnchor: anchor,
            lastCompletedOccurrenceAt: anchor, reminderMinutesBefore: 60, automaticallyCompletes: true)
        container.mainContext.insert(item)
        try container.mainContext.save()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        try executor.apply(updateProposal(id: item.id, fields: ["is_completed": true], executor: executor))
        XCTAssertTrue(item.isCompleted)
        XCTAssertEqual(item.lastCompletedOccurrenceAt, anchor, "Ending the whole task must not complete another occurrence")
        XCTAssertTrue(item.automaticallyCompletes)
        XCTAssertNil(TodoScheduledReminder(item: item))
        try executor.apply(updateProposal(id: item.id, fields: ["is_completed": false, "automatically_completes": false], executor: executor))
        XCTAssertFalse(item.isCompleted)
        XCTAssertFalse(item.automaticallyCompletes)
        XCTAssertEqual(item.lastCompletedOccurrenceAt, anchor)
        try executor.apply(updateProposal(id: item.id, fields: ["recurrence_interval_days": 7], executor: executor))
        XCTAssertEqual(item.recurrenceRule, .everyNDays(7))
        XCTAssertEqual(item.recurrenceAnchor, anchor)
        let nextAnchor = "2033-05-19T09:00:00Z"
        try executor.apply(updateProposal(id: item.id, fields: ["recurrence_anchor": nextAnchor], executor: executor))
        XCTAssertEqual(item.recurrenceRule, .everyNDays(7))
        XCTAssertEqual(item.recurrenceAnchor, ISO8601DateFormatter().date(from: nextAnchor))
        try executor.apply(updateProposal(id: item.id, fields: ["recurrence_rule": "weekly"], executor: executor))
        XCTAssertEqual(item.recurrenceRule, .weekly)
        XCTAssertEqual(item.recurrenceAnchor, ISO8601DateFormatter().date(from: nextAnchor))
        XCTAssertEqual(item.reminderMinutesBefore, 60)
        try executor.apply(updateProposal(id: item.id, fields: ["scheduled_times": []], executor: executor))
        XCTAssertEqual(item.scheduleKind, .none)
        XCTAssertNil(item.reminderMinutesBefore)
        XCTAssertNil(item.lastCompletedOccurrenceAt)
    }

    @MainActor
    func testUpdateToolPersistsExplicitHistoryAndClearsOnlyRequestedOptionalFields() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let anchor = ISO8601DateFormatter().date(from: "2033-05-18T09:00:00Z")!
        let item = TodoItem(title: "周期", note: "旧备注", groupID: UUID(), recurrenceRule: .daily,
            recurrenceAnchor: anchor, reminderMinutesBefore: 30)
        container.mainContext.insert(item)
        try container.mainContext.save()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        try executor.apply(updateProposal(id: item.id, fields: [
            "created_at": "2025-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
            "last_completed_occurrence_at": "2033-05-18T09:00:00Z", "clear_group": true, "clear_note": true
        ], executor: executor))
        let context = ModelContext(container)
        let saved = try XCTUnwrap(AITodoLookup.todo(id: item.id, in: context))
        XCTAssertEqual(saved.createdAt, ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z"))
        XCTAssertEqual(saved.updatedAt, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        XCTAssertEqual(saved.lastCompletedOccurrenceAt, anchor)
        XCTAssertNil(saved.note)
        XCTAssertNil(saved.groupID)
        XCTAssertEqual(saved.reminderMinutesBefore, 30)
        XCTAssertEqual(saved.pendingOccurrence(), anchor.addingTimeInterval(86_400))
        try executor.apply(updateProposal(id: item.id, fields: ["clear_last_completed_occurrence": true], executor: executor))
        XCTAssertNil(item.lastCompletedOccurrenceAt)
        XCTAssertEqual(item.pendingOccurrence(), anchor)
    }

    @MainActor
    func testInvalidUpdateFieldsDoNotPartiallyChangeTask() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TodoItem(title: "原任务", note: "备注", updatedAt: timestamp)
        container.mainContext.insert(item)
        try container.mainContext.save()
        let executor = AIToolExecutor(modelContext: container.mainContext)
        let invalidFields: [[String: Any]] = [
            ["is_completed": "false"], ["is_completed": 1], ["created_at": "yesterday"],
            ["updated_at": 42], ["last_completed_occurrence_at": "2033-05-18T09:00:00Z"],
            ["automatically_completes": true], ["recurrence_anchor": "2033-05-18T09:00:00Z"],
            ["recurrence_interval_days": 3], ["note": "新备注", "clear_note": true],
            ["group_id": UUID().uuidString, "clear_group": true],
            ["deadline_at": "2033-05-18T09:00:00Z", "clear_schedule": true],
            ["deadline_at": "2033-05-18T09:00:00Z", "scheduled_times": ["2033-05-19T09:00:00Z"]]
        ]
        for var fields in invalidFields {
            fields["title"] = "不能部分写入"
            XCTAssertThrowsError(try executor.apply(updateProposal(id: item.id, fields: fields, executor: executor)))
            XCTAssertEqual(item.title, "原任务")
            XCTAssertEqual(item.note, "备注")
            XCTAssertFalse(item.isCompleted)
            XCTAssertEqual(item.updatedAt, timestamp)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    @MainActor
    private func updateProposal(id: UUID, fields: [String: Any], executor: AIToolExecutor) throws -> AIActionProposal {
        var arguments = fields
        arguments["id"] = id.uuidString
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let call = AIToolCall(id: "update", type: "function", function: .init(name: "update_todo", arguments: json))
        guard case let .proposal(proposal) = try executor.handle(call) else { throw AIToolExecutorError.invalidArguments }
        return proposal
    }

    private func summaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AITodoToolTests/\(UUID().uuidString)", isDirectory: true)
    }
}
