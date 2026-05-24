import AppKit
import SwiftData
import SwiftUI
import UserNotifications

@MainActor
final class ReminderPresenter {
    private let modelContext: ModelContext
    private let historyStore: ReminderHistoryStore
    private let logStore: AppDebugLogStore
    private var flashPanel: NSPanel?
    private var reminderPanel: NSPanel?
    private var previewGeneration = 0

    init(
        modelContext: ModelContext,
        historyStore: ReminderHistoryStore = ReminderHistoryStore(),
        logStore: AppDebugLogStore = .shared
    ) {
        self.modelContext = modelContext
        self.historyStore = historyStore
        self.logStore = logStore

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewChanged(_:)),
            name: ReminderSettings.previewDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundaryPreviewChanged(_:)),
            name: ReminderSettings.boundaryPreviewDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelPreviewChanged),
            name: ReminderSettings.panelPreviewDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewEnded),
            name: ReminderSettings.previewDidEndNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func present(decision: ReminderDecision, trigger: ReminderTrigger, settings: ReminderSettings, timestamp: Date = Date()) {
        guard decision.shouldRemind else {
            historyStore.record(ReminderHistoryEntry(trigger: trigger, decision: decision, timestamp: timestamp, status: .skipped))
            return
        }

        let entry = ReminderHistoryEntry(trigger: trigger, decision: decision, timestamp: timestamp)
        historyStore.record(entry)
        showFlash(expansion: settings.hotZoneFlashExpansion)
        if settings.systemNotificationsEnabled {
            Task { await sendSystemNotification(decision: decision) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + ReminderPresentationTiming.panelDelayAfterFlash) { [weak self] in
            Task { @MainActor [weak self] in
                self?.showPanel(decision: decision, entryID: entry.id)
            }
        }
    }

    private func showFlash(expansion: Double) {
        showFlash(expansion: expansion, animated: true, duration: ReminderPresentationTiming.flashDuration)
    }

    private func showBoundary(expansion: Double) {
        showFlash(expansion: expansion, animated: false, duration: nil)
    }

    private func showFlash(expansion: Double, animated: Bool, duration: TimeInterval?) {
        let settings = IslandLayoutSettings(defaults: .standard)
        let hotZone = settings.hotZoneFrame(in: NSScreen.main?.frame ?? .zero)
        let frame = hotZone.insetBy(dx: -expansion, dy: -expansion)

        flashPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = ReminderFlashView(frame: CGRect(origin: .zero, size: frame.size), expansion: CGFloat(expansion))
        panel.contentView = view
        flashPanel = panel
        panel.orderFrontRegardless()
        if animated {
            view.startFlashing()
        }

        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
                guard let self, panel === self.flashPanel else { return }
                panel?.orderOut(nil)
                self.flashPanel = nil
            }
        }
    }

    @objc private func previewChanged(_ notification: Notification) {
        previewGeneration += 1
        let generation = previewGeneration
        let expansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
            ?? ReminderSettings(defaults: .standard).hotZoneFlashExpansion
        showFlash(expansion: expansion)
        DispatchQueue.main.asyncAfter(deadline: .now() + ReminderPresentationTiming.panelDelayAfterFlash) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                self.showPreviewPanel()
            }
        }
    }

    @objc private func boundaryPreviewChanged(_ notification: Notification) {
        previewGeneration += 1
        let expansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
            ?? ReminderSettings(defaults: .standard).hotZoneFlashExpansion
        hidePanel()
        showBoundary(expansion: expansion)
    }

    @objc private func panelPreviewChanged() {
        previewGeneration += 1
        flashPanel?.orderOut(nil)
        flashPanel = nil
        showPreviewPanel(autoClose: false)
    }

    @objc private func previewEnded() {
        previewGeneration += 1
        flashPanel?.orderOut(nil)
        flashPanel = nil
        hidePanel()
    }

    private func showPreviewPanel(autoClose: Bool = true) {
        let previewDecision = ReminderDecision(
            shouldRemind: true,
            message: "这是一条提醒预览。相关事项会统一放在文案下方。",
            todoReferences: [],
            snoozeSuggestion: nil
        )
        showPanel(decision: previewDecision, entryID: UUID(), autoClose: autoClose)
    }

    private func showPanel(decision: ReminderDecision, entryID: UUID, autoClose: Bool = true) {
        let content = ReminderPanelContent.from(message: decision.message, explicitReferences: decision.todoReferences)
        let layout = IslandLayoutSettings(defaults: .standard)
        let settings = ReminderSettings(defaults: .standard)
        let screenFrame = NSScreen.main?.frame ?? .zero
        let hotZone = settings.reminderCollapsedFrame(in: screenFrame, islandLayout: layout)
        let frame = settings.reminderPanelFrame(in: screenFrame, islandLayout: layout)

        hidePanelImmediately()
        let panel = ReminderPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let hostingView = NSHostingView(
            rootView: ReminderPanelView(
                content: content,
                modelContext: modelContext,
                historyStore: historyStore,
                entryID: entryID,
                close: { [weak self] in self?.hidePanel() }
            )
            .frame(width: frame.width, height: frame.height)
        )
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        let revealView = ReminderPanelRevealView(
            frame: CGRect(origin: .zero, size: frame.size),
            contentView: hostingView,
            geometry: ReminderPanelRevealGeometry(collapsedFrameInScreen: hotZone, finalFrameInScreen: frame)
        )
        panel.contentView = revealView
        reminderPanel = panel
        panel.alphaValue = 1
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        revealView.animateExpansion(duration: ReminderPresentationTiming.panelExpansionDuration)

        if autoClose {
            let closeDelay = ReminderPresentationTiming.panelExpansionDuration + ReminderPresentationTiming.panelAutoCloseDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay) { [weak self, weak panel] in
                guard let self, panel === self.reminderPanel else { return }
                self.hidePanel()
            }
        }
    }

    private func hidePanel() {
        guard let panel = reminderPanel else { return }
        let complete: () -> Void = { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, panel === self.reminderPanel else { return }
                panel?.orderOut(nil)
                self.reminderPanel = nil
            }
        }
        if let revealView = panel.contentView as? ReminderPanelRevealView {
            revealView.animateCollapse(duration: ReminderPresentationTiming.panelCollapseDuration, completion: complete)
        } else {
            complete()
        }
    }

    private func hidePanelImmediately() {
        reminderPanel?.orderOut(nil)
        reminderPanel = nil
    }

    private func sendSystemNotification(decision: ReminderDecision) async {
        do {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            let current = await center.notificationSettings()
            guard current.authorizationStatus == .authorized || current.authorizationStatus == .provisional else {
                log(.info, "Notification permission unavailable")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "barNoticer"
            content.body = ReminderPanelContent.from(message: decision.message, explicitReferences: decision.todoReferences).message
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try await center.add(request)
        } catch {
            log(.error, "System notification failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func log(_ level: AppDebugLogStore.Level, _ message: String, metadata: [String: String] = [:]) {
        try? logStore.write(level, category: "Reminder", message: message, metadata: metadata)
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ReminderPanelRevealView: NSView, CAAnimationDelegate {
    private let contentView: NSView
    private let geometry: ReminderPanelRevealGeometry
    private let maskLayer = CAShapeLayer()
    private var animationCompletion: (() -> Void)?

    init(frame frameRect: NSRect, contentView: NSView, geometry: ReminderPanelRevealGeometry) {
        self.contentView = contentView
        self.geometry = geometry
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.mask = maskLayer
        addSubview(contentView)
        maskLayer.path = path(for: geometry.collapsedFrameInContentCoordinates).cgPath
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        contentView.frame = geometry.contentFrame
    }

    func animateExpansion(duration: TimeInterval) {
        animateMask(
            from: geometry.collapsedFrameInContentCoordinates,
            to: geometry.contentFrame,
            duration: duration,
            timingFunction: CAMediaTimingFunction(controlPoints: 0.16, 0.92, 0.18, 1)
        )
    }

    func animateCollapse(duration: TimeInterval, completion: @escaping () -> Void) {
        animationCompletion = completion
        animateMask(
            from: geometry.contentFrame,
            to: geometry.collapsedFrameInContentCoordinates,
            duration: duration,
            timingFunction: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1),
            delegate: self
        )
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        let completion = animationCompletion
        animationCompletion = nil
        completion?()
    }

    private func animateMask(
        from startRect: CGRect,
        to endRect: CGRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        delegate: CAAnimationDelegate? = nil
    ) {
        let startPath = path(for: startRect).cgPath
        let endPath = path(for: endRect).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = endPath
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = startPath
        animation.toValue = endPath
        animation.duration = duration
        animation.timingFunction = timingFunction
        animation.fillMode = .both
        animation.isRemovedOnCompletion = true
        animation.delegate = delegate
        maskLayer.add(animation, forKey: "reminderPanelRevealPath")
    }

    private func path(for rect: CGRect) -> NSBezierPath {
        let radius = min(max(rect.height / 2, 16), 24)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}

private final class ReminderFlashView: NSView {
    private let expansion: CGFloat
    private var ringLayers: [CALayer] = []

    init(frame frameRect: NSRect, expansion: CGFloat) {
        self.expansion = max(0, expansion)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        ringLayers = (0..<ReminderFlashRippleStyle.ringCount).map { index in
            let ring = CALayer()
            ring.backgroundColor = NSColor.clear.cgColor
            ring.borderColor = NSColor.systemYellow.withAlphaComponent(0.88 - CGFloat(index) * 0.08).cgColor
            ring.borderWidth = 2
            ring.cornerCurve = .continuous
            ring.opacity = 0
            ring.shadowColor = NSColor.systemYellow.cgColor
            ring.shadowOpacity = 0.5
            ring.shadowRadius = 7
            ring.shadowOffset = .zero
            layer?.addSublayer(ring)
            return ring
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        for (index, ring) in ringLayers.enumerated() {
            let progress = CGFloat(index) / CGFloat(max(1, ReminderFlashRippleStyle.ringCount - 1))
            let minimumOutset = CGFloat(index) * ReminderFlashRippleStyle.minimumExpansionStep
            let outset = max(expansion * progress, minimumOutset)
            let frame = bounds.insetBy(dx: expansion - outset, dy: expansion - outset)
            ring.frame = frame
            ring.cornerRadius = min(frame.height / 2, 18 + outset * 0.42)
            ring.shadowPath = CGPath(
                roundedRect: ring.bounds,
                cornerWidth: ring.cornerRadius,
                cornerHeight: ring.cornerRadius,
                transform: nil
            )
        }
    }

    func startFlashing() {
        for (index, ring) in ringLayers.enumerated() {
            let begin = CACurrentMediaTime() + Double(index) * ReminderFlashRippleStyle.staggerDelay

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.96, 0.58, 0.18, 0]
            opacity.keyTimes = [0, 0.16, 0.44, 0.74, 1]
            opacity.duration = ReminderFlashRippleStyle.pulseDuration
            opacity.beginTime = begin
            opacity.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
            opacity.fillMode = .both
            opacity.isRemovedOnCompletion = false

            let width = CAKeyframeAnimation(keyPath: "borderWidth")
            width.values = [1.1, 3.2, 2.1, 0.8]
            width.keyTimes = [0, 0.22, 0.62, 1]
            width.duration = ReminderFlashRippleStyle.pulseDuration
            width.beginTime = begin
            width.fillMode = .both
            width.isRemovedOnCompletion = false

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.98
            scale.toValue = 1.035
            scale.duration = ReminderFlashRippleStyle.pulseDuration
            scale.beginTime = begin
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scale.fillMode = .both
            scale.isRemovedOnCompletion = false

            ring.add(opacity, forKey: "reminderRippleOpacity")
            ring.add(width, forKey: "reminderRippleWidth")
            ring.add(scale, forKey: "reminderRippleScale")
        }
    }
}

private struct ReminderPanelView: View {
    let content: ReminderPanelContent
    let modelContext: ModelContext
    let historyStore: ReminderHistoryStore
    let entryID: UUID
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("提醒", systemImage: "bell.badge.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.96))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.74))
            }

            if !content.message.isEmpty {
                Text(content.message)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.todoReferences.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("相关事项")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.76))
                    ForEach(content.todoReferences, id: \.self) { id in
                        ReminderTodoCard(todo: referencedTodo(id: id)) {
                            completeTodo(id: id)
                        } snooze: {
                            historyStore.mark(id: entryID, status: .snoozed)
                            close()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 30, y: 16)
        .environment(\.colorScheme, .dark)
    }

    private func referencedTodo(id: UUID) -> AIReferencedTodo {
        guard let item = (try? modelContext.fetch(FetchDescriptor<TodoItem>()))?.first(where: { $0.id == id }) else {
            return AIReferencedTodo(id: id, title: "事项", priority: .low, groupName: nil, scheduleText: nil, createdAt: nil, isCompleted: false, exists: false)
        }
        let groups = (try? modelContext.fetch(FetchDescriptor<TodoGroup>())) ?? []
        let group = TodoGroupResolver.group(for: item, groups: groups)
        return AIReferencedTodo(id: id, title: item.title, priority: item.priority, groupName: group.name, scheduleText: TodoDeadlineFormatter.cardText(for: item), createdAt: item.createdAt, isCompleted: item.isCompleted, exists: true)
    }

    private func completeTodo(id: UUID) {
        try? AIToolExecutor(modelContext: modelContext).apply(.completeTodo(id: id))
        historyStore.mark(id: entryID, status: .dismissed)
    }
}

private struct ReminderTodoCard: View {
    let todo: AIReferencedTodo
    var complete: () -> Void
    var snooze: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(todo.priority.islandColor.opacity(todo.exists ? 1 : 0.38))
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(todo.exists ? 0.96 : 0.72))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(todo.exists ? "\(todo.priority.title)重要性" : "事项不存在")
                    if let groupName = todo.groupName {
                        Text(groupName)
                    }
                    if let scheduleText = todo.scheduleText {
                        Text(scheduleText)
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
            }

            Spacer(minLength: 8)

            Button("稍后") {
                snooze()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.white.opacity(0.13), in: Capsule())

            Button {
                complete()
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "checkmark")
                    .font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!todo.exists || todo.isCompleted)
            .foregroundStyle(.white.opacity(0.94))
            .padding(7)
            .background(todo.priority.islandColor.opacity(0.86), in: Circle())
        }
        .padding(10)
        .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(todo.priority.islandColor.opacity(todo.exists ? 0.48 : 0.18), lineWidth: 1)
        }
    }
}
