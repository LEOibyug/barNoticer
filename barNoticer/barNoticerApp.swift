import SwiftData
import SwiftUI

@main
struct barNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self)
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
    private var assistantHotKeyController: GlobalHotKeyController?
    private var todoCreationController: TodoCreationPanelController?
    private var todoCreationHotKeyController: GlobalHotKeyController?
    private var reminderScheduler: ReminderScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func configure(modelContainer: ModelContainer) {
        guard islandController == nil else { return }

        TodoGroupBootstrap.ensureDefaultGroup(in: modelContainer.mainContext)

        let controller = NotchIslandController(modelContainer: modelContainer)
        controller.start()
        islandController = controller

        let reminders = ReminderScheduler(modelContext: modelContainer.mainContext)
        reminders.start()
        reminderScheduler = reminders

        let assistant = AIAssistantPanelController(modelContext: modelContainer.mainContext)
        assistantController = assistant

        let todoCreation = TodoCreationPanelController(modelContext: modelContainer.mainContext)
        todoCreationController = todoCreation

        let assistantHotKey = GlobalHotKeyController(id: 1) { [weak assistant] in
            assistant?.toggle()
        }
        assistantHotKey.register(shortcut: AISettings(defaults: .standard).shortcut)
        assistantHotKeyController = assistantHotKey

        let creationHotKey = GlobalHotKeyController(id: 2) { [weak todoCreation] in
            todoCreation?.toggle()
        }
        creationHotKey.register(shortcut: TodoCreationSettings(defaults: .standard).shortcut)
        todoCreationHotKeyController = creationHotKey

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(aiSettingsChanged),
            name: AISettings.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(todoCreationSettingsChanged),
            name: TodoCreationSettings.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showTodoCreationPanel),
            name: TodoCreationSettings.showPanelNotification,
            object: nil
        )
    }

    @objc private func aiSettingsChanged() {
        assistantHotKeyController?.register(shortcut: AISettings(defaults: .standard).shortcut)
    }

    @objc private func todoCreationSettingsChanged() {
        todoCreationHotKeyController?.register(shortcut: TodoCreationSettings(defaults: .standard).shortcut)
    }

    @objc private func showTodoCreationPanel() {
        todoCreationController?.show()
    }
}
