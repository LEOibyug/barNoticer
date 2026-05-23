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
        state = .loading
        progress = .thinking
        conversation.appendUser(text)
        proposals = []
        syncConversationState()
        log(.info, "AI request started", metadata: ["promptLength": "\(text.count)"])

        Task {
            await run(prompt: text)
        }
    }

    func apply(_ proposal: AIActionProposal) {
        do {
            try applyConfirmed(proposal)
            proposals.removeAll { $0.id == proposal.id && $0.summary == proposal.summary }
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
                try applyConfirmed(proposal)
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

            let first = try await client.send(messages: messages, settings: settings, apiKey: apiKey)
            guard !first.toolCalls.isEmpty else {
                response = AIVisibleResponse.sanitized(first.content)
                if response.isEmpty {
                    response = AIVisibleResponse.fallbackText(toolCallCount: 0, proposalCount: 0)
                }
                conversation.appendAssistant(response)
                state = .ready
                progress = .idle
                syncConversationState()
                log(.info, "AI request completed", metadata: ["toolCalls": "0"])
                return
            }
            response = AIVisibleResponse.sanitized(first.content)

            let assistantToolMessage = AIChatMessage(
                role: "assistant",
                content: first.content,
                reasoningContent: first.reasoningContent,
                toolCalls: first.toolCalls
            )
            messages.append(assistantToolMessage)
            var pendingProposals: [AIActionProposal] = []

            for call in first.toolCalls {
                progress = AIAssistantProgress.progress(forToolName: call.function.name)
                log(.debug, "AI tool requested", metadata: ["tool": call.function.name])
                let result = try executor.handle(call)
                switch result {
                case let .context(content):
                    messages.append(AIChatMessage(role: "tool", content: content, toolCallID: call.id))
                case let .proposal(proposal):
                    pendingProposals.append(proposal)
                    let toolMessage = settings.requiresActionConfirmation
                        ? "已创建待确认操作：\(proposal.summary)"
                        : "操作已执行：\(proposal.summary)"
                    messages.append(AIChatMessage(role: "tool", content: toolMessage, toolCallID: call.id))
                }
            }

            stageOrApply(pendingProposals, settings: settings)
            let final = try await client.send(messages: messages, settings: settings, apiKey: apiKey)
            let visibleFinal = AIVisibleResponse.sanitized(final.content)
            let visibleFirst = AIVisibleResponse.sanitized(first.content)
            let visibleResponse = visibleFinal.isEmpty
                ? (visibleFirst.isEmpty ? AIVisibleResponse.fallbackText(toolNames: first.toolCalls.map(\.function.name), proposalCount: pendingProposals.count) : visibleFirst)
                : visibleFinal
            response = visibleResponse
            conversation.appendAssistant(visibleResponse)
            state = .ready
            progress = .idle
            syncConversationState()
            log(.info, "AI request completed", metadata: ["toolCalls": "\(first.toolCalls.count)", "proposals": "\(pendingProposals.count)"])
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
            return AIReferencedTodo(id: id, title: "事项", priority: .low, createdAt: nil, isCompleted: false, exists: false)
        }
        return AIReferencedTodo(id: id, title: item.title, priority: item.priority, createdAt: item.createdAt, isCompleted: item.isCompleted, exists: true)
    }

    func titleForReferencedTodo(id: UUID) -> String {
        referencedTodo(id: id).title
    }

    private func syncConversationState() {
        hasVisibleConversation = conversation.hasVisibleContent
        hasTransientOutput = !response.isEmpty || !proposals.isEmpty || state.isFailure || state == .loading
    }

    private func makeInlineContext() -> AITodoInlineContext {
        do {
            let items = try modelContext.fetch(FetchDescriptor<TodoItem>())
            let summaries = try modelContext.fetch(FetchDescriptor<DailySummary>())
            return AITodoContext.snapshot(items: items, dailySummaries: summaries).inlineContext()
        } catch {
            log(.error, "AI inline context failed", metadata: ["error": error.localizedDescription])
            return AITodoInlineContext(content: "当前任务上下文读取失败，必要时请调用工具重新读取。")
        }
    }

    private func applyConfirmed(_ proposal: AIActionProposal) throws {
        try AIToolExecutor(modelContext: modelContext).apply(proposal)
    }

    private func log(_ level: AppDebugLogStore.Level, _ message: String, metadata: [String: String] = [:]) {
        try? logStore.write(level, category: "AI", message: message, metadata: metadata)
    }
}

struct AIReferencedTodo: Equatable, Identifiable {
    let id: UUID
    let title: String
    let priority: TodoPriority
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
