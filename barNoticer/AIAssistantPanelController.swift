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
        resize(panel, to: AIAssistantPanelChrome.size(
            outputKind: AIAssistantPanelChrome.outputKind(response: assistantModel.response, proposals: assistantModel.proposals, state: assistantModel.state),
            hasImages: !assistantModel.images.isEmpty,
            hasImageError: assistantModel.imageInputError != nil
        ), animated: false)
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
        guard let panel, isPresented else { return }
        isPresented = false
        presentationGeneration += 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
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
