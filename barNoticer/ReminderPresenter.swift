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
    private var flashScreen: NSScreen?
    private var boundaryScreen: NSScreen?
    private var reminderScreen: NSScreen?
    private var reminderContent: ReminderPanelContent?
    private var flashExpansion: Double = 0
    private var boundaryExpansion: Double = 0
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
        let screen: NSScreen?
    }
    private var pendingPanels: [PendingPanel] = []

    init(
        modelContext: ModelContext,
        historyStore: ReminderHistoryStore? = nil,
        logStore: AppDebugLogStore = .shared,
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = .default,
        reduceMotion: (@MainActor () -> Bool)? = nil
    ) {
        self.modelContext = modelContext
        self.historyStore = historyStore ?? ReminderHistoryStore()
        self.logStore = logStore
        self.defaults = defaults
        self.notifications = notifications
        self.reduceMotion = reduceMotion ?? { MotionPreferences.reduceMotion }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
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
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func accessibilityChanged() {
        (boundaryPanel?.contentView as? ReminderHaloView)?.updateAppearance()
        guard let view = flashPanel?.contentView as? ReminderHaloView else { return }
        if reduceMotion(), !view.isPreview {
            flashPanel?.orderOut(nil)
            flashPanel = nil
            assistantFlashPanel = nil
            updatePopupPresence()
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
        let screen = selectedScreen()
        let reduceMotion = reduceMotion()
        if !reduceMotion {
            showFlash(expansion: settings.hotZoneFlashExpansion, screen: screen)
        }
        let delay = reduceMotion ? 0 : ReminderPresentationTiming.panelDelayAfterFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Present on this main-queue turn, as replies do, so an extra Task
            // cannot let a later reply overtake an earlier reminder.
            self.showPanel(decision: decision, entryID: entry.id, screen: screen)
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
        let screen = selectedScreen()
        let reduceMotion = reduceMotion()
        if !reduceMotion {
            showFlash(expansion: settings.hotZoneFlashExpansion, screen: screen)
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
                onOpenChat: onOpenChat,
                screen: screen
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
        updatePopupPresence()
        if isShowingAssistantReply {
            hidePanelImmediately()
            showNextPanel()
        }
    }

    private func showFlash(expansion: Double, screen: NSScreen?) {
        showFlash(expansion: expansion, screen: screen, animated: true, duration: ReminderPresentationTiming.flashDuration)
    }

    private func showBoundary(expansion: Double, screen: NSScreen?) {
        showFlash(expansion: expansion, screen: screen, animated: false, duration: nil)
    }

    private func showFlash(expansion: Double, screen: NSScreen?, animated: Bool, duration: TimeInterval?) {
        let screen = availableScreen(screen)
        let layout = IslandLayoutSettings(defaults: defaults)
        var settings = ReminderSettings(defaults: defaults)
        settings.hotZoneFlashExpansion = expansion
        let boundary = settings.haloBoundaryFrame(in: screen?.frame ?? .zero, islandLayout: layout)
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
            flashScreen = screen
            flashExpansion = expansion
            view.startPulse()
        } else {
            boundaryPanel = panel
            boundaryScreen = screen
            boundaryExpansion = expansion
        }
        panel.orderFrontRegardless()
        updatePopupPresence()

        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
                guard let self, panel === self.flashPanel else { return }
                panel?.orderOut(nil)
                self.flashPanel = nil
                self.updatePopupPresence()
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
        let screen = selectedScreen()
        if !reduceMotion { showFlash(expansion: expansion, screen: screen) }
        let delay = reduceMotion ? 0 : ReminderPresentationTiming.panelDelayAfterFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                self.showPreviewPanel(screen: screen)
            }
        }
    }

    @objc private func boundaryPreviewChanged(_ notification: Notification) {
        previewGeneration += 1
        let expansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
            ?? ReminderSettings(defaults: defaults).hotZoneFlashExpansion
        hidePanel()
        showBoundary(expansion: expansion, screen: selectedScreen())
    }

    @objc private func panelPreviewChanged() {
        boundaryPanel?.orderOut(nil)
        boundaryPanel = nil
        previewGeneration += 1
        flashPanel?.orderOut(nil)
        flashPanel = nil
        showPreviewPanel(autoClose: false, screen: selectedScreen())
    }

    @objc private func previewEnded() {
        boundaryPanel?.orderOut(nil)
        boundaryPanel = nil
        previewGeneration += 1
        flashPanel?.orderOut(nil)
        flashPanel = nil
        updatePopupPresence()
        hidePanel()
    }

    private func showPreviewPanel(autoClose: Bool = true, screen: NSScreen?) {
        hidePanelImmediately()
        let previewDecision = ReminderDecision(
            shouldRemind: true,
            message: "这是一条提醒预览。相关事项会统一放在文案下方。",
            todoReferences: [],
            snoozeSuggestion: nil
        )
        showPanel(decision: previewDecision, entryID: UUID(), autoClose: autoClose, screen: screen)
    }

    private func showPanel(decision: ReminderDecision, entryID: UUID?, autoClose: Bool = true,
                           reply: AIAssistantReply? = nil, onOpenChat: (() -> Void)? = nil, screen: NSScreen?) {
        if reminderPanel != nil {
            pendingPanels.append(PendingPanel(decision: decision, entryID: entryID, autoClose: autoClose,
                                              reply: reply, onOpenChat: onOpenChat, screen: screen))
            return
        }
        let content = ReminderPanelContent.from(message: decision.message, explicitReferences: decision.todoReferences)
        let screen = availableScreen(screen)
        let geometry = panelGeometry(on: screen, content: content)
        let frame = geometry.finalFrameInScreen

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
                topContentInset: contentTopInset(frame: frame, screen: screen),
                title: reply?.title ?? "提醒",
                reply: reply,
                openChatTitle: reply?.openButtonTitle,
                onOpenChat: onOpenChat,
                close: { [weak self] in self?.hidePanel() }
            )
        )
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        let revealView = ReminderPanelRevealView(
            frame: CGRect(origin: .zero, size: frame.size),
            contentView: hostingView,
            geometry: geometry
        )
        panel.contentView = revealView
        reminderPanel = panel
        reminderScreen = screen
        reminderContent = content
        panel.alphaValue = 1
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        updatePopupPresence()
        if reduceMotion() {
            revealView.showImmediately()
        } else {
            revealView.animateExpansion(duration: ReminderPresentationTiming.panelExpansionDuration)
        }

        if autoClose {
            let settings = ReminderSettings(defaults: defaults)
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
                self.reminderScreen = nil
                self.reminderContent = nil
                self.updatePopupPresence()
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
        reminderScreen = nil
        reminderContent = nil
        updatePopupPresence()
    }

    private func showNextPanel() {
        guard reminderPanel == nil, !pendingPanels.isEmpty else { return }
        let next = pendingPanels.removeFirst()
        showPanel(decision: next.decision, entryID: next.entryID, autoClose: next.autoClose,
                  reply: next.reply, onOpenChat: next.onOpenChat, screen: next.screen)
    }

    private func selectedScreen() -> NSScreen? {
        ScreenTargeting.currentPointerScreen()
    }

    private func availableScreen(_ screen: NSScreen?) -> NSScreen? {
        ScreenTargeting.screen(forScreenNumber: ScreenTargeting.screenNumber(of: screen)) ?? NSScreen.screens.first
    }

    private func panelGeometry(on screen: NSScreen?, content: ReminderPanelContent?) -> ReminderPanelRevealGeometry {
        let settings = ReminderSettings(defaults: defaults)
        let layout = IslandLayoutSettings(defaults: defaults)
        let screenFrame = screen?.frame ?? .zero
        var frame = settings.reminderPanelFrame(in: screenFrame, islandLayout: layout,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0)
        if let screen {
            // Keep the black crown at the screen edge, but keep controls clear of
            // the Dock and side edges. Only constrain offsets that leave the display.
            let visible = screen.visibleFrame
            let available = CGRect(x: visible.minX + 12, y: visible.minY + 12,
                width: max(1, visible.width - 24), height: max(1, screen.frame.maxY - visible.minY - 12))
            frame.size.width = min(frame.width, available.width)
            frame.size.height = min(frame.height, available.height)
            frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
        }
        if let content {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            let textHeight = ceil((content.message as NSString).boundingRect(
                with: CGSize(width: max(1, frame.width - 32), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]
            ).height)
            let cardsHeight = content.todoReferences.isEmpty ? 0 : CGFloat(content.todoReferences.count) * 66 + 20
            let inset = contentTopInset(frame: frame, screen: screen)
            let height = min(frame.height, max(144 + inset, 110 + inset + textHeight + cardsHeight))
            frame.origin.y += frame.height - height
            frame.size.height = height
        }
        return ReminderPanelRevealGeometry(
            collapsedFrameInScreen: settings.reminderCollapsedFrame(in: screenFrame, islandLayout: layout),
            finalFrameInScreen: frame
        )
    }

    private func contentTopInset(frame: CGRect, screen: NSScreen?) -> CGFloat {
        let settings = ReminderSettings(defaults: defaults)
        let safeTop = (screen?.frame.maxY ?? frame.maxY) - (screen?.safeAreaInsets.top ?? 0)
        return max(CGFloat(settings.reminderPanelTopContentInset), frame.maxY - safeTop - 16 + 8)
    }

    @objc private func screenParametersChanged() {
        if let panel = reminderPanel {
            let screen = availableScreen(reminderScreen)
            reminderScreen = screen
            let geometry = panelGeometry(on: screen, content: reminderContent)
            panel.setFrame(geometry.finalFrameInScreen, display: true)
            (panel.contentView as? ReminderPanelRevealView)?.updateGeometry(geometry,
                topContentInset: contentTopInset(frame: geometry.finalFrameInScreen, screen: screen))
        }
        for (panel, previousScreen, expansion) in [
            (flashPanel, flashScreen, flashExpansion),
            (boundaryPanel, boundaryScreen, boundaryExpansion)
        ] {
            guard let panel else { continue }
            let screen = availableScreen(previousScreen)
            var settings = ReminderSettings(defaults: defaults)
            settings.hotZoneFlashExpansion = expansion
            let boundary = settings.haloBoundaryFrame(in: screen?.frame ?? .zero,
                islandLayout: IslandLayoutSettings(defaults: defaults))
            panel.setFrame(boundary.insetBy(dx: -ReminderHaloView.drawingInset,
                dy: -ReminderHaloView.drawingInset), display: true)
            panel.contentView?.frame = CGRect(origin: .zero, size: panel.frame.size)
            if panel === flashPanel { flashScreen = screen }
            else { boundaryScreen = screen }
        }
    }

    private func updatePopupPresence() {
        NotchPopupPresence.setVisible(
            reminderPanel?.isVisible == true || flashPanel?.isVisible == true || boundaryPanel?.isVisible == true,
            owner: self
        )
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
    private var geometry: ReminderPanelRevealGeometry
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

    func updateGeometry(_ geometry: ReminderPanelRevealGeometry, topContentInset: CGFloat) {
        self.geometry = geometry
        if let hostingView = contentView as? NSHostingView<ReminderPanelView> {
            hostingView.rootView.topContentInset = topContentInset
        }
        contentView.frame = geometry.contentFrame
        maskLayer.removeAllAnimations()
        showImmediately()
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
    var topContentInset: CGFloat
    let title: String
    let reply: AIAssistantReply?
    let openChatTitle: String?
    var onOpenChat: (() -> Void)?
    var close: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var statusColor: Color { reply?.isFailure == true ? .orange : .accentColor }

    private var symbol: String {
        if reply?.isFailure == true { return "exclamationmark.triangle.fill" }
        if let reply, reply.pendingActionCount > 0 { return "checkmark.shield" }
        return reply == nil ? "bell.badge.fill" : "sparkles"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reply == nil ? Color.primary : statusColor)
                if let reply {
                    if reply.isFailure {
                        Text("未完成")
                            .foregroundStyle(statusColor)
                    } else if reply.pendingActionCount > 0 {
                        Text("\(reply.pendingActionCount) 项待确认")
                            .foregroundStyle(statusColor)
                    }
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭通知")
                .help("关闭通知")
            }
            .font(.caption)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !content.message.isEmpty {
                        Text(content.message)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !content.todoReferences.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("相关事项")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
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
            .scrollIndicators(.automatic)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("知道了", action: close)
                    .buttonStyle(.bordered)
                if let onOpenChat, let openChatTitle {
                    Button(openChatTitle) {
                        close()
                        onOpenChat()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)
        }
        .padding(.top, topContentInset)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque black keeps the crown continuous with the physical notch.
        .background(.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private func completeTodo(id: UUID) {
        do {
            try AIToolExecutor(modelContext: modelContext).apply(.completeTodo(id: id))
            if let entryID { historyStore.mark(id: entryID, status: .dismissed) }
        } catch {
            try? AppDebugLogStore.shared.write(.error, category: "Reminder", message: "Complete todo from reminder failed", metadata: ["error": error.localizedDescription, "itemID": id.uuidString])
        }
    }
}

private struct ReminderTodoCard: View {
    let todo: AIReferencedTodo
    var complete: () -> Void
    var snooze: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(todo.priority.islandColor.opacity(todo.exists ? 0.9 : 0.35))
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(todo.exists ? Color.primary : Color.secondary)
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
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("稍后") {
                snooze()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                complete()
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!todo.exists || todo.isCompleted)
            .foregroundStyle(todo.isCompleted ? Color.secondary : Color.accentColor)
            .accessibilityLabel(todo.isCompleted ? "已完成" : "完成事项")
            .help(todo.isCompleted ? "已完成" : "完成事项")
        }
        .padding(10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        }
    }
}
