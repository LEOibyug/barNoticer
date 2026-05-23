import SwiftData
import SwiftUI

@main
struct barNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: TodoItem.self)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func configure(modelContainer: ModelContainer) {
        guard islandController == nil else { return }

        let controller = NotchIslandController(modelContainer: modelContainer)
        controller.start()
        islandController = controller
    }
}
