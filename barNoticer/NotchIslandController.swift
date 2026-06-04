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
        installIslandPanel()
        startPointerPolling()
    }

    func showIsland() {
        guard let islandPanel else { return }
        panelState.recoverIfTransitionTimedOut(timeout: islandTransitionRecoveryTimeout)
        panelState.reconcile(isPanelVisible: islandPanel.isVisible)
        guard let transition = panelState.beginShowing() else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil

        let plan = expansionPlan()
        let contentView = islandPanel.contentView

        islandPanel.setFrame(plan.startFrame, display: true)
        islandPanel.alphaValue = 1
        contentView?.alphaValue = 1
        setIslandContentVisibility(false)
        islandPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = plan.duration
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
                    context.duration = plan.contentFadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.setIslandContentVisibility(true, animated: true)
                }
            }
        }
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

        let mouseLocation = NSEvent.mouseLocation
        let decision = IslandAutoHidePolicy.decision(
            pointerInIsland: islandPanel.frame.contains(mouseLocation),
            pointerInHotZone: hotZoneFrame().contains(mouseLocation),
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
        let plan = expansionPlan()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hideAnimation.duration
            context.timingFunction = hideAnimation.timingFunction
            self.setIslandContentVisibility(false, animated: true)
            islandPanel.animator().setFrame(plan.startFrame, display: true)
        } completionHandler: { [weak self, transition] in
            Task { @MainActor [weak self, transition] in
                guard let self, self.panelState.finishHiding(transition) else { return }
                islandPanel.orderOut(nil)
                islandPanel.setFrame(plan.endFrame, display: false)
                self.setIslandContentVisibility(true)
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

    private func pollPointerLocation() {
        guard !isPreviewingIsland else { return }
        if islandPanel == nil {
            installIslandPanel()
        }
        if pointerPollTimer?.isValid != true {
            startPointerPolling()
        }

        let mouseLocation = NSEvent.mouseLocation
        let pointerInHotZone = hotZoneFrame().contains(mouseLocation)
        let pointerInIslandFrame = panelState.shouldUseCollapsedHitTesting ? collapsedIslandFrame() : islandPanel?.frame
        let pointerInIsland = islandPanel?.isVisible == true && pointerInIslandFrame?.contains(mouseLocation) == true

        if pointerInHotZone {
            isPointerInHotZone = true
            showIsland()
            return
        }

        if isPointerInHotZone {
            isPointerInHotZone = false
            scheduleHideIsland()
            return
        }

        if islandPanel?.isVisible == true && !pointerInIsland {
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
        islandPanel?.setFrame(islandFrame(), display: true)
    }

    private func animateIslandPanelToCurrentFrameIfVisible() {
        guard let islandPanel, islandPanel.isVisible else {
            positionIslandPanel()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = resizeAnimation.duration
            context.timingFunction = resizeAnimation.timingFunction
            islandPanel.animator().setFrame(islandFrame(), display: true)
        }
    }

    private func positionHotZonePreviewPanel() {
        hotZonePreviewPanel?.setFrame(hotZoneFrame(), display: true)
        hotZonePreviewPanel?.contentView?.frame = hotZonePreviewPanel?.contentView?.bounds ?? .zero
    }

    private func hotZoneFrame() -> CGRect {
        frame { $0.hotZoneFrame(in: $1) }
    }

    private func islandFrame() -> CGRect {
        frame { $0.islandFrame(in: $1) }
    }

    private func collapsedIslandFrame() -> CGRect {
        frame { $0.collapsedIslandFrame(in: $1) }
    }

    private func expansionPlan() -> IslandExpansionPlan {
        IslandExpansionPlan(settings: layoutSettings, screenFrame: NSScreen.main?.frame ?? .zero)
    }

    private func frame(_ resolve: (IslandLayoutSettings, CGRect) -> CGRect) -> CGRect {
        resolve(layoutSettings, NSScreen.main?.frame ?? .zero)
    }

    private func setIslandContentVisibility(_ isVisible: Bool, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.24)) {
                contentVisibility.isVisible = isVisible
            }
        } else {
            contentVisibility.isVisible = isVisible
        }
    }

    @objc private func screenParametersChanged() {
        positionIslandPanel()
        positionHotZonePreviewPanel()
    }

    @objc private func layoutSettingsChanged() {
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
        showIsland()
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
        controller?.showIsland()
    }

    override func mouseExited(with event: NSEvent) {
        controller?.scheduleHideIsland()
    }
}
