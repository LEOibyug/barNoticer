import AppKit
import SwiftData
import SwiftUI
import UserNotifications

@MainActor
final class ReminderPresenter: AIAssistantReplyPresenting, ReminderPresenting {
    private let modelContext: ModelContext
    private let historyStore: ReminderHistoryStore
    private let logStore: AppDebugLogStore
    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private let reduceMotion: @MainActor () -> Bool
    private var flashPanel: NSPanel?
    private var boundaryPanel: NSPanel?
    private var reminderPanel: NSPanel?
    private var previewGeneration = 0
    private var pendingAssistantReplyID: UUID?
    private var isShowingAssistantReply = false
    private weak var assistantFlashPanel: NSPanel?
    private struct PendingPanel {
        let decision: ReminderDecision
        let entryID: UUID?
        let autoClose: Bool
        let reply: AIAssistantReply?
        let onOpenChat: (() -> Void)?
    }
    private var pendingPanels: [PendingPanel] = []

    init(
        modelContext: ModelContext,
        historyStore: ReminderHistoryStore = ReminderHistoryStore(),
        logStore: AppDebugLogStore = .shared,
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = .default,
        reduceMotion: @escaping @MainActor () -> Bool = { MotionPreferences.reduceMotion }
    ) {
        self.modelContext = modelContext
        self.historyStore = historyStore
        self.logStore = logStore
        self.defaults = defaults
        self.notifications = notifications
        self.reduceMotion = reduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )

