import Carbon.HIToolbox
import Foundation

struct TodoCreationSettings: Equatable {
    static let didChangeNotification = Notification.Name("TodoCreationSettingsDidChange")
    static let showPanelNotification = Notification.Name("TodoCreationShowPanel")
    static let shortcutKeyCodeKey = "TodoCreationShortcutKeyCode"
    static let shortcutModifiersKey = "TodoCreationShortcutModifiers"

    var shortcut: AIKeyboardShortcut

    init(shortcut: AIKeyboardShortcut = .createTodoDefault) {
        self.shortcut = shortcut
    }

    init(defaults: UserDefaults) {
        self.init(shortcut: AIKeyboardShortcut(
            defaults: defaults,
            keyCodeKey: Self.shortcutKeyCodeKey,
            modifiersKey: Self.shortcutModifiersKey
        ) ?? .createTodoDefault)
    }

    func save(to defaults: UserDefaults = .standard) {
        shortcut.save(
            to: defaults,
            keyCodeKey: Self.shortcutKeyCodeKey,
            modifiersKey: Self.shortcutModifiersKey
        )
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

struct TodoCreationSettingsDraft {
    private let defaults: UserDefaults
    private var isLoading = false

    var shortcut: AIKeyboardShortcut {
        didSet { saveIfLoaded() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = TodoCreationSettings(defaults: defaults).shortcut
    }

    mutating func reload() {
        isLoading = true
        shortcut = TodoCreationSettings(defaults: defaults).shortcut
        isLoading = false
    }

    private func saveIfLoaded() {
        guard !isLoading else { return }
        TodoCreationSettings(shortcut: shortcut).save(to: defaults)
    }
}
