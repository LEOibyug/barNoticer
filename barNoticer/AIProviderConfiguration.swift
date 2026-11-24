import Foundation

enum AIResponseFormat: String, Codable, CaseIterable, Identifiable {
    case chatCompletions, responses, anthropic, gemini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chatCompletions: "OpenAI Chat Completions"
        case .responses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Google AI Studio (Gemini)"
        }
    }
    var endpoint: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        case .anthropic: "messages"
        case .gemini: "models"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic: "https://api.anthropic.com/v1"
        case .chatCompletions, .responses: "https://api.openai.com/v1"
        }
    }
    var defaultModel: String {
        switch self {
        case .gemini: "gemini-2.5-flash"
        case .anthropic: "claude-sonnet-4-20250514"
        case .chatCompletions, .responses: "gpt-4o-mini"
        }
    }
    var supportsReasoningEffort: Bool {
        self == .chatCompletions || self == .responses
    }
}

enum AIEnvironmentAPIKey {
    static let geminiVariableName = "GEMINI_API_KEY"

    nonisolated static func geminiAPIKey(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        (environment[geminiVariableName] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func hasGeminiAPIKey(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !geminiAPIKey(in: environment).isEmpty
    }
}

enum AIAPIKeySource: String, Codable, CaseIterable, Identifiable {
    case manual
    case environment

    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "手动输入"
        case .environment: "环境变量（\(AIEnvironmentAPIKey.geminiVariableName)）"
        }
    }
}

enum AIProviderMode: String, Codable, CaseIterable, Identifiable {
    case single, ordered
    var id: String { rawValue }
    var title: String { self == .single ? "仅使用指定配置" : "按列表顺序尝试" }
}

enum AIReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh
    var id: String { rawValue }
}

struct AIProviderConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "新供应商"
    var baseURL = ""
    var responseFormat: AIResponseFormat = .chatCompletions
    var apiKeySource: AIAPIKeySource = .manual
    var apiKey = ""
    var model = ""
    var reasoningEffort: AIReasoningEffort? = nil

    var effectiveAPIKeySource: AIAPIKeySource {
        responseFormat == .gemini ? apiKeySource : .manual
    }

    var url: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    func resolvedAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        switch effectiveAPIKeySource {
        case .manual:
            return apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .environment:
            return AIEnvironmentAPIKey.geminiAPIKey(in: environment)
        }
    }

    func canDiscover(environment: [String: String]) -> Bool {
        url != nil && !resolvedAPIKey(environment: environment).isEmpty
    }

    func isReady(environment: [String: String]) -> Bool {
        canDiscover(environment: environment) && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canDiscover: Bool { canDiscover(environment: ProcessInfo.processInfo.environment) }
    var isReady: Bool { isReady(environment: ProcessInfo.processInfo.environment) }

    var settings: AISettings {
        AISettings(baseURL: url ?? URL(string: "invalid://configuration")!,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines), responseFormat: responseFormat,
            reasoningEffort: reasoningEffort, apiKeySource: effectiveAPIKeySource)
    }
}

extension AIProviderConfiguration {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "新供应商"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        responseFormat = try container.decodeIfPresent(AIResponseFormat.self, forKey: .responseFormat) ?? .chatCompletions
        apiKeySource = try container.decodeIfPresent(AIAPIKeySource.self, forKey: .apiKeySource) ?? .manual
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        reasoningEffort = try container.decodeIfPresent(AIReasoningEffort.self, forKey: .reasoningEffort)
    }
}

struct AIProviderCollection: Codable, Equatable {
    static let storageKey = "AIProviderConfigurations.v1"
    var providers: [AIProviderConfiguration]
    var activeID: UUID
    var mode: AIProviderMode = .single

    var active: AIProviderConfiguration? { providers.first { $0.id == activeID } }
    var routes: [AIProviderConfiguration] { mode == .ordered ? providers : active.map { [$0] } ?? [] }

    static func load(from defaults: UserDefaults, keyStore: AIAPIKeyStore? = nil) -> Self {
        let store = keyStore ?? AIAPIKeyStore(defaults: defaults)
        if let data = defaults.data(forKey: storageKey),
           var saved = try? JSONDecoder().decode(Self.self, from: data), !saved.providers.isEmpty {
            var needsScrub = false
            for index in saved.providers.indices {
                let providerID = saved.providers[index].id
                let inlineKey = saved.providers[index].apiKey
                if !inlineKey.isEmpty {
                    store.saveAPIKey(inlineKey, for: providerID)
                    needsScrub = true
                }
                saved.providers[index].apiKey = store.readAPIKey(for: providerID)
            }
            if needsScrub {
                saved.save(to: defaults, keyStore: store)
            }
            return saved
        }
        // Import the existing installation exactly once, without discarding its key.
        let provider = AIProviderConfiguration(name: "默认供应商",
            baseURL: defaults.string(forKey: AISettings.baseURLKey) ?? "",
            apiKey: store.readAPIKey(),
            model: defaults.string(forKey: AISettings.modelKey) ?? "")
        return Self(providers: [provider], activeID: provider.id)
    }

    func save(to defaults: UserDefaults, keyStore: AIAPIKeyStore? = nil) {
        let store = keyStore ?? AIAPIKeyStore(defaults: defaults)
        for provider in providers {
            store.saveAPIKey(provider.apiKey, for: provider.id)
        }
        store.pruneProviderKeys(keeping: Set(providers.map(\.id)))
        store.saveAPIKey(active?.apiKey ?? "")

        var redacted = self
        for index in redacted.providers.indices {
            redacted.providers[index].apiKey = ""
        }
        guard let data = try? JSONEncoder().encode(redacted) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
