import Combine
import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class AIAssistantModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)

        var isFailure: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    @Published var prompt = ""
    @Published private(set) var sessionID = UUID()
    let completedReplies = PassthroughSubject<AIAssistantReply, Never>()
    @Published private(set) var memoryClearConfirmation: AIGlobalMemoryClearRequest?
    @Published var isComposingPromptText = false
    @Published private(set) var images: [AIImageAttachment] = []
    @Published private(set) var imageInputError: String?
    private(set) var isChoosingImages = false
    @Published private(set) var response = ""
    @Published private(set) var proposals: [AIActionProposal] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var focusRequestID = UUID()
    @Published private(set) var progress: AIAssistantProgress = .idle
    @Published private(set) var activityLines: [String] = []
    @Published private(set) var conversation = AIConversationHistory()
    @Published private(set) var hasVisibleConversation = false
    @Published private(set) var hasTransientOutput = false
    @Published private(set) var todoReferenceRefreshID = UUID()

    private let modelContext: ModelContext
    private let memoryStore: AIGlobalMemoryStore
    private let summaryStore: SummaryStore
    private var summaryDrafts: [AIActionProposal] = []
    private var summaryDecisions: [UUID: String] = [:]
    private var summaryResponseNotes: [String] = []

    var hasSummaryPreview: Bool { !summaryDrafts.isEmpty }
    private var memoryClearProposalID: UUID?
    private var memoryClearRequestID: UUID?
    private let client: AIClient
    private let apiKeyStore: AIAPIKeyStore
    private let defaults: UserDefaults
    private let logStore: AppDebugLogStore
    private let maxToolRounds = 6
    private var requestTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        client: AIClient? = nil,
        apiKeyStore: AIAPIKeyStore? = nil,
        defaults: UserDefaults = .standard,
        logStore: AppDebugLogStore? = nil,
        memoryStore: AIGlobalMemoryStore? = nil,
        summaryStore: SummaryStore? = nil
    ) {
        self.modelContext = modelContext
        self.memoryStore = memoryStore ?? AIGlobalMemoryStore(defaults: defaults)
        self.summaryStore = summaryStore ?? .shared
        self.client = client ?? AIClient()
        self.apiKeyStore = apiKeyStore ?? .shared
        self.defaults = defaults
        self.logStore = logStore ?? .shared
    }

    var canSubmit: Bool {
        (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
            && state != .loading && !isComposingPromptText && memoryClearConfirmation == nil
    }

    func addImages(_ attachments: [AIImageAttachment]) {
        guard state != .loading else { return }
        guard images.count + attachments.count <= AIImageAttachment.maxCount else {
            imageInputError = AIImageAttachment.ImportError.tooMany.localizedDescription
            return
        }
        images.append(contentsOf: attachments)
        imageInputError = nil
    }

    func removeImage(id: UUID) {
        images.removeAll { $0.id == id }
        imageInputError = nil
        requestInputFocus()
    }

    func chooseImages() {
        guard state != .loading, let window = NSApp.keyWindow else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.prompt = "添加图片"
        isChoosingImages = true
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            self.isChoosingImages = false
            if result == .OK { self.importImageURLsInBackground(picker.urls) }
            window.makeKey()
            self.requestInputFocus()
        }
    }

    private func importImageURLsInBackground(_ urls: [URL]) {
        guard state != .loading, !urls.isEmpty else { return }
        guard images.count + urls.count <= AIImageAttachment.maxCount else {
            imageInputError = AIImageAttachment.ImportError.tooMany.localizedDescription
            return
        }
        let expectedSessionID = sessionID
        Task {
            do {
                let attachments = try await Task.detached(priority: .userInitiated) {
                    try urls.map { try AIImageAttachment(url: $0) }
                }.value
                guard self.sessionID == expectedSessionID, self.state != .loading else { return }
                self.addImages(attachments)
            } catch {
                guard self.sessionID == expectedSessionID else { return }
                self.imageInputError = error.localizedDescription
            }
        }
    }

    func addImageURLs(_ urls: [URL]) {
        guard state != .loading else { return }
        do {
            guard images.count + urls.count <= AIImageAttachment.maxCount else {
                throw AIImageAttachment.ImportError.tooMany
            }
            addImages(try urls.map { try AIImageAttachment(url: $0) })
        } catch {
            imageInputError = error.localizedDescription
        }
    }

    /// Return false for ordinary text so AppKit keeps its normal paste behavior.
    func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addImageURLs(urls)
            return true
        }
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else {
            return false
        }
        do { addImages([try AIImageAttachment(data: data, name: "粘贴的图片")]) }
        catch { imageInputError = error.localizedDescription }
        return true
    }

    var shouldShowPromptPlaceholder: Bool {
        PromptPlaceholderVisibility.shouldShowPlaceholder(text: prompt, isComposingText: isComposingPromptText)
    }

    func submit() {
        guard canSubmit else { return }
        cancelMemoryClearConfirmation()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = images
        let previousConversation = conversation

        prompt = ""
        images = []
        imageInputError = nil
        isComposingPromptText = false
        response = ""
        activityLines = []
        proposals = []
        summaryDrafts = []
        summaryDecisions = [:]
        summaryResponseNotes = []
        state = .loading
        progress = .thinking
        conversation.appendUser(text, imageURLs: attachments.map(\.dataURL))
        syncConversationState()
        log(.info, "AI request started", metadata: ["promptLength": "\(text.count)", "imageCount": "\(attachments.count)"])
        logChat(role: "User", content: text)

        let requestSessionID = sessionID
        requestTask = Task {
            await run(prompt: text, images: attachments, previousConversation: previousConversation, requestSessionID: requestSessionID)
        }
    }

    func apply(_ proposal: AIActionProposal, sessionID: UUID? = nil) {
        guard state != .loading, sessionID == nil || sessionID == self.sessionID,
              proposals.contains(proposal) else { return }
        if case .clearGlobalMemory = proposal {
            requestMemoryClearConfirmation(for: proposal)
            return
        }
        do {
            try applyConfirmed(proposal)
            proposals.removeAll { $0 == proposal }
            if case .saveSummary = proposal {
                recordSummaryDecision(proposal, status: "已保存。")
                state = .ready
            }
            todoReferenceRefreshID = UUID()
            syncConversationState()
        } catch {
            if case .saveSummary = proposal {
                recordSummaryDecision(proposal, status: "保存失败，尚未保存：\(error.localizedDescription)。可以重试或选择不保存。")
            }
            state = .failed(error.localizedDescription)
        }
    }

    func applyAllProposals() {
        guard state != .loading else { return }
        do {
            for proposal in proposals where !proposal.requiresMandatoryConfirmation {
                try applyConfirmed(proposal)
                proposals.removeAll { $0 == proposal }
            }
            if let clear = proposals.first(where: {
                if case .clearGlobalMemory = $0 { return true }
                return false
            }) {
                requestMemoryClearConfirmation(for: clear)
            }
            todoReferenceRefreshID = UUID()
            syncConversationState()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stageOrApply(_ proposals: [AIActionProposal], settings: AISettings) {
        self.proposals = proposals
        summaryDrafts = proposals.filter {
            if case .saveSummary = $0 { return true }
            return false
        }
        summaryDecisions = [:]
        summaryResponseNotes = []
        if !summaryDrafts.isEmpty { response = summaryPreview() }
        if !settings.requiresActionConfirmation {
            do {
                for proposal in proposals where !proposal.requiresMandatoryConfirmation {
                    try applyConfirmed(proposal)
                    self.proposals.removeAll { $0 == proposal }
                }
                todoReferenceRefreshID = UUID()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        syncConversationState()
    }

    func dismiss(_ proposal: AIActionProposal, sessionID: UUID? = nil) {
        guard state != .loading, sessionID == nil || sessionID == self.sessionID,
              proposals.contains(proposal) else { return }
        if proposal.id == memoryClearProposalID { cancelMemoryClearConfirmation() }
        proposals.removeAll { $0 == proposal }
        if case .saveSummary = proposal {
            recordSummaryDecision(proposal, status: "未保存，已放弃这份草稿。")
            state = .ready
        }
        syncConversationState()
    }

    func dismissAllProposals() {
        guard state != .loading else { return }
        for proposal in proposals { dismiss(proposal) }
        cancelMemoryClearConfirmation()
        syncConversationState()
    }

    private func summaryPreview() -> String {
        var sections = summaryDrafts.compactMap { proposal -> String? in
            guard case let .saveSummary(id, title, start, end, content) = proposal else { return nil }
            let status = summaryDecisions[id] ?? "尚未保存。是否保存这份总结？请点击这份总结的“保存总结”或“不保存”。"
            return "\(title)\n时间范围：\(SavedSummary.periodDescription(start: start, end: end))\n\n\(content)\n\n\(status)"
        }
        sections.append(contentsOf: summaryResponseNotes)
        if proposals.contains(where: {
            if case .clearGlobalMemory = $0 { return true }
            return false
        }) {
            sections.append("清空全部全局记忆需要二次确认，目前尚未清空。请点击待确认操作继续。")
        }
        return sections.joined(separator: "\n\n")
    }

    private func recordSummaryDecision(_ proposal: AIActionProposal, status: String) {
        guard case let .saveSummary(id, _, _, _, _) = proposal else { return }
        summaryDecisions[id] = status
        response = summaryPreview()
        conversation.replaceLastAssistantContent(with: response)
        syncConversationState()
    }

    var isConversationEmpty: Bool {
        conversation.messages.isEmpty && prompt.isEmpty && images.isEmpty
            && response.isEmpty && proposals.isEmpty && state == .idle
            && imageInputError == nil
    }

    func startNewConversation() {
        cancelMemoryClearConfirmation()
        requestTask?.cancel()
        requestTask = nil
        sessionID = UUID()
        prompt = ""
        images = []
        imageInputError = nil
        isComposingPromptText = false
        response = ""
        activityLines = []
        proposals = []
        summaryDrafts = []
        summaryDecisions = [:]
        summaryResponseNotes = []
        state = .idle
        progress = .idle
        conversation.reset()
        syncConversationState()
        requestInputFocus()
    }

    func requestInputFocus() {
        focusRequestID = UUID()
    }

    private func requestMemoryClearConfirmation(for proposal: AIActionProposal) {
        guard proposals.contains(proposal), case let .clearGlobalMemory(id, revision) = proposal else { return }
        do {
            memoryClearConfirmation = try memoryStore.requestClear(expectedRevision: revision)
            memoryClearProposalID = id
            memoryClearRequestID = memoryClearConfirmation?.id
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func hideMemoryClearConfirmation() {
        // SwiftUI may dismiss the alert before invoking its chosen button.
        memoryClearConfirmation = nil
    }

    func cancelMemoryClearConfirmation() {
        memoryClearConfirmation = nil
        memoryClearProposalID = nil
        memoryClearRequestID = nil
    }

    func confirmMemoryClear(_ request: AIGlobalMemoryClearRequest) {
        guard state != .loading, request.id == memoryClearRequestID, let id = memoryClearProposalID,
              proposals.contains(where: {
                  if case let .clearGlobalMemory(proposalID, revision) = $0 { return proposalID == id && revision == request.revision }
                  return false
              }) else { return }
        defer { cancelMemoryClearConfirmation() }
        do {
            try memoryStore.confirmClear(request)
            proposals.removeAll {
                if case .clearGlobalMemory = $0 { return true }
                return false
            }
            let message = "已清空全部全局记忆。"
            summaryResponseNotes.append(message)
            response = summaryDrafts.isEmpty ? message : summaryPreview()
            if summaryDrafts.isEmpty { conversation.appendAssistant(message) }
            else { conversation.replaceLastAssistantContent(with: response) }
            state = .ready
            syncConversationState()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func run(prompt: String, images: [AIImageAttachment], previousConversation: AIConversationHistory, requestSessionID: UUID) async {
        var hasAppliedActions = false
        var activeAttemptActivityStart: Int?
        do {
            try Task.checkCancellation()
            let settings = AISettings(defaults: defaults)
            let memoryEpoch = try memoryStore.read().epoch
            let apiKey = apiKeyStore.readAPIKey()
            let executor = AIToolExecutor(modelContext: modelContext, memoryStore: memoryStore, summaryStore: summaryStore)
            var messages = AIAssistantRequestBuilder.makeMessages(
                systemPrompt: AISystemPrompt.text(requiresActionConfirmation: settings.requiresActionConfirmation),
                inlineContext: makeInlineContext(),
                conversation: conversation
            )

            var readMemoryRevision: UUID?
            var handledToolNames: [String] = []
            var handledProposalCount = 0
            var appliedProposalCount = 0
            var visibleResponse = ""
            var completed = false
            var toolErrors: [String] = []

            for _ in 0..<maxToolRounds {
                let memory = try memoryStore.read()
                guard memory.epoch == memoryEpoch else { throw AIGlobalMemoryError.clearedDuringRequest }
                if let revision = readMemoryRevision, revision != memory.revision {
                    expireMemoryReadResults(in: &messages)
                    readMemoryRevision = nil
                }
                let previousResponse = response
                let previousActivityCount = activityLines.count
                activeAttemptActivityStart = previousActivityCount
                let previousProgress = progress
                var streamedText = ""
                var streamedReasoning = ""
                var reasoningLineIndex: Int?
                var memoryInvalidated = false
                let result = try await client.sendStreaming(messages: messages, settings: settings, apiKey: apiKey) { [weak self] event in
                    guard let self, !Task.isCancelled, self.sessionID == requestSessionID else { return }
                    guard !memoryInvalidated else { return }
                    guard let currentMemory = try? self.memoryStore.read(), currentMemory.epoch == memoryEpoch else {
                        memoryInvalidated = true
                        self.response = ""
                        self.activityLines.removeSubrange(previousActivityCount...)
                        self.syncConversationState()
                        return
                    }
                    switch event {
                    case let .text(delta):
                        streamedText += delta
                        self.response = AIVisibleResponse.sanitized(streamedText)
                    case let .reasoning(delta):
                        streamedReasoning += delta
                        let summary = "思考摘要 · \(streamedReasoning)"
                        if let reasoningLineIndex {
                            self.activityLines[reasoningLineIndex] = summary
                        } else {
                            reasoningLineIndex = self.activityLines.count
                            self.activityLines.append(summary)
                        }
                    case let .toolCall(name):
                        self.activityLines.append("准备调用 \(name) · 等待完整参数")
                    case .reset:
                        streamedText = ""
                        streamedReasoning = ""
                        reasoningLineIndex = nil
                        self.response = previousResponse
                        self.activityLines.removeSubrange(previousActivityCount...)
                        self.progress = previousProgress
                    }
                    self.syncConversationState()
                }
                try Task.checkCancellation()
                guard sessionID == requestSessionID else { return }
                guard try memoryStore.read().epoch == memoryEpoch else { throw AIGlobalMemoryError.clearedDuringRequest }
                activeAttemptActivityStart = nil
                // Replace this attempt's previews with its authoritative result, keeping completed rounds.
                activityLines.removeSubrange(previousActivityCount...)
                response = previousResponse
                if let reasoning = result.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                    activityLines.append("思考摘要 · \(reasoning)")
                }
                let sanitized = AIVisibleResponse.sanitized(result.content)

                guard !result.toolCalls.isEmpty else {
                    if sanitized.isEmpty, !toolErrors.isEmpty {
                        throw AIAssistantRunError.toolCorrectionFailed(toolErrors.joined(separator: "；"))
                    }
                    completed = true
                    visibleResponse = sanitized.isEmpty
                        ? (handledToolNames.isEmpty && (result.reasoningContent != nil || result.responseItems != nil)
                            ? "模型仅返回了思考内容，未返回答复。请继续提问或调整思考设置。"
                            : AIVisibleResponse.fallbackText(toolNames: handledToolNames, proposalCount: proposals.count, appliedCount: appliedProposalCount))
                        : sanitized
                    break
                }

                response = sanitized.isEmpty ? previousResponse : sanitized
                syncConversationState()
                messages.append(AIChatMessage(
                    role: "assistant",
                    content: result.content,
                    reasoningContent: result.reasoningContent,
                    toolCalls: result.toolCalls,
                    responseItems: result.responseItems,
                    responseProviderID: result.responseProviderID
                ))

                // Keep lookup activity visible through the following network request,
                // even if this response contains other, instantaneous tool operations.
                progress = AIAssistantProgress.progress(forToolNames: result.toolCalls.map { $0.function.name })
                toolErrors = []
                for call in result.toolCalls {
                    log(.debug, "AI tool requested", metadata: ["tool": call.function.name])
                    activityLines.append("调用 \(call.function.name) · \(AIAssistantProgress.progress(forToolName: call.function.name).displayText)")
                    do {
                        if call.function.name == "read_global_memory" || call.function.name == "save_global_memory" {
                            expireMemoryReadResults(in: &messages)
                            readMemoryRevision = nil
                        }
                        let toolResult = try executor.handle(call)
                        if call.function.name == "read_global_memory" { readMemoryRevision = try memoryStore.read().revision }
                        let toolMessage: String
                        switch toolResult {
                        case let .context(content):
                            toolMessage = content
                            activityLines.append("\(call.function.name) · 查阅完成")
                        case let .memoryUpdated(content):
                            hasAppliedActions = true
                            toolMessage = content
                            activityLines.append("\(call.function.name) · 记忆已保存")
                        case let .proposal(proposal):
                            if settings.requiresActionConfirmation || proposal.requiresMandatoryConfirmation {
                                proposals.append(proposal)
                                if case .saveSummary = proposal { summaryDrafts.append(proposal) }
                                toolMessage = "已创建待确认操作：\(proposal.summary)"
                            } else {
                                toolMessage = try executor.apply(proposal).toolMessage
                                appliedProposalCount += 1
                                hasAppliedActions = true
                            }
                            handledProposalCount += 1
                            activityLines.append("\(call.function.name) · \(toolMessage)")
                        }
                        handledToolNames.append(call.function.name)
                        messages.append(AIChatMessage(role: "tool", content: toolMessage, toolCallID: call.id))
                    } catch {
                        let recoverable: Bool
                        if error is AIToolExecutorError {
                            recoverable = true
                        } else if let memoryError = error as? AIGlobalMemoryError {
                            switch memoryError {
                            case .invalidEntry, .capacityExceeded, .explicitEntryProtected: recoverable = true
                            default: recoverable = false
                            }
                        } else { recoverable = false }
                        guard recoverable else { throw error }
                        let detail = "\(call.function.name)：\(error.localizedDescription)"
                        toolErrors.append(detail)
                        let feedback = "工具调用失败，未执行此调用。\(detail) 请根据工具定义修正参数后重新调用；不要重复本轮已经成功或已待确认的操作。"
                        messages.append(AIChatMessage(role: "tool", content: feedback, toolCallID: call.id))
                        activityLines.append("参数纠错 · \(detail)")
                        progress = .correctingToolArguments
                        log(.error, "AI tool correction requested", metadata: ["tool": call.function.name, "error": error.localizedDescription])
                    }
                }

                if !summaryDrafts.isEmpty {
                    if appliedProposalCount > 0 { summaryResponseNotes.append("已执行 \(appliedProposalCount) 项其他操作。") }
                    let otherCount = proposals.filter { proposal in
                        if case .saveSummary = proposal { return false }
                        if case .clearGlobalMemory = proposal { return false }
                        return true
                    }.count
                    if otherCount > 0 { summaryResponseNotes.append("另有 \(otherCount) 项操作待确认。") }
                    summaryResponseNotes.append(contentsOf: toolErrors.map { "工具调用失败，未执行：\($0)" })
                    visibleResponse = summaryPreview()
                    completed = true
                    if hasAppliedActions { todoReferenceRefreshID = UUID() }
                    break
                }
                if !toolErrors.isEmpty {
                    activityLines.append("已反馈工具错误，等待 AI 修正（最多 \(maxToolRounds) 轮）…")
                }
                if hasAppliedActions { todoReferenceRefreshID = UUID() }

            }
            guard completed else {
                throw AIAssistantRunError.toolCorrectionFailed(toolErrors.isEmpty
                    ? "已达到 \(maxToolRounds) 轮工具调用上限。"
                    : toolErrors.joined(separator: "；"))
            }

            if visibleResponse.isEmpty {
                visibleResponse = AIVisibleResponse.fallbackText(toolNames: handledToolNames, proposalCount: proposals.count, appliedCount: appliedProposalCount)
            }
            if summaryDrafts.isEmpty, proposals.contains(where: {
                if case .clearGlobalMemory = $0 { return true }
                return false
            }) {
                visibleResponse = "清空全部全局记忆需要二次确认，目前尚未清空。请点击待确认操作继续。"
            }

            response = visibleResponse
            conversation.appendAssistant(visibleResponse)
            logChat(role: "Assistant", content: visibleResponse)
            state = .ready
            progress = .idle
            syncConversationState()
            log(.info, "AI request completed", metadata: ["toolCalls": "\(handledToolNames.count)", "proposals": "\(handledProposalCount)"])
            publishCompletedReply()
        } catch {
            guard !Task.isCancelled, sessionID == requestSessionID else { return }
            if let memoryError = error as? AIGlobalMemoryError, case .clearedDuringRequest = memoryError {
                response = ""
                if let activeAttemptActivityStart {
                    activityLines.removeSubrange(activeAttemptActivityStart...)
                }
            }
            if !summaryDrafts.isEmpty {
                summaryResponseNotes.append("部分工具处理失败：\(error.localizedDescription)。其他待确认操作仍然保留。")
                if hasAppliedActions { summaryResponseNotes.append("部分其他操作已执行，请检查结果，避免重复提交。") }
                response = summaryPreview()
                conversation.appendAssistant(response)
            } else if hasAppliedActions {
                response = "部分操作已执行，但后续 AI 请求失败。请先检查事项或记忆中的结果，避免重复提交。"
                conversation.appendAssistant(response)
            } else if !proposals.isEmpty {
                response = "操作已准备好，但后续 AI 请求失败。你仍可以确认或忽略这些操作。"
                conversation.appendAssistant(response)
            } else {
                self.prompt = prompt
                self.images = images
                conversation = previousConversation
                if !response.isEmpty {
                    response = "回复未完成，以下仅为中断前的部分内容：\n" + response
                }
            }
            state = .failed(error.localizedDescription)
            progress = .idle
            activityLines.append("请求停止 · \(error.localizedDescription)")
            syncConversationState()
            log(.error, "AI request failed", metadata: ["error": error.localizedDescription])
            publishCompletedReply()
        }
    }

    private func expireMemoryReadResults(in messages: inout [AIChatMessage]) {
        let readIDs = Set(messages.flatMap { $0.toolCalls ?? [] }
            .filter { $0.function.name == "read_global_memory" }.map(\.id))
        for index in messages.indices where messages[index].role == "tool" {
            if let id = messages[index].toolCallID, readIDs.contains(id) {
                messages[index].content = "此查阅结果已过期或被更新的查阅替代；需要时请再次调用 read_global_memory。"
            }
        }
    }

    private func publishCompletedReply() {
        let message: String
        if case let .failed(error) = state {
            message = response.isEmpty ? error : response + "\n" + error
        } else {
            message = response
        }
        completedReplies.send(AIAssistantReply(sessionID: sessionID, message: message,
                                                pendingActionCount: proposals.count, isFailure: state.isFailure))
    }

    func completeReferencedTodo(id: UUID) {
        do {
            try AIToolExecutor(modelContext: modelContext).apply(.completeTodo(id: id))
            todoReferenceRefreshID = UUID()
        } catch {
            state = .failed(error.localizedDescription)
            syncConversationState()
        }
    }

    func referencedTodo(id: UUID) -> AIReferencedTodo {
        AITodoLookup.referencedTodo(id: id, in: modelContext)
    }

    private func syncConversationState() {
        hasVisibleConversation = conversation.hasVisibleContent
        hasTransientOutput = !response.isEmpty || !proposals.isEmpty || state.isFailure
    }

    private func makeInlineContext() -> AITodoInlineContext {
        do {
            let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
            let groups = try modelContext.fetch(FetchDescriptor<TodoGroup>())
            return AITodoContext.snapshot(items: items, groups: groups, summaries: summaryStore.summaries).inlineContext()
        } catch {
            log(.error, "AI inline context failed", metadata: ["error": error.localizedDescription])
            return AITodoInlineContext(content: "当前任务上下文读取失败，必要时请调用工具重新读取。")
        }
    }

    private func applyConfirmed(_ proposal: AIActionProposal) throws {
        _ = try AIToolExecutor(modelContext: modelContext, memoryStore: memoryStore, summaryStore: summaryStore).apply(proposal)
    }

    private func log(_ level: AppDebugLogStore.Level, _ message: String, metadata: [String: String] = [:]) {
        try? logStore.write(level, category: "AI", message: message, metadata: metadata)
    }

    private func logChat(role: String, content: String) {
        try? logStore.write(.info, category: "AIChat", message: role, metadata: ["content": content])
        guard role == "Assistant" else { return }
        let parts = AITodoReferenceParser.parse(content)
        let todoReferenceCount = parts.filter { part in
            if case .todo = part {
                return true
            }
            return false
        }.count
        let textPartCount = parts.filter { part in
            if case let .text(text) = part {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }.count
        try? logStore.write(
            .debug,
            category: "AIChat",
            message: "Assistant render parts",
            metadata: ["textParts": "\(textPartCount)", "todoReferences": "\(todoReferenceCount)"]
        )
    }
}

private enum AIAssistantRunError: LocalizedError {
    case toolCorrectionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .toolCorrectionFailed(detail):
            return "AI 未能在工具调用上限内完成处理：\(detail)"
        }
    }
}

struct AIReferencedTodo: Equatable, Identifiable {
    let id: UUID
    let title: String
    let priority: TodoPriority
    let groupName: String?
    let scheduleText: String?
    let createdAt: Date?
    let isCompleted: Bool
    let exists: Bool
    var readFailed: Bool = false

    var ageText: String {
        guard let createdAt else { return "" }
        return TodoAgeFormatter.elapsedText(since: createdAt)
    }
}

enum AIAssistantRequestBuilder {
    static func makeMessages(
        systemPrompt: String,
        inlineContext: AITodoInlineContext,
        conversation: AIConversationHistory
    ) -> [AIChatMessage] {
        [
            AIChatMessage(role: "system", content: systemPrompt),
            AIChatMessage(role: "system", content: inlineContext.content)
        ] + conversation.messages
    }
}
