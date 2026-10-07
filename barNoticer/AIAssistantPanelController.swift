import AppKit
import Combine
import SwiftData
import SwiftUI

@MainActor
final class AIAssistantPanelController {
    private var panel: NSPanel?
    private let model: AIAssistantModel
    private let replyPresenter: any AIAssistantReplyPresenting
    private var replyCancellable: AnyCancellable?
    private var heightCancellable: AnyCancellable?
    private var screenParametersObserver: NSObjectProtocol?
    private var presentationGeneration = 0
    private(set) var isPresented = false

    init(modelContext: ModelContext, model: AIAssistantModel? = nil, replyPresenter: (any AIAssistantReplyPresenting)? = nil) {
        self.model = model ?? AIAssistantModel(modelContext: modelContext)
        self.replyPresenter = replyPresenter ?? ReminderPresenter(modelContext: modelContext)
        replyCancellable = self.model.completedReplies.sink { [weak self] reply in
            guard let self, !self.isPresented, reply.sessionID == self.model.sessionID else { return }
            self.replyPresenter.presentAssistantReply(reply) { [weak self] in
                guard let self, reply.sessionID == self.model.sessionID else { return }
                self.show()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func toggle() {
        if isPresented {
            close()
        } else {
            show()
        }
    }

    func show() {
        let assistantModel = model
        presentationGeneration += 1
        isPresented = true
        replyPresenter.dismissAssistantReply()

        let panel = panel ?? makePanel(model: assistantModel)
        self.panel = panel
        observeHeight(for: assistantModel, panel: panel)
        observeScreenChanges(panel: panel)
        resize(panel, to: AIAssistantPanelChrome.size(
            outputKind: AIAssistantPanelChrome.outputKind(response: assistantModel.response, proposals: assistantModel.proposals, state: assistantModel.state),
            hasImages: !assistantModel.images.isEmpty,
            hasImageError: assistantModel.imageInputError != nil
        ), animated: false)
        // 以当前交互屏幕为准定位；高度变化时保持底边锚定。
        center(panel)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        assistantModel.requestInputFocus()
        try? AppDebugLogStore.shared.write(
            .debug,
            category: "AIInput",
            message: "Assistant panel shown",
            metadata: ["isKeyWindow": "\(panel.isKeyWindow)", "canBecomeKey": "\(panel.canBecomeKey)"]
        )

        NSAnimationContext.runAnimation(duration: 0.18, timing: CAMediaTimingFunction(name: .easeOut)) {
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel, isPresented else { return }
        isPresented = false
        presentationGeneration += 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimation(duration: 0.14, timing: CAMediaTimingFunction(name: .easeIn)) {
            panel.animator().alphaValue = 0
        } completion: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, self.presentationGeneration == generation, !self.isPresented else { return }
                panel?.orderOut(nil)
            }
        }
    }

    func startNewConversation() {
        replyPresenter.dismissAssistantReply()
        model.startNewConversation()
    }

    private func makePanel(model: AIAssistantModel) -> NSPanel {
        AIAssistantPanelChrome.makePanel(contentView: NSHostingView(rootView: AIAssistantPanelView(
            model: model,
            close: { [weak self] in self?.close() },
            newConversation: { [weak self] in self?.startNewConversation() }
        ))) { [weak self] in
            guard self?.model.isChoosingImages != true else { return }
            guard self?.model.memoryClearConfirmation == nil else { return }
            self?.close()
        }
    }

    /// 屏幕参数变化（外接、分辨率调整）后重新执行边界约束。
    private func observeScreenChanges(panel: NSPanel) {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.isPresented else { return }
                let size = panel.frame.size
                self.resize(panel, to: size, animated: false)
            }
        }
    }

    private func observeHeight(for model: AIAssistantModel, panel: NSPanel) {
        heightCancellable = Publishers.CombineLatest3(model.$response, model.$proposals, model.$state)
            .combineLatest(model.$images, model.$imageInputError)
            .map { output, images, imageError in
                let (response, proposals, state) = output
                return AIAssistantPanelChrome.size(
                    outputKind: AIAssistantPanelChrome.outputKind(
                        response: response,
                        proposals: proposals,
                        state: state
                    ),
                    hasImages: !images.isEmpty,
                    hasImageError: imageError != nil
                )
            }
            .removeDuplicates()
            .sink { [weak self, weak panel] size in
                guard let panel else { return }
                self?.resize(panel, to: size, animated: true)
            }
    }

