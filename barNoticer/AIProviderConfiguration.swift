import Foundation

enum AIResponseFormat: String, Codable, CaseIterable, Identifiable {
    case chatCompletions, responses, anthropic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chatCompletions: "OpenAI Chat Completions"
        case .responses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        }
    }
    var endpoint: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        case .anthropic: "messages"
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
    var apiKey = ""
    var model = ""
    var reasoningEffort: AIReasoningEffort? = nil

    var url: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    var canDiscover: Bool { url != nil && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isReady: Bool { canDiscover && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var settings: AISettings {
        AISettings(baseURL: url ?? URL(string: "invalid://configuration")!,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines), responseFormat: responseFormat,
            reasoningEffort: reasoningEffort)
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
