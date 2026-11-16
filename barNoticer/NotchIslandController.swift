import AppKit
import SwiftData
import SwiftUI

@MainActor
final class NotchIslandController: NSObject {
    private let modelContainer: ModelContainer
    private var islandPanel: NSPanel?
    private var mainWindow: NSWindow?
    private var hotZonePreviewPanel: NSPanel?
    private var pointerPollTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var isPointerInHotZone = false
    private var layoutSettings = IslandLayoutSettings(defaults: .standard)
    private var isPreviewingIsland = false
    private var activeScreenNumber: NSNumber?
    private var previewScreenNumber: NSNumber?
    private var lastPolledMouseLocation: NSPoint?
    private var panelState = IslandPanelState()
    private let contentVisibility = IslandContentVisibilityModel()
    private let showTimingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.92, 0.18, 1)
    private let resizeAnimation = IslandAnimation(
        duration: IslandAnimationTimings.modeSwitchDuration,
        timingFunction: CAMediaTimingFunction(controlPoints: 0.16, 0.92, 0.18, 1)
    )
    private let hideAnimation = IslandAnimation(
        duration: 0.34,
        timingFunction: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
    )

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        super.init()

        NotificationCenter.default.addObserver(
            self, selector: #selector(popupPresenceChanged),
            name: NotchPopupPresence.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutSettingsChanged),
            name: IslandLayoutSettings.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutPreviewChanged(_:)),
            name: IslandLayoutSettings.previewDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutPreviewEnded),
            name: IslandLayoutSettings.previewDidEndNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pointerPollTimer?.invalidate()
    }

    func start() {
        startPointerPolling()
    }

    func showIsland() {
        showIsland(on: ScreenTargeting.currentPointerScreen())
    }

    private func showIsland(on screen: NSScreen?) {
        guard !NotchPopupPresence.isPresenting else { return }
        if islandPanel == nil {
            installIslandPanel()
        }
        guard let islandPanel else { return }
        panelState.recoverIfTransitionTimedOut(timeout: islandTransitionRecoveryTimeout)
        panelState.reconcile(isPanelVisible: islandPanel.isVisible)
        guard let transition = panelState.beginShowing() else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        activeScreenNumber = ScreenTargeting.screenNumber(of: screen ?? ScreenTargeting.currentPointerScreen())

        let plan = expansionPlan(on: currentActiveScreen())
        let contentView = islandPanel.contentView

        islandPanel.setFrame(plan.startFrame, display: true)
        islandPanel.alphaValue = 1
        contentView?.alphaValue = 1
        setIslandContentVisibility(false)
        islandPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionPreferences.reduceMotion ? 0 : plan.duration
            context.timingFunction = showTimingFunction
            islandPanel.animator().setFrame(plan.endFrame, display: true)
        } completionHandler: { [weak self, transition] in
            Task { @MainActor [weak self, transition] in
                guard let self, self.panelState.finishShowing(transition) else { return }
                self.setIslandContentVisibility(true)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + plan.contentFadeDelay) { [weak self, weak islandPanel, transition] in
            Task { @MainActor [weak self, weak islandPanel, transition] in
                guard let self, islandPanel === self.islandPanel, self.panelState.isCurrentTransition(transition) else {
                    return
                }

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = MotionPreferences.reduceMotion ? 0 : plan.contentFadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.setIslandContentVisibility(true, animated: !MotionPreferences.reduceMotion)
                }
            }
        }
    }

    fileprivate func pointerEnteredIsland(_ window: NSWindow?) {
        // Tracking events may outlive the panel. Only the hot zone (or preview)
        // may open it; entering the current panel only cancels a pending hide.
        guard let islandPanel, window === islandPanel, islandPanel.isVisible,
              !panelState.isClosing else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    func scheduleHideIsland() {
        guard hideWorkItem == nil else { return }

        hideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideIslandIfPointerOutside()
            }
        }

        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }

    private func hideIslandIfPointerOutside() {
        hideWorkItem = nil
        guard let islandPanel else { return }
        guard !panelState.shouldUseCollapsedHitTesting else { return }

        let screen = currentActiveScreen()
        let mouseLocation = NSEvent.mouseLocation
        let decision = IslandAutoHidePolicy.decision(
            pointerInIsland: islandPanel.frame.contains(mouseLocation),
            pointerInHotZone: hotZoneFrame(on: screen).contains(mouseLocation),
            isPreviewingIsland: isPreviewingIsland
        )

        guard decision.shouldHide else {
            return
        }

        if decision.shouldEndEditing {
            islandPanel.endEditing(for: nil)
            islandPanel.makeFirstResponder(nil)
        }

        let transition = panelState.beginHiding(suppressShowingDuration: hideAnimation.duration + hideInterruptionSuppression)
        let plan = expansionPlan(on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionPreferences.reduceMotion ? 0 : hideAnimation.duration
            context.timingFunction = hideAnimation.timingFunction
            self.setIslandContentVisibility(false, animated: !MotionPreferences.reduceMotion)
            islandPanel.animator().setFrame(plan.startFrame, display: true)
        } completionHandler: { [weak self, transition] in
            Task { @MainActor [weak self, transition] in
                guard let self, self.panelState.finishHiding(transition) else { return }
                islandPanel.orderOut(nil)
                islandPanel.setFrame(plan.endFrame, display: false)
                self.setIslandContentVisibility(true)
                self.activeScreenNumber = nil
                self.lastPolledMouseLocation = nil
                if islandPanel === self.islandPanel {
                    self.islandPanel = nil
                }
            }
        }
    }

    private func installIslandPanel() {
        let panel = InteractiveIslandPanel(
            contentRect: islandFrame(),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = IslandPanelPresentation.collectionBehavior
        panel.alphaValue = 0
        let hostingView = IslandTrackingHostingView(
            rootView: IslandSummaryView(openMainWindow: { [weak self] in
                self?.openMainWindow()
            })
            .modelContainer(modelContainer)
            .environmentObject(contentVisibility),
            controller: self
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 30
        hostingView.layer?.cornerCurve = .continuous

        panel.contentView = hostingView

        islandPanel = panel
    }

    private func installHotZonePreviewPanelIfNeeded() {
        guard hotZonePreviewPanel == nil else { return }

        let panel = NSPanel(
            contentRect: hotZoneFrame(),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = IslandPanelPresentation.collectionBehavior
        panel.contentView = HotZonePreviewView(frame: panel.contentView?.bounds ?? .zero)
        hotZonePreviewPanel = panel
    }

    private func startPointerPolling() {
        pointerPollTimer?.invalidate()

        let timer = Timer(
            timeInterval: 0.12,
            target: self,
            selector: #selector(pointerPollTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        pointerPollTimer = timer
    }

    @objc private func pointerPollTimerFired(_ timer: Timer) {
        pollPointerLocation()
    }

    @objc private func popupPresenceChanged() {
        guard NotchPopupPresence.isPresenting else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isPointerInHotZone = false
        isPreviewingIsland = false
        activeScreenNumber = nil
        lastPolledMouseLocation = nil
        guard let islandPanel else { return }
        let transition = panelState.beginHiding(suppressShowingDuration: 0)
        _ = panelState.finishHiding(transition)
        islandPanel.orderOut(nil)
        self.islandPanel = nil
        setIslandContentVisibility(true)
    }

    private func pollPointerLocation() {
        guard !isPreviewingIsland, !NotchPopupPresence.isPresenting else { return }
        if pointerPollTimer?.isValid != true {
            startPointerPolling()
        }

        let mouseLocation = NSEvent.mouseLocation
        let isVisible = islandPanel?.isVisible == true
        // 指针静止且面板处于收起空闲态时跳过屏幕遍历与矩形计算。
        if !isVisible, !isPointerInHotZone, lastPolledMouseLocation == mouseLocation {
            return
        }
        lastPolledMouseLocation = mouseLocation

        let targetScreen = isVisible
            ? currentActiveScreen()
            : ScreenTargeting.screen(at: mouseLocation)
        let pointerInHotZone = hotZoneFrame(on: targetScreen).contains(mouseLocation)
        let pointerInIslandFrame = panelState.shouldUseCollapsedHitTesting
            ? collapsedIslandFrame(on: targetScreen)
            : islandPanel?.frame
        let pointerInIsland = isVisible && pointerInIslandFrame?.contains(mouseLocation) == true

        if pointerInHotZone {
            isPointerInHotZone = true
            showIsland(on: targetScreen)
            return
        }

        if isPointerInHotZone {
            isPointerInHotZone = false
            scheduleHideIsland()
            return
        }

        if isVisible && !pointerInIsland {
            scheduleHideIsland()
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = existingMainWindow() {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "barNoticer"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: ContentView()
                .modelContainer(modelContainer)
        )
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func existingMainWindow() -> NSWindow? {
        if let mainWindow, mainWindow.isVisible {
            return mainWindow
        }

        return NSApp.windows.first { window in
            Self.shouldReuseAsMainWindow(window)
        }
    }

    static func shouldReuseAsMainWindow(_ window: NSWindow) -> Bool {
        !window.isKind(of: NSPanel.self) && window.styleMask.contains(.titled)
    }

    private func positionIslandPanel() {
        islandPanel?.setFrame(islandFrame(on: currentActiveScreen()), display: true)
    }

    private func animateIslandPanelToCurrentFrameIfVisible() {
        guard let islandPanel, islandPanel.isVisible else {
            positionIslandPanel()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionPreferences.reduceMotion ? 0 : resizeAnimation.duration
            context.timingFunction = resizeAnimation.timingFunction
            islandPanel.animator().setFrame(islandFrame(on: currentActiveScreen()), display: true)
        }
    }

    private func positionHotZonePreviewPanel() {
        hotZonePreviewPanel?.setFrame(hotZoneFrame(on: currentPreviewScreen()), display: true)
        hotZonePreviewPanel?.contentView?.frame = hotZonePreviewPanel?.contentView?.bounds ?? .zero
    }

    private func hotZoneFrame(on screen: NSScreen? = nil) -> CGRect {
        frame(on: screen) { $0.hotZoneFrame(in: $1) }
    }

    private func islandFrame(on screen: NSScreen? = nil) -> CGRect {
        frame(on: screen) { $0.islandFrame(in: $1) }
    }

    private func collapsedIslandFrame(on screen: NSScreen? = nil) -> CGRect {
        frame(on: screen) { $0.collapsedIslandFrame(in: $1) }
    }

    private func expansionPlan(on screen: NSScreen? = nil) -> IslandExpansionPlan {
        IslandExpansionPlan(settings: layoutSettings, screenFrame: (screen ?? currentActiveScreen())?.frame ?? .zero)
    }

    private func frame(on screen: NSScreen? = nil, _ resolve: (IslandLayoutSettings, CGRect) -> CGRect) -> CGRect {
        resolve(layoutSettings, (screen ?? currentActiveScreen())?.frame ?? .zero)
    }

    private func currentActiveScreen() -> NSScreen? {
        ScreenTargeting.resolvedScreen(pinnedNumber: &activeScreenNumber)
    }

    private func currentPreviewScreen() -> NSScreen? {
        if let screen = ScreenTargeting.screen(forScreenNumber: previewScreenNumber) {
            return screen
        }
        let preferred = mainWindow?.screen ?? NSApp.keyWindow?.screen ?? ScreenTargeting.currentPointerScreen()
        previewScreenNumber = ScreenTargeting.screenNumber(of: preferred)
        return preferred
    }

    private func setIslandContentVisibility(_ isVisible: Bool, animated: Bool = false) {
        if animated, !MotionPreferences.reduceMotion {
            withAnimation(.easeOut(duration: 0.24)) {
                contentVisibility.isVisible = isVisible
            }
        } else {
            contentVisibility.isVisible = isVisible
        }
    }

    @objc private func screenParametersChanged() {
        lastPolledMouseLocation = nil
        positionIslandPanel()
        positionHotZonePreviewPanel()
    }

    @objc private func layoutSettingsChanged() {
        lastPolledMouseLocation = nil
        layoutSettings = IslandLayoutSettings(defaults: .standard)
        animateIslandPanelToCurrentFrameIfVisible()
        positionHotZonePreviewPanel()
    }

    @objc private func layoutPreviewChanged(_ notification: Notification) {
        let rawValue = notification.userInfo?[IslandLayoutSettings.previewKindUserInfoKey] as? String
        guard let rawValue, let previewKind = IslandLayoutSettings.PreviewKind(rawValue: rawValue) else {
            return
        }

        switch previewKind {
        case .hotZone:
            showHotZonePreview()
        case .island:
            showIslandPreview()
        }
    }

    @objc private func layoutPreviewEnded() {
        hideHotZonePreview()
        previewScreenNumber = nil
        if isPreviewingIsland {
            isPreviewingIsland = false
            scheduleHideIsland()
        }
    }

    private func showHotZonePreview() {
        installHotZonePreviewPanelIfNeeded()
        positionHotZonePreviewPanel()
        hotZonePreviewPanel?.orderFrontRegardless()
    }

    private func hideHotZonePreview() {
        hotZonePreviewPanel?.orderOut(nil)
    }

    private func showIslandPreview() {
        hideHotZonePreview()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isPreviewingIsland = true
        showIsland(on: currentPreviewScreen())
    }
}

private struct IslandAnimation {
    let duration: TimeInterval
    let timingFunction: CAMediaTimingFunction
}

private let islandTransitionRecoveryTimeout: TimeInterval = 2.0
private let hideInterruptionSuppression: TimeInterval = 0.3

enum IslandPanelPresentation {
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]
}

private final class InteractiveIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HotZonePreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.86).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class IslandTrackingHostingView<Content: View>: NSHostingView<Content> {
    private weak var controller: NotchIslandController?
    private var trackingAreaRef: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    init(rootView: Content, controller: NotchIslandController) {
        self.controller = controller
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerEnteredIsland(window)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.scheduleHideIsland()
    }
}
