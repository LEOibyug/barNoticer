import Carbon.HIToolbox
import Foundation

struct AISettings: Equatable {
    static let didChangeNotification = Notification.Name("AISettingsDidChange")
    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    static let defaultModel = "gpt-4o-mini"
    static let baseURLKey = "AISettingsBaseURL"
    static let modelKey = "AISettingsModel"
    static let shortcutKeyCodeKey = "AISettingsShortcutKeyCode"
    static let shortcutModifiersKey = "AISettingsShortcutModifiers"
    static let requiresActionConfirmationKey = "AISettingsRequiresActionConfirmation"

    var responseFormat: AIResponseFormat = .chatCompletions
    var providerRoutes: [AIProviderConfiguration]?
    var baseURL: URL
    var model: String
    var shortcut: AIKeyboardShortcut
    var requiresActionConfirmation: Bool

    init(
        baseURL: URL = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        shortcut: AIKeyboardShortcut = .default,
        requiresActionConfirmation: Bool = true,
        responseFormat: AIResponseFormat = .chatCompletions
    ) {
        self.responseFormat = responseFormat
        self.baseURL = baseURL
        self.model = model
        self.shortcut = shortcut
        self.requiresActionConfirmation = requiresActionConfirmation
    }

    init(defaults: UserDefaults) {
        let storedBaseURL = defaults.string(forKey: Self.baseURLKey).flatMap(URL.init(string:))
        let storedModel = defaults.string(forKey: Self.modelKey)
        let storedShortcut = AIKeyboardShortcut(defaults: defaults)

        self.init(
            baseURL: storedBaseURL ?? Self.defaultBaseURL,
            model: storedModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? storedModel! : Self.defaultModel,
            shortcut: storedShortcut ?? .default,
            requiresActionConfirmation: defaults.object(forKey: Self.requiresActionConfirmationKey) == nil ? true : defaults.bool(forKey: Self.requiresActionConfirmationKey)
        )
        if defaults.data(forKey: AIProviderCollection.storageKey) != nil {
            let collection = AIProviderCollection.load(from: defaults)
            providerRoutes = collection.routes
            if let active = collection.active {
                baseURL = active.settings.baseURL
                model = active.settings.model
                responseFormat = active.responseFormat
            }
        }
    }

    var isValid: Bool {
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }

