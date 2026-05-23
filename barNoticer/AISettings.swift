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

    var baseURL: URL
    var model: String
    var shortcut: AIKeyboardShortcut
    var requiresActionConfirmation: Bool

    init(
        baseURL: URL = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        shortcut: AIKeyboardShortcut = .default,
        requiresActionConfirmation: Bool = true
    ) {
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
    }

    var isValid: Bool {
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }

        return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    var baseURLText: String {
        didSet { saveIfLoaded() }
    }
    var model: String {
        didSet { saveIfLoaded() }
    }
    var apiKey: String {
        didSet { saveIfLoaded() }
    }
    var shortcut: AIKeyboardShortcut {
        didSet { saveIfLoaded() }
    }
    var requiresActionConfirmation: Bool {
        didSet { saveIfLoaded() }
    }

    init(defaults: UserDefaults = .standard, keyStore: AIAPIKeyStore = .shared) {
        self.defaults = defaults
        self.keyStore = keyStore
        let settings = AISettings(defaults: defaults)
        baseURLText = settings.baseURL.absoluteString
        model = settings.model
        apiKey = keyStore.readAPIKey()
        shortcut = settings.shortcut
        requiresActionConfirmation = settings.requiresActionConfirmation
    }

    var settings: AISettings {
        AISettings(
            baseURL: URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? AISettings.defaultBaseURL,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            shortcut: shortcut,
            requiresActionConfirmation: requiresActionConfirmation
        )
    }

    var canTestConnection: Bool {
        settings.isValid && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func reload() {
        isLoading = true
        let stored = AISettings(defaults: defaults)
        baseURLText = stored.baseURL.absoluteString
        model = stored.model
        shortcut = stored.shortcut
        requiresActionConfirmation = stored.requiresActionConfirmation
        apiKey = keyStore.readAPIKey()
        isLoading = false
    }

    private func saveIfLoaded() {
        guard !isLoading else { return }
        settings.save(to: defaults)
        keyStore.saveAPIKey(apiKey)
    }
}

struct AIKeyboardShortcut: Equatable {
    static let `default` = AIKeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: [.command, .option])

    let keyCode: UInt32
    let modifiers: AIShortcutModifiers

    init(keyCode: UInt32, modifiers: AIShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(defaults: UserDefaults) {
        guard defaults.object(forKey: AISettings.shortcutKeyCodeKey) != nil else { return nil }
        let keyCode = UInt32(defaults.integer(forKey: AISettings.shortcutKeyCodeKey))
        let rawModifiers = UInt32(defaults.integer(forKey: AISettings.shortcutModifiersKey))
        self.init(keyCode: keyCode, modifiers: AIShortcutModifiers(rawValue: rawModifiers))
    }

    var displayValue: String {
        "\(modifiers.displayValue)\(Self.keyName(for: keyCode))"
    }

    var carbonModifiers: UInt32 {
        modifiers.carbonFlags
    }

    func save(to defaults: UserDefaults) {
        defaults.set(Int(keyCode), forKey: AISettings.shortcutKeyCodeKey)
        defaults.set(Int(modifiers.rawValue), forKey: AISettings.shortcutModifiersKey)
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
