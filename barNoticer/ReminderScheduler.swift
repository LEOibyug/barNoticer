import Foundation
import SwiftData

@MainActor
final class ReminderScheduler {
    private let modelContext: ModelContext
    private let engine: AIReminderEngine
    private let presenter: ReminderPresenter
    private let historyStore: ReminderHistoryStore
    private let defaults: UserDefaults
    private let logStore: AppDebugLogStore
    private var deadlineTimer: Timer?
    private var pollTimer: Timer?
    private var settings: ReminderSettings
    private var isChecking = false

    init(
        modelContext: ModelContext,
        engine: AIReminderEngine? = nil,
        presenter: ReminderPresenter? = nil,
        historyStore: ReminderHistoryStore = ReminderHistoryStore(),
        defaults: UserDefaults = .standard,
        logStore: AppDebugLogStore = .shared
    ) {
        self.modelContext = modelContext
        self.historyStore = historyStore
        self.defaults = defaults
        self.logStore = logStore
        self.settings = ReminderSettings(defaults: defaults)
        self.engine = engine ?? AIReminderEngine(modelContext: modelContext, historyStore: historyStore, logStore: logStore)
        self.presenter = presenter ?? ReminderPresenter(modelContext: modelContext, historyStore: historyStore, logStore: logStore)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: ReminderSettings.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        deadlineTimer?.invalidate()
        pollTimer?.invalidate()
    }

    func start() {
        installDeadlineTimer()
        installPollTimer()
        Task { await checkDeadlineTriggers(now: Date()) }
    }

    @objc private func settingsChanged() {
        settings = ReminderSettings(defaults: defaults)
        installPollTimer()
    }

    private func installDeadlineTimer() {
        deadlineTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkDeadlineTriggers(now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func installPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard settings.aiPollingEnabled else { return }
        let timer = Timer(timeInterval: settings.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.run(trigger: .aiPoll, now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func checkDeadlineTriggers(now: Date) async {
        do {
            let snapshots = try ReminderSnapshotBuilder.make(modelContext: modelContext, now: now)
            let triggers = ReminderDeadlinePolicy.dueTriggers(
                for: snapshots.todos,
                now: now,
                history: historyStore,
                dedupeWindow: settings.dedupeWindow
            )
            for trigger in triggers {
                await run(trigger: trigger, now: now)
            }
        } catch {
            log(.error, "Deadline reminder scan failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func run(trigger: ReminderTrigger, now: Date) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let decision = await engine.decision(for: trigger, settings: settings, now: now)
        presenter.present(decision: decision, trigger: trigger, settings: settings, timestamp: now)
    }

    private func log(_ level: AppDebugLogStore.Level, _ message: String, metadata: [String: String] = [:]) {
        try? logStore.write(level, category: "Reminder", message: message, metadata: metadata)
    }
}