        return baseURL.host != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var chatCompletionsURL: URL {
        baseURL
            .standardized
            .appendingPathComponent("chat/completions")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(baseURL.absoluteString, forKey: Self.baseURLKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(requiresActionConfirmation, forKey: Self.requiresActionConfirmationKey)
        shortcut.save(to: defaults)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

struct AISettingsDraft {
    private let defaults: UserDefaults
    private let keyStore: AIAPIKeyStore
    private var isLoading = false
    var collection: AIProviderCollection
    var editingID: UUID
    var shortcut: AIKeyboardShortcut { didSet { saveIfLoaded() } }
    var requiresActionConfirmation: Bool { didSet { saveIfLoaded() } }

    init(defaults: UserDefaults = .standard, keyStore: AIAPIKeyStore = .shared) {
        self.defaults = defaults
        self.keyStore = keyStore
        let settings = AISettings(defaults: defaults)
        collection = AIProviderCollection.load(from: defaults)
        editingID = collection.activeID
        shortcut = settings.shortcut
        requiresActionConfirmation = settings.requiresActionConfirmation
    }

    var provider: AIProviderConfiguration {
        get { collection.providers.first { $0.id == editingID } ?? collection.providers[0] }
        set {
            guard let index = collection.providers.firstIndex(where: { $0.id == editingID }) else { return }
            collection.providers[index] = newValue
            saveIfLoaded()
        }
    }
    var baseURLText: String { get { provider.baseURL } set { provider.baseURL = newValue } }
    var model: String { get { provider.model } set { provider.model = newValue } }
    var apiKey: String { get { provider.apiKey } set { provider.apiKey = newValue } }
    var settings: AISettings { provider.settings }
    var canTestConnection: Bool { provider.isReady }

    mutating func addProvider() {
        let new = AIProviderConfiguration(name: "供应商 \(collection.providers.count + 1)")
        collection.providers.append(new)
        editingID = new.id
        saveIfLoaded()
    }
    mutating func removeProvider() {
        guard collection.providers.count > 1 else { return }
        collection.providers.removeAll { $0.id == editingID }
        if collection.activeID == editingID { collection.activeID = collection.providers[0].id }
        editingID = collection.providers[0].id
        saveIfLoaded()
    }
    mutating func moveProvider(by offset: Int) {
        guard let index = collection.providers.firstIndex(where: { $0.id == editingID }),
              collection.providers.indices.contains(index + offset) else { return }
        collection.providers.swapAt(index, index + offset)
        saveIfLoaded()
    }
    mutating func setMode(_ mode: AIProviderMode) { collection.mode = mode; saveIfLoaded() }
    mutating func setActive(_ id: UUID) { collection.activeID = id; saveIfLoaded() }

    mutating func reload() {
        isLoading = true
        let stored = AISettings(defaults: defaults)
        collection = AIProviderCollection.load(from: defaults)
        if !collection.providers.contains(where: { $0.id == editingID }) { editingID = collection.activeID }
        shortcut = stored.shortcut
        requiresActionConfirmation = stored.requiresActionConfirmation
        isLoading = false
    }

    private func saveIfLoaded() {
        guard !isLoading else { return }
        collection.save(to: defaults)
        var active = collection.active?.settings ?? AISettings()
        active.shortcut = shortcut
        active.requiresActionConfirmation = requiresActionConfirmation
        keyStore.saveAPIKey(collection.active?.apiKey ?? "")
        active.save(to: defaults)
    }
}

struct AIKeyboardShortcut: Equatable {
    static let `default` = AIKeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: [.command, .option])
    static let createTodoDefault = AIKeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: [.command, .option])

    let keyCode: UInt32
    let modifiers: AIShortcutModifiers

    init(keyCode: UInt32, modifiers: AIShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(defaults: UserDefaults) {
        self.init(
            defaults: defaults,
            keyCodeKey: AISettings.shortcutKeyCodeKey,
            modifiersKey: AISettings.shortcutModifiersKey
        )
    }

    init?(defaults: UserDefaults, keyCodeKey: String, modifiersKey: String) {
        guard defaults.object(forKey: keyCodeKey) != nil else { return nil }
        let keyCode = UInt32(defaults.integer(forKey: keyCodeKey))
        let rawModifiers = UInt32(defaults.integer(forKey: modifiersKey))
        self.init(keyCode: keyCode, modifiers: AIShortcutModifiers(rawValue: rawModifiers))
    }

    var displayValue: String {
        "\(modifiers.displayValue)\(Self.keyName(for: keyCode))"
    }

    var carbonModifiers: UInt32 {
        modifiers.carbonFlags
    }

    func save(to defaults: UserDefaults) {
        save(
            to: defaults,
            keyCodeKey: AISettings.shortcutKeyCodeKey,
            modifiersKey: AISettings.shortcutModifiersKey
        )
    }

    func save(to defaults: UserDefaults, keyCodeKey: String, modifiersKey: String) {
        defaults.set(Int(keyCode), forKey: keyCodeKey)
        defaults.set(Int(modifiers.rawValue), forKey: modifiersKey)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_ANSI_A...kVK_ANSI_Z:
            let names: [Int: String] = [
                kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
                kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
                kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
                kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
                kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
                kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
                kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z"
            ]
            return names[Int(keyCode)] ?? "Key \(keyCode)"
        default:
            return "Key \(keyCode)"
        }
    }
}

struct AIShortcutModifiers: OptionSet, Equatable {
    let rawValue: UInt32

    static let command = AIShortcutModifiers(rawValue: 1 << 0)
    static let option = AIShortcutModifiers(rawValue: 1 << 1)
    static let control = AIShortcutModifiers(rawValue: 1 << 2)
    static let shift = AIShortcutModifiers(rawValue: 1 << 3)

    var displayValue: String {
        var result = ""
        if contains(.command) { result += "⌘" }
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        return result
    }

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
