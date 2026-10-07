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
    /// 读取或投递标记保存失败后的重试退避：30/60/120/300 秒，新数据事件可提前重试。
    private static let retryDelays: [TimeInterval] = [30, 60, 120, 300]

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
    private var preparedMemoryRevision: UUID?
    private var isRefreshScheduled = false
    private var retryDelayIndex = 0

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

        // 事项保存、提醒设置、记忆变更都会触发重算；不再依赖周期兜底扫描。
        for name in [ModelContext.didSave, ReminderSettings.didChangeNotification, AIGlobalMemoryStore.didChangeNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }.store(in: &observations)
        }
        // 休眠唤醒后重新计算错过的提醒。
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }.store(in: &observations)
        // 时钟调整与时区变化可能改变到期判断或本地文案解释。
        for name: Notification.Name in [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }.store(in: &observations)
        }
        refresh()
    }

    /// 批量保存（拖动排序、批量投递标记）等密集事件合并为一次待执行 refresh。
    func scheduleRefresh() {
        guard isStarted, !isRefreshScheduled else { return }
        isRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.isRefreshScheduled = false
            self?.refresh()
        }
    }

    func refresh(now: Date = Date()) {
        let settings = ReminderSettings(defaults: defaults)
        let revision = engine.memoryRevision
        if !settings.scheduledAIWordingEnabled || revision != preparedMemoryRevision {
            preparation?.cancel()
            preparation = nil
            preparationID = nil
            preparedMessages = [:]
            preparedMemoryRevision = revision
        }
        guard let items = try? modelContext.fetch(FetchDescriptor<TodoItem>()) else {
            scheduleRetry()
            return
        }
        let pending = items.compactMap { item -> (TodoItem, TodoScheduledReminder, String)? in
            guard let reminder = TodoScheduledReminder(item: item) else { return nil }
            let key = reminder.key + ":" + item.title + ":" + (item.note ?? "") + ":" + settings.tone.rawValue
            return (item, reminder, key)
        }.sorted { $0.1.fireDate < $1.1.fireDate }
        let validKeys = Set(pending.map { $0.2 })
        preparedMessages = preparedMessages.filter { validKeys.contains($0.key) }

        var didFailPersistingDelivery = false
        for (item, reminder, cacheKey) in pending where reminder.fireDate <= now {
            // Persist the occurrence key, so relaunching or another timer tick
            // cannot deliver the same configured reminder again.
            let previous = item.lastDeliveredReminderKey
            item.lastDeliveredReminderKey = reminder.key
            do { try modelContext.save() }
            catch {
                item.lastDeliveredReminderKey = previous
                didFailPersistingDelivery = true
                continue
            }
            let prepared = preparedMessages.removeValue(forKey: cacheKey)
            let decision = prepared?.shouldRemind == true ? prepared! : reminder.fallback(now: now)
            presenter.present(decision: decision, trigger: reminder.trigger, settings: settings, timestamp: now)
        }

        if !didFailPersistingDelivery {
            retryDelayIndex = 0
        }

        let nextDate = pending.map { $0.1.fireDate }.first { $0 > now }
        if let nextDate, !didFailPersistingDelivery {
            // 正常路径：单个 one-shot timer 指向最近一次未投递提醒。
            installTimer(at: nextDate)
        } else if didFailPersistingDelivery {
            scheduleRetry(now: now)
        } else {
            // 没有待提醒事项且没有重试时不装 timer，等待数据事件唤醒。
            timer?.invalidate()
            timer = nil
        }

        // Generate wording ahead of time; delivery never waits for an AI call.
        if settings.scheduledAIWordingEnabled, preparation == nil,
           let (_, reminder, cacheKey) = pending.first(where: { $0.1.fireDate > now && preparedMessages[$0.2] == nil }) {
            let id = UUID()
            preparationID = id
            preparation = Task { [weak self, engine] in
                let decision = await engine.decision(for: reminder.trigger, settings: settings, now: now)
                guard let self, !Task.isCancelled, self.preparationID == id else { return }
                if self.engine.memoryRevision == revision {
                    self.preparedMessages[cacheKey] = decision
                }
                self.preparation = nil
                self.preparationID = nil
                self.refresh()
            }
        }
    }

    /// 测试与诊断用：当前是否装有下一次到期/重试计时器。
    var isTimerArmed: Bool { timer != nil }

    private func scheduleRetry(now: Date = Date()) {
        let delay = Self.retryDelays[min(retryDelayIndex, Self.retryDelays.count - 1)]
        retryDelayIndex += 1
        installTimer(at: now.addingTimeInterval(delay))
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
