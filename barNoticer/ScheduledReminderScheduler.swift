import AppKit
import Combine
import SwiftData

@MainActor
protocol ReminderPresenting: AnyObject {
    func present(decision: ReminderDecision, trigger: ReminderTrigger, settings: ReminderSettings, timestamp: Date)
}

/// User-scheduled reminders run locally, independently of AI polling and network requests.
@MainActor
final class ScheduledReminderScheduler {
    private let modelContext: ModelContext
    private let presenter: any ReminderPresenting
    private let engine: AIReminderEngine
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observations: [AnyCancellable] = []
    private var preparedMessages: [String: ReminderDecision] = [:]
    private var preparation: Task<Void, Never>?
    private var preparationID: UUID?
    private var isStarted = false

    init(modelContext: ModelContext, presenter: any ReminderPresenting, engine: AIReminderEngine, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.presenter = presenter
        self.engine = engine
        self.defaults = defaults
    }

    deinit {
        timer?.invalidate()
        preparation?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        for name in [ModelContext.didSave, ReminderSettings.didChangeNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }.store(in: &observations)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &observations)
        refresh()
    }

    func refresh(now: Date = Date()) {
        let settings = ReminderSettings(defaults: defaults)
        if !settings.scheduledAIWordingEnabled {
            preparation?.cancel()
            preparation = nil
            preparationID = nil
            preparedMessages = [:]
        }
        guard let items = try? modelContext.fetch(FetchDescriptor<TodoItem>()) else {
            installTimer(at: now.addingTimeInterval(30))
            return
        }
        let pending = items.compactMap { item -> (TodoItem, TodoScheduledReminder, String)? in
            guard let reminder = TodoScheduledReminder(item: item) else { return nil }
            let key = reminder.key + ":" + item.title + ":" + (item.note ?? "") + ":" + settings.tone.rawValue
            return (item, reminder, key)
        }.sorted { $0.1.fireDate < $1.1.fireDate }
        let validKeys = Set(pending.map { $0.2 })
        preparedMessages = preparedMessages.filter { validKeys.contains($0.key) }

        for (item, reminder, cacheKey) in pending where reminder.fireDate <= now {
            // Persist the occurrence key, so relaunching or another timer tick
            // cannot deliver the same configured reminder again.
            let previous = item.lastDeliveredReminderKey
            item.lastDeliveredReminderKey = reminder.key
            do { try modelContext.save() }
            catch {
                item.lastDeliveredReminderKey = previous
                continue
            }
            let prepared = preparedMessages.removeValue(forKey: cacheKey)
            let decision = prepared?.shouldRemind == true ? prepared! : reminder.fallback(now: now)
            presenter.present(decision: decision, trigger: reminder.trigger, settings: settings, timestamp: now)
        }

        let nextDate = pending.map { $0.1.fireDate }.first { $0 > now }
        installTimer(at: min(nextDate ?? now.addingTimeInterval(30), now.addingTimeInterval(30)))

        // Generate wording ahead of time; delivery never waits for an AI call.
        if settings.scheduledAIWordingEnabled, preparation == nil,
           let (_, reminder, cacheKey) = pending.first(where: { $0.1.fireDate > now && preparedMessages[$0.2] == nil }) {
            let id = UUID()
            preparationID = id
            preparation = Task { [weak self, engine] in
                let decision = await engine.decision(for: reminder.trigger, settings: settings, now: now)
                guard let self, !Task.isCancelled, self.preparationID == id else { return }
                self.preparedMessages[cacheKey] = decision
                self.preparation = nil
                self.preparationID = nil
                self.refresh()
            }
        }
    }

    private func installTimer(at date: Date) {
        guard isStarted else { return }
        timer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
