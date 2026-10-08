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

struct AIProviderConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "新供应商"
    var baseURL = ""
    var responseFormat: AIResponseFormat = .chatCompletions
    var apiKey = ""
    var model = ""

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
            model: model.trimmingCharacters(in: .whitespacesAndNewlines), responseFormat: responseFormat)
    }
}

struct AIProviderCollection: Codable, Equatable {
    static let storageKey = "AIProviderConfigurations.v1"
    var providers: [AIProviderConfiguration]
    var activeID: UUID
    var mode: AIProviderMode = .single

    var active: AIProviderConfiguration? { providers.first { $0.id == activeID } }
    var routes: [AIProviderConfiguration] { mode == .ordered ? providers : active.map { [$0] } ?? [] }

    static func load(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Self.self, from: data), !saved.providers.isEmpty {
            return saved
        }
        // Import the existing installation exactly once, without discarding its key.
        let provider = AIProviderConfiguration(name: "默认供应商",
            baseURL: defaults.string(forKey: AISettings.baseURLKey) ?? "",
            apiKey: defaults.string(forKey: AIAPIKeyStore.apiKeyKey) ?? "",
            model: defaults.string(forKey: AISettings.modelKey) ?? "")
        return Self(providers: [provider], activeID: provider.id)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
