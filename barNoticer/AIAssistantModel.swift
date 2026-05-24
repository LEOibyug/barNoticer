import Combine
import Foundation
import SwiftData

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
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .loading
    }

    func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        prompt = ""
        response = ""
        proposals = []
        state = .loading
        progress = .thinking
        conversation.appendUser(text)
        syncConversationState()
        log(.info, "AI request started", metadata: ["promptLength": "\(text.count)"])
        logChat(role: "User", content: text)

        Task {
            await run(prompt: text)
        }
    }

    func apply(_ proposal: AIActionProposal) {
        do {
            try applyConfirmed(proposal)
            proposals.removeAll { $0.id == proposal.id && $0.summary == proposal.summary }
            todoReferenceRefreshID = UUID()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func applyAllProposals() {
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

    func resetTransientOutput() {
        proposals = []
        if !conversation.hasVisibleContent {
            response = ""
            state = .idle
        }
        progress = .idle
        syncConversationState()
    }

    func resetSessionForContextRefresh() {
        prompt = ""
        response = ""
        proposals = []
        state = .idle
        progress = .idle
        conversation.reset()
        syncConversationState()
    }

    func requestInputFocus() {
        focusRequestID = UUID()
    }

    private func run(prompt: String) async {
        do {
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
                        let toolMessage = settings.requiresActionConfirmation
                            ? "已创建待确认操作：\(proposal.summary)"
                            : try executor.apply(proposal).toolMessage
                        messages.append(AIChatMessage(role: "tool", content: toolMessage, toolCallID: call.id))
                    }
                }

                if settings.requiresActionConfirmation, !pendingProposals.isEmpty {
                    stageOrApply(pendingProposals, settings: settings)
                    let final = try await client.send(messages: messages, settings: settings, apiKey: apiKey)
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
        } catch {
            state = .failed(error.localizedDescription)
            progress = .idle
            syncConversationState()
            log(.error, "AI request failed", metadata: ["error": error.localizedDescription])
        }
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
