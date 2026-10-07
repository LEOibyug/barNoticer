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
    @Published private(set) var conversation = AIConversationHistory()
    @Published private(set) var hasVisibleConversation = false
    @Published private(set) var hasTransientOutput = false
    @Published private(set) var todoReferenceRefreshID = UUID()

    private let modelContext: ModelContext
    private let memoryStore: AIGlobalMemoryStore
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
        memoryStore: AIGlobalMemoryStore? = nil
    ) {
        self.modelContext = modelContext
        self.memoryStore = memoryStore ?? AIGlobalMemoryStore(defaults: defaults)
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
            if result == .OK { self.addImageURLs(picker.urls) }
            window.makeKey()
            self.requestInputFocus()
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
        proposals = []
        state = .loading
        progress = .thinking
        conversation.appendUser(text, imageURLs: attachments.map(\.dataURL))
        syncConversationState()
        log(.info, "AI request started", metadata: ["promptLength": "\(text.count)", "imageCount": "\(attachments.count)"])
        logChat(role: "User", content: text)

        requestTask = Task {
            await run(prompt: text, images: attachments, previousConversation: previousConversation)
        }
    }

    func apply(_ proposal: AIActionProposal) {
        guard state != .loading else { return }
        if proposal.requiresMandatoryConfirmation {
            requestMemoryClearConfirmation(for: proposal)
            return
        }
        do {
            try applyConfirmed(proposal)
            proposals.removeAll { $0.id == proposal.id && $0.summary == proposal.summary }
            todoReferenceRefreshID = UUID()
        } catch {
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
            if let clear = proposals.first(where: \.requiresMandatoryConfirmation) {
                requestMemoryClearConfirmation(for: clear)
            }
            todoReferenceRefreshID = UUID()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stageOrApply(_ proposals: [AIActionProposal], settings: AISettings) {
        if settings.requiresActionConfirmation {
            self.proposals = proposals
            return
        }

        do {
            self.proposals = proposals.filter(\.requiresMandatoryConfirmation)
            for proposal in proposals where !proposal.requiresMandatoryConfirmation {
                _ = try applyConfirmed(proposal)
            }
            todoReferenceRefreshID = UUID()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismiss(_ proposal: AIActionProposal) {
        if proposal.id == memoryClearProposalID { cancelMemoryClearConfirmation() }
        proposals.removeAll { $0.id == proposal.id && $0.summary == proposal.summary }
    }

    func dismissAllProposals() {
        cancelMemoryClearConfirmation()
        proposals = []
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
        proposals = []
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
            proposals.removeAll(where: \.requiresMandatoryConfirmation)
            response = "已清空全部全局记忆。"
            conversation.appendAssistant(response)
            state = .ready
            syncConversationState()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func run(prompt: String, images: [AIImageAttachment], previousConversation: AIConversationHistory) async {
        var hasAppliedActions = false
        do {
            try Task.checkCancellation()
            let settings = AISettings(defaults: defaults)
            let memoryEpoch = try memoryStore.read().epoch
            let apiKey = apiKeyStore.readAPIKey()
            let executor = AIToolExecutor(modelContext: modelContext, memoryStore: memoryStore)
            var messages = AIAssistantRequestBuilder.makeMessages(
                systemPrompt: AISystemPrompt.text,
                inlineContext: makeInlineContext(),
                conversation: conversation
            )

            var readMemoryRevision: UUID?
            var handledToolNames: [String] = []
            var handledProposalCount = 0
            var visibleResponse = ""

            for _ in 0..<maxToolRounds {
                let memory = try memoryStore.read()
                guard memory.epoch == memoryEpoch else { throw AIGlobalMemoryError.clearedDuringRequest }
                if let revision = readMemoryRevision, revision != memory.revision {
                    expireMemoryReadResults(in: &messages)
                    readMemoryRevision = nil
                }
                let result = try await client.send(messages: messages, settings: settings, apiKey: apiKey)
                try Task.checkCancellation()
                guard try memoryStore.read().epoch == memoryEpoch else { throw AIGlobalMemoryError.clearedDuringRequest }
                let sanitized = AIVisibleResponse.sanitized(result.content)

                guard !result.toolCalls.isEmpty else {
                    visibleResponse = sanitized.isEmpty
                        ? AIVisibleResponse.fallbackText(toolNames: handledToolNames, proposalCount: handledProposalCount)
                        : sanitized
                    break
                }

                if !sanitized.isEmpty {
                    response = sanitized
                }
                messages.append(AIChatMessage(
                    role: "assistant",
                    content: result.content,
                    reasoningContent: result.reasoningContent,
                    toolCalls: result.toolCalls
                ))

                // Keep lookup activity visible through the following network request,
                // even if this response contains other, instantaneous tool operations.
                progress = AIAssistantProgress.progress(forToolNames: result.toolCalls.map { $0.function.name })
                var pendingProposals: [AIActionProposal] = []
                for call in result.toolCalls {
                    handledToolNames.append(call.function.name)
                    log(.debug, "AI tool requested", metadata: ["tool": call.function.name])
                    if call.function.name == "read_global_memory" || call.function.name == "save_global_memory" {
                        expireMemoryReadResults(in: &messages)
                        readMemoryRevision = nil
                    }
                    let toolResult = try executor.handle(call)
                    if call.function.name == "read_global_memory" { readMemoryRevision = try memoryStore.read().revision }
                    switch toolResult {
                    case let .context(content):
                        messages.append(AIChatMessage(role: "tool", content: content, toolCallID: call.id))
                    case let .memoryUpdated(content):
                        hasAppliedActions = true
                        messages.append(AIChatMessage(role: "tool", content: content, toolCallID: call.id))
                    case let .proposal(proposal):
                        handledProposalCount += 1
                        let toolMessage: String
                        if settings.requiresActionConfirmation || proposal.requiresMandatoryConfirmation {
                            pendingProposals.append(proposal)
                            toolMessage = "已创建待确认操作：\(proposal.summary)"
                        } else {
                            toolMessage = try executor.apply(proposal).toolMessage
                            hasAppliedActions = true
                        }
                        messages.append(AIChatMessage(role: "tool", content: toolMessage, toolCallID: call.id))
                    }
                }

                // Pending task approvals must not swallow subsequent memory/read tool calls.
                proposals.append(contentsOf: pendingProposals)
                if hasAppliedActions { todoReferenceRefreshID = UUID() }

            }

            if visibleResponse.isEmpty {
                visibleResponse = AIVisibleResponse.fallbackText(toolNames: handledToolNames, proposalCount: handledProposalCount)
            }
            if proposals.contains(where: \.requiresMandatoryConfirmation) {
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
            guard !Task.isCancelled else { return }
            if hasAppliedActions {
                response = "部分操作已执行，但后续 AI 请求失败。请先检查事项或记忆中的结果，避免重复提交。"
                conversation.appendAssistant(response)
            } else if !proposals.isEmpty {
                response = "操作已准备好，但后续 AI 请求失败。你仍可以确认或忽略这些操作。"
                conversation.appendAssistant(response)
            } else {
                self.prompt = prompt
                self.images = images
                conversation = previousConversation
            }
            state = .failed(error.localizedDescription)
            progress = .idle
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
        guard let items = try? modelContext.fetch(FetchDescriptor<TodoItem>()),
              let item = items.first(where: { $0.id == id })
        else {
            return AIReferencedTodo(id: id, title: "事项", priority: .low, groupName: nil, scheduleText: nil, createdAt: nil, isCompleted: false, exists: false)
        }
        let groups = (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
        let group = TodoGroupResolver.group(for: item, groups: groups)
        return AIReferencedTodo(
            id: id,
            title: item.title,
            priority: item.priority,
            groupName: group.name,
            scheduleText: TodoDeadlineFormatter.cardText(for: item),
            createdAt: item.createdAt,
            isCompleted: item.isCompleted,
            exists: true
        )
    }

    func titleForReferencedTodo(id: UUID) -> String {
        referencedTodo(id: id).title
    }

    private func syncConversationState() {
        hasVisibleConversation = conversation.hasVisibleContent
        hasTransientOutput = !response.isEmpty || !proposals.isEmpty || state.isFailure
    }

    private func makeInlineContext() -> AITodoInlineContext {
        do {
            let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
            let summaries = try modelContext.fetch(FetchDescriptor<DailySummary>())
            let groups = try modelContext.fetch(FetchDescriptor<TodoGroup>())
            return AITodoContext.snapshot(items: items, groups: groups, dailySummaries: summaries).inlineContext()
        } catch {
            log(.error, "AI inline context failed", metadata: ["error": error.localizedDescription])
            return AITodoInlineContext(content: "当前任务上下文读取失败，必要时请调用工具重新读取。")
        }
    }

    private func applyConfirmed(_ proposal: AIActionProposal) throws {
        _ = try AIToolExecutor(modelContext: modelContext, memoryStore: memoryStore).apply(proposal)
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

struct AIReferencedTodo: Equatable, Identifiable {
    let id: UUID
    let title: String
    let priority: TodoPriority
    let groupName: String?
    let scheduleText: String?
    let createdAt: Date?
    let isCompleted: Bool
    let exists: Bool

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
