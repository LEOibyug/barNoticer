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
        logStore: AppDebugLogStore? = nil
    ) {
        self.modelContext = modelContext
        self.client = client ?? AIClient()
        self.apiKeyStore = apiKeyStore ?? .shared
        self.defaults = defaults
        self.logStore = logStore ?? .shared
    }

    var canSubmit: Bool {
        (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
            && state != .loading && !isComposingPromptText
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
            for proposal in proposals {
                try applyConfirmed(proposal)
            }
            proposals = []
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
            for proposal in proposals {
                _ = try applyConfirmed(proposal)
            }
            self.proposals = []
            todoReferenceRefreshID = UUID()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismiss(_ proposal: AIActionProposal) {
        proposals.removeAll { $0.id == proposal.id && $0.summary == proposal.summary }
    }

    func dismissAllProposals() {
        proposals = []
    }

    func startNewConversation() {
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

    private func run(prompt: String, images: [AIImageAttachment], previousConversation: AIConversationHistory) async {
        var hasAppliedActions = false
        do {
            try Task.checkCancellation()
            let settings = AISettings(defaults: defaults)
            let apiKey = apiKeyStore.readAPIKey()
            let executor = AIToolExecutor(modelContext: modelContext)
            var messages = AIAssistantRequestBuilder.makeMessages(
                systemPrompt: AISystemPrompt.text,
                inlineContext: makeInlineContext(),
                conversation: conversation
            )

            var handledToolNames: [String] = []
            var handledProposalCount = 0
            var visibleResponse = ""

            for _ in 0..<maxToolRounds {
                let result = try await client.send(messages: messages, settings: settings, apiKey: apiKey)
                try Task.checkCancellation()
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

                var pendingProposals: [AIActionProposal] = []
                for call in result.toolCalls {
                    handledToolNames.append(call.function.name)
                    progress = AIAssistantProgress.progress(forToolName: call.function.name)
                    log(.debug, "AI tool requested", metadata: ["tool": call.function.name])
                    let toolResult = try executor.handle(call)
                    switch toolResult {
                    case let .context(content):
                        messages.append(AIChatMessage(role: "tool", content: content, toolCallID: call.id))
                    case let .proposal(proposal):
                        handledProposalCount += 1
                        pendingProposals.append(proposal)
                        let toolMessage: String
                        if settings.requiresActionConfirmation {
                            toolMessage = "已创建待确认操作：\(proposal.summary)"
                        } else {
                            toolMessage = try executor.apply(proposal).toolMessage
                            hasAppliedActions = true
                        }
                        messages.append(AIChatMessage(role: "tool", content: toolMessage, toolCallID: call.id))
                    }
                }

                if settings.requiresActionConfirmation, !pendingProposals.isEmpty {
                    stageOrApply(pendingProposals, settings: settings)
                    let final = try await client.send(messages: messages, settings: settings, apiKey: apiKey)
                    try Task.checkCancellation()
                    let visibleFinal = AIVisibleResponse.sanitized(final.content)
                    visibleResponse = visibleFinal.isEmpty
                        ? (sanitized.isEmpty ? AIVisibleResponse.fallbackText(toolNames: handledToolNames, proposalCount: handledProposalCount) : sanitized)
                        : visibleFinal
                    break
                }

                if !settings.requiresActionConfirmation {
                    proposals = []
                    todoReferenceRefreshID = UUID()
                }
            }

            if visibleResponse.isEmpty {
                visibleResponse = AIVisibleResponse.fallbackText(toolNames: handledToolNames, proposalCount: handledProposalCount)
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
                response = "部分操作已执行，但后续 AI 请求失败。请先检查事项列表，避免重复提交。"
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
        _ = try AIToolExecutor(modelContext: modelContext).apply(proposal)
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
