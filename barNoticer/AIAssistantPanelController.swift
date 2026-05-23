import AppKit
import Combine
import SwiftData
import SwiftUI

@MainActor
final class AIAssistantPanelController {
    private let modelContext: ModelContext
    private var panel: NSPanel?
    private var model: AIAssistantModel?
    private var heightCancellable: AnyCancellable?
    private var isClosing = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let assistantModel = model ?? AIAssistantModel(modelContext: modelContext)
        assistantModel.resetTransientOutput()
        model = assistantModel

        let panel = panel ?? makePanel(model: assistantModel)
        self.panel = panel
        isClosing = false
        observeHeight(for: assistantModel, panel: panel)
        resize(panel, to: AIAssistantPanelChrome.size(hasVisibleConversation: assistantModel.hasVisibleConversation, hasTransientOutput: assistantModel.hasTransientOutput), animated: false)
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

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel else { return }
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.model?.resetSessionForContextRefresh()
                self?.isClosing = false
            }
        }
    }

    private func makePanel(model: AIAssistantModel) -> NSPanel {
        AIAssistantPanelChrome.makePanel(contentView: NSHostingView(rootView: AIAssistantPanelView(model: model) { [weak self] in
            self?.close()
        })) { [weak self] in
            self?.close()
        }
    }

    private func observeHeight(for model: AIAssistantModel, panel: NSPanel) {
        heightCancellable = Publishers.CombineLatest3(model.$response, model.$proposals, model.$state)
            .map { response, proposals, state in
                AIAssistantPanelChrome.size(
                    outputKind: AIAssistantPanelChrome.outputKind(
                        response: response,
                        proposals: proposals,
                        state: state
                    )
                )
            }
            .removeDuplicates()
            .sink { [weak self, weak panel] size in
                guard let panel else { return }
                self?.resize(panel, to: size, animated: true)
            }
    }

    private func resize(_ panel: NSPanel, to size: CGSize, animated: Bool) {
        guard panel.frame.size != size else { return }
        let current = panel.frame
        let next = CGRect(
            x: current.midX - size.width / 2,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(next, display: true)
            }
        } else {
            panel.setFrame(next, display: true)
        }
    }

    private func center(_ panel: NSPanel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY + screenFrame.height * 0.12
        ))
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
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
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
        contentView.appearance = NSAppearance(named: .darkAqua)
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
