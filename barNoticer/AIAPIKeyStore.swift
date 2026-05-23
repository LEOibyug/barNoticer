import Foundation

struct AIAPIKeyStore {
    static let shared = AIAPIKeyStore()
    static let apiKeyKey = "AISettingsAPIKey"

    var defaults: UserDefaults = .standard

    func readAPIKey() -> String {
        defaults.string(forKey: Self.apiKeyKey) ?? ""
    }

    func saveAPIKey(_ value: String) {
        defaults.set(value, forKey: Self.apiKeyKey)
    }
}