        notifications.addObserver(
            self,
            selector: #selector(previewChanged(_:)),
            name: ReminderSettings.previewDidChangeNotification,
            object: nil
        )
        notifications.addObserver(
            self,
            selector: #selector(boundaryPreviewChanged(_:)),
            name: ReminderSettings.boundaryPreviewDidChangeNotification,
            object: nil
        )
        notifications.addObserver(
            self,
            selector: #selector(panelPreviewChanged),
            name: ReminderSettings.panelPreviewDidChangeNotification,
            object: nil
        )
        notifications.addObserver(
            self,
            selector: #selector(previewEnded),
            name: ReminderSettings.previewDidEndNotification,
            object: nil
        )
    }

    deinit {
        notifications.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func accessibilityChanged() {
        (boundaryPanel?.contentView as? ReminderHaloView)?.updateAppearance()
        guard let view = flashPanel?.contentView as? ReminderHaloView else { return }
        if reduceMotion(), !view.isPreview {
            flashPanel?.orderOut(nil)
            flashPanel = nil
            assistantFlashPanel = nil
        } else {
            view.updateAppearance()
        }
    }

    func present(decision: ReminderDecision, trigger: ReminderTrigger, settings: ReminderSettings, timestamp: Date = Date()) {
        guard decision.shouldRemind else {
            historyStore.record(ReminderHistoryEntry(trigger: trigger, decision: decision, timestamp: timestamp, status: .skipped))
            return
        }

        let entry = ReminderHistoryEntry(trigger: trigger, decision: decision, timestamp: timestamp)
        historyStore.record(entry)
        // 先展示光晕再出现内容；减少动态效果时不做光效、无人为等待。
        let reduceMotion = reduceMotion()
        if !reduceMotion {
            showFlash(expansion: settings.hotZoneFlashExpansion)
        }
        let delay = reduceMotion ? 0 : ReminderPresentationTiming.panelDelayAfterFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Present on this main-queue turn, as replies do, so an extra Task
            // cannot let a later reply overtake an earlier reminder.
            self.showPanel(decision: decision, entryID: entry.id)
            if settings.systemNotificationsEnabled {
                Task { await self.sendSystemNotification(decision: decision) }
            }
        }
    }

    func presentAssistantReply(_ reply: AIAssistantReply, onOpenChat: @escaping () -> Void) {
        dismissAssistantReply()
        let id = UUID()
        pendingAssistantReplyID = id
        let settings = ReminderSettings(defaults: defaults)
        let reduceMotion = reduceMotion()
        if !reduceMotion {
            showFlash(expansion: settings.hotZoneFlashExpansion)
        }
        assistantFlashPanel = flashPanel
        let delay = reduceMotion ? 0 : ReminderPresentationTiming.panelDelayAfterFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingAssistantReplyID == id else { return }
            self.pendingAssistantReplyID = nil
            self.showPanel(
                decision: ReminderDecision(shouldRemind: true, message: reply.message, todoReferences: [], snoozeSuggestion: nil),
                entryID: nil,
                reply: reply,
                onOpenChat: onOpenChat
            )
        }
    }

    func dismissAssistantReply() {
        pendingAssistantReplyID = nil
        pendingPanels.removeAll { $0.reply != nil }
        if let assistantFlashPanel, assistantFlashPanel === flashPanel {
            assistantFlashPanel.orderOut(nil)
            flashPanel = nil
        }
        assistantFlashPanel = nil
        if isShowingAssistantReply {
            hidePanelImmediately()
            showNextPanel()
        }
    }

    private func showFlash(expansion: Double) {
        showFlash(expansion: expansion, animated: true, duration: ReminderPresentationTiming.flashDuration)
    }

    private func showBoundary(expansion: Double) {
        showFlash(expansion: expansion, animated: false, duration: nil)
    }

    private func showFlash(expansion: Double, animated: Bool, duration: TimeInterval?) {
        let layout = IslandLayoutSettings(defaults: defaults)
        var settings = ReminderSettings(defaults: defaults)
        settings.hotZoneFlashExpansion = expansion
        let boundary = settings.haloBoundaryFrame(in: NSScreen.main?.frame ?? .zero, islandLayout: layout)
        let frame = boundary.insetBy(dx: -ReminderHaloView.drawingInset, dy: -ReminderHaloView.drawingInset)

        if animated { flashPanel?.orderOut(nil) }
        else { boundaryPanel?.orderOut(nil) }
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = ReminderHaloView(frame: CGRect(origin: .zero, size: frame.size), isPreview: !animated,
            cornerRadius: settings.haloBoundary.isCustom ? settings.haloBoundary.cornerRadius : 24)
        panel.contentView = view
        if animated {
            flashPanel = panel
            view.startPulse()
        } else {
            boundaryPanel = panel
        }
        panel.orderFrontRegardless()

        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
                guard let self, panel === self.flashPanel else { return }
                panel?.orderOut(nil)
                self.flashPanel = nil
            }
        }
    }

    @objc private func previewChanged(_ notification: Notification) {
        // Replaying an example must not leave the previous content over the new halo.
        hidePanelImmediately()
        previewGeneration += 1
        let generation = previewGeneration
        let expansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
            ?? ReminderSettings(defaults: defaults).hotZoneFlashExpansion
        let reduceMotion = reduceMotion()
        if !reduceMotion { showFlash(expansion: expansion) }
        let delay = reduceMotion ? 0 : ReminderPresentationTiming.panelDelayAfterFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                self.showPreviewPanel()
            }
        }
    }

    @objc private func boundaryPreviewChanged(_ notification: Notification) {
        previewGeneration += 1
        let expansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
            ?? ReminderSettings(defaults: defaults).hotZoneFlashExpansion
        hidePanel()
        showBoundary(expansion: expansion)
    }

    @objc private func panelPreviewChanged() {
        boundaryPanel?.orderOut(nil)
        boundaryPanel = nil
        previewGeneration += 1
        flashPanel?.orderOut(nil)
        flashPanel = nil
        showPreviewPanel(autoClose: false)
    }

    @objc private func previewEnded() {
        boundaryPanel?.orderOut(nil)
        boundaryPanel = nil
        previewGeneration += 1
        flashPanel?.orderOut(nil)
        flashPanel = nil
        hidePanel()
    }

    private func showPreviewPanel(autoClose: Bool = true) {
        hidePanelImmediately()
        let previewDecision = ReminderDecision(
            shouldRemind: true,
            message: "这是一条提醒预览。相关事项会统一放在文案下方。",
            todoReferences: [],
            snoozeSuggestion: nil
        )
        showPanel(decision: previewDecision, entryID: UUID(), autoClose: autoClose)
    }

    private func showPanel(decision: ReminderDecision, entryID: UUID?, autoClose: Bool = true,
                           reply: AIAssistantReply? = nil, onOpenChat: (() -> Void)? = nil) {
        if reminderPanel != nil {
            pendingPanels.append(PendingPanel(decision: decision, entryID: entryID, autoClose: autoClose,
                                              reply: reply, onOpenChat: onOpenChat))
            return
        }
        let content = ReminderPanelContent.from(message: decision.message, explicitReferences: decision.todoReferences)
        let layout = IslandLayoutSettings(defaults: .standard)
        let settings = ReminderSettings(defaults: defaults)
        let screen = NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let safeAreaTop = screen?.safeAreaInsets.top ?? 0
        let hotZone = settings.reminderCollapsedFrame(in: screenFrame, islandLayout: layout)
        let frame = settings.reminderPanelFrame(in: screenFrame, islandLayout: layout, safeAreaTop: safeAreaTop)

        hidePanelImmediately()
        isShowingAssistantReply = reply != nil
        let panel = ReminderPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.title = reply?.title ?? "提醒"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let hostingView = NSHostingView(
            rootView: ReminderPanelView(
                content: content,
                modelContext: modelContext,
                historyStore: historyStore,
                entryID: entryID,
                topContentInset: settings.reminderContentTopInset(safeAreaTop: safeAreaTop),
                title: reply?.title ?? "提醒",
                symbol: reply == nil ? "bell.badge.fill" : "sparkles",
                openChatTitle: reply?.openButtonTitle,
                onOpenChat: onOpenChat,
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
        if reduceMotion() {
            revealView.showImmediately()
        } else {
            revealView.animateExpansion(duration: ReminderPresentationTiming.panelExpansionDuration)
        }

        if autoClose {
            let closeDelay = ReminderPresentationTiming.panelExpansionDuration + settings.reminderPanelAutoCloseDelay
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
                self.isShowingAssistantReply = false
                self.showNextPanel()
            }
        }
        if reduceMotion() {
            complete()
        } else if let revealView = panel.contentView as? ReminderPanelRevealView {
            revealView.animateCollapse(duration: ReminderPresentationTiming.panelCollapseDuration, completion: complete)
        } else {
            complete()
        }
    }

    private func hidePanelImmediately() {
        reminderPanel?.orderOut(nil)
        reminderPanel = nil
        isShowingAssistantReply = false
    }

    private func showNextPanel() {
        guard reminderPanel == nil, !pendingPanels.isEmpty else { return }
        let next = pendingPanels.removeFirst()
        showPanel(decision: next.decision, entryID: next.entryID, autoClose: next.autoClose,
                  reply: next.reply, onOpenChat: next.onOpenChat)
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

    /// 减少动态效果：直接呈现最终形状，不播放路径揭幕。
    func showImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path(for: geometry.contentFrame).cgPath
        CATransaction.commit()
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

private struct ReminderPanelView: View {
    let content: ReminderPanelContent
    let modelContext: ModelContext
    let historyStore: ReminderHistoryStore
    let entryID: UUID?
    let topContentInset: CGFloat
    let title: String
    let symbol: String
    let openChatTitle: String?
    var onOpenChat: (() -> Void)?
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
                            let todoMap = AITodoLookup.referencedTodoMap(ids: content.todoReferences, in: modelContext)
                            ForEach(content.todoReferences, id: \.self) { id in
                                ReminderTodoCard(todo: todoMap[id] ?? .missing(id: id)) {
                                    completeTodo(id: id)
                                } snooze: {
                                    if let entryID { historyStore.mark(id: entryID, status: .snoozed) }
                                    close()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("知道了", action: close)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.18))
                if let onOpenChat, let openChatTitle {
                    Button(openChatTitle) {
                        close()
                        onOpenChat()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.top, topContentInset)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private func completeTodo(id: UUID) {
        try? AIToolExecutor(modelContext: modelContext).apply(.completeTodo(id: id))
        if let entryID { historyStore.mark(id: entryID, status: .dismissed) }
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