    private func resize(_ panel: NSPanel, to size: CGSize, animated: Bool) {
        // 尺寸限制在目标屏幕内，保留最小可用尺寸，不产生负数宽高。
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let margin: CGFloat = 12
        let clamped = CGSize(
            width: min(max(size.width, 360), screenFrame.width - margin * 2),
            height: min(max(size.height, 128), screenFrame.height - margin * 2)
        )
        // 顶部锚定：输入行位置稳定，结果区向下扩展。
        let current = panel.frame
        let next = CGRect(
            x: current.midX - clamped.width / 2,
            y: current.maxY - clamped.height,
            width: clamped.width,
            height: clamped.height
        )
        let constrained = constrain(next, to: screenFrame)
        guard panel.frame != constrained else { return }
        if animated, panel.isVisible {
            NSAnimationContext.runAnimation(duration: 0.22, timing: CAMediaTimingFunction(name: .easeInEaseOut)) {
                panel.animator().setFrame(constrained, display: true)
            }
        } else {
            panel.setFrame(constrained, display: true)
        }
    }

    private func center(_ panel: NSPanel) {
        // 使用当前交互屏幕；整个 frame 的四边限制在 visibleFrame 内，四周至少 12 pt。
        let screen = panel.screen ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let size = panel.frame.size
        let ideal = CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY + screenFrame.height * 0.12 - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(constrain(ideal, to: screenFrame), display: false)
    }

    private func constrain(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 12
        let x = min(max(frame.minX, visibleFrame.minX + margin), visibleFrame.maxX - margin - frame.width)
        let y = min(max(frame.minY, visibleFrame.minY + margin), visibleFrame.maxY - margin - frame.height)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
}

enum AIAssistantPanelChrome {
    enum OutputKind: Equatable {
        case none
        case response
        case actionConfirmation
    }

    static let compactSize = CGSize(width: 720, height: 128)
    static let responseSize = CGSize(width: 720, height: 320)
    static let expandedSize = CGSize(width: 720, height: 520)
    static let size = compactSize
    static let cornerRadius: CGFloat = 22

    static func size(hasVisibleConversation: Bool, hasTransientOutput: Bool) -> CGSize {
        hasTransientOutput ? responseSize : compactSize
    }

    static func size(hasOutput: Bool) -> CGSize {
        size(hasVisibleConversation: hasOutput, hasTransientOutput: hasOutput)
    }

    static func size(outputKind: OutputKind) -> CGSize {
        switch outputKind {
        case .none:
            return compactSize
        case .response:
            return responseSize
        case .actionConfirmation:
            return expandedSize
        }
    }

    static func size(outputKind: OutputKind, hasImages: Bool, hasImageError: Bool) -> CGSize {
        let base = size(outputKind: outputKind)
        return CGSize(width: base.width, height: base.height + (hasImages ? 76 : 0) + (hasImageError ? 28 : 0))
    }

    static func outputKind(response: String, proposals: [AIActionProposal], state: AIAssistantModel.State) -> OutputKind {
        if !proposals.isEmpty {
            return .actionConfirmation
        }

        if state.isFailure || AIVisibleResponse.hasVisibleContent(response) {
            return .response
        }

        return .none
    }

    static func makePanel(contentView: NSView, onResignFocus: (() -> Void)? = nil) -> NSPanel {
        let panel = FocusableAssistantPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.onResignFocus = onResignFocus
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 不强制外观：SwiftUI 材质与 AppKit 编辑器随系统浅/深色自适应。
        // 系统窗口阴影作为唯一阴影来源，内容层不叠加 SwiftUI 阴影。
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = contentView
        configureRoundedContentView(contentView)
        return panel
    }

    private static func configureRoundedContentView(_ contentView: NSView) {
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.layer?.cornerRadius = cornerRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class FocusableAssistantPanel: NSPanel {
    var onResignFocus: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignFocus?()
    }

    override func resignMain() {
        super.resignMain()
        onResignFocus?()
    }
}
