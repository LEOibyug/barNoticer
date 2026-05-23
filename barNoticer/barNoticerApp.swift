import SwiftData
import SwiftUI

@main
struct barNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: TodoItem.self, DailySummary.self)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .modelContainer(modelContainer)
                .onAppear {
                    appDelegate.configure(modelContainer: modelContainer)
                }
        }
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandController: NotchIslandController?
    private var assistantController: AIAssistantPanelController?
    private var hotKeyController: GlobalHotKeyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func configure(modelContainer: ModelContainer) {
        guard islandController == nil else { return }

        let controller = NotchIslandController(modelContainer: modelContainer)
        controller.start()
        islandController = controller

        let assistant = AIAssistantPanelController(modelContext: modelContainer.mainContext)
        assistantController = assistant

        let hotKey = GlobalHotKeyController { [weak assistant] in
            assistant?.toggle()
        }
        hotKey.register(shortcut: AISettings(defaults: .standard).shortcut)
        hotKeyController = hotKey

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(aiSettingsChanged),
            name: AISettings.didChangeNotification,
            object: nil
        )
    }

    @objc private func aiSettingsChanged() {
        hotKeyController?.register(shortcut: AISettings(defaults: .standard).shortcut)
    }
}
