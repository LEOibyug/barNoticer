import AppKit
import SwiftUI

final class TransparentPromptField: NSTextField {
    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    private func configure() {
        isBordered = false
        isBezeled = false
        drawsBackground = false
        backgroundColor = .clear
        textColor = .white
        font = .systemFont(ofSize: 18, weight: .medium)
        placeholderString = nil
        isEditable = true
        isSelectable = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        refusesFirstResponder = false
    }
}

enum PromptPlaceholderVisibility {
    static func shouldShowPlaceholder(text: String, isComposingText: Bool) -> Bool {
        text.isEmpty && !isComposingText
    }
}

struct TransparentPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposingText: Bool
    var focusRequestID: UUID
    var onSubmit: () -> Void
    var onPasteImages: ((NSPasteboard) -> Bool)? = nil

    func makeNSView(context: Context) -> TransparentPromptField {
        let field = TransparentPromptField()
        let cell = ImagePromptCell(textCell: "")
        cell.imageEditor.onPasteImages = onPasteImages
        field.cell = cell
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 18, weight: .medium)
        field.textColor = .white
        field.isEditable = true
        field.isSelectable = true
        cell.isScrollable = true
        cell.wraps = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.stringValue = text
        // Keep the placeholder inside AppKit's text system so marked text
        // hides it even before the input method updates the SwiftUI bindings.
        field.placeholderAttributedString = NSAttributedString(
            string: "询问 AI，或写下当日总结",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(AIAssistantPanelStyle.secondaryTextOpacity)
            ]
        )
        return field
    }

    func updateNSView(_ field: TransparentPromptField, context: Context) {
        (field.cell as? ImagePromptCell)?.imageEditor.onPasteImages = onPasteImages
        field.isEditable = context.environment.isEnabled
        Self.synchronize(field, with: text)
        guard let window = field.window else { return }
        guard context.coordinator.shouldRequestFocus(focusRequestID) else { return }

        DispatchQueue.main.async {
            if window.makeFirstResponder(field) {
                context.coordinator.markFocusRequestHandled(focusRequestID)
                try? AppDebugLogStore.shared.write(.debug, category: "AIInput", message: "Prompt field became first responder")
            } else {
                try? AppDebugLogStore.shared.write(.error, category: "AIInput", message: "Prompt field failed to become first responder")
            }
        }
    }

    static func synchronize(_ field: TransparentPromptField, with text: String) {
        // The binding contains committed text; replacing the editor's value
        // here would discard the input method's in-progress composition.
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text {
            field.stringValue = text
        }
        field.textColor = .white
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isComposingText: $isComposingText, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var isComposingText: Bool
        let onSubmit: () -> Void
        private var handledFocusRequestID: UUID?

        init(text: Binding<String>, isComposingText: Binding<Bool>, onSubmit: @escaping () -> Void) {
            _text = text
            _isComposingText = isComposingText
            self.onSubmit = onSubmit
        }

        func shouldRequestFocus(_ id: UUID) -> Bool {
            handledFocusRequestID != id
        }

        func markFocusRequestHandled(_ id: UUID) {
            handledFocusRequestID = id
        }

        @objc func submit() {
            onSubmit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let textView = field.currentEditor() as? NSTextView
                ?? notification.userInfo?["NSFieldEditor"] as? NSTextView
            isComposingText = textView?.hasMarkedText() == true
            guard !isComposingText else { return }
            text = field.stringValue
            try? AppDebugLogStore.shared.write(.debug, category: "AIInput", message: "Prompt field changed", metadata: ["length": "\(field.stringValue.count)"])
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textView = (notification.object as? NSTextField)?.currentEditor() as? NSTextView
                ?? notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            textView.insertionPointColor = .white
            textView.textColor = .white
            isComposingText = textView.hasMarkedText()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isComposingText = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }
    }
}

private final class ImagePromptCell: NSTextFieldCell {
    let imageEditor = ImagePromptFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        imageEditor.isFieldEditor = true
        imageEditor.isRichText = false
        imageEditor.drawsBackground = false
        return imageEditor
    }
}

final class ImagePromptFieldEditor: NSTextView {
    var onPasteImages: ((NSPasteboard) -> Bool)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff, .fileURL] + super.readablePasteboardTypes
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if onPasteImages?(pasteboard) == true { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func paste(_ sender: Any?) {
        if onPasteImages?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }
}

struct ComposingAwareTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposingText: Bool
    var font: NSFont
    var textColor: NSColor
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> TransparentPromptField {
        let field = TransparentPromptField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.font = font
        field.textColor = textColor
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: TransparentPromptField, context: Context) {
        TransparentPromptEditor.synchronize(field, with: text)
        field.font = font
        field.textColor = textColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isComposingText: $isComposingText, textColor: textColor, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var isComposingText: Bool
        let textColor: NSColor
        let onSubmit: () -> Void

        init(text: Binding<String>, isComposingText: Binding<Bool>, textColor: NSColor, onSubmit: @escaping () -> Void) {
            _text = text
            _isComposingText = isComposingText
            self.textColor = textColor
            self.onSubmit = onSubmit
        }

        @objc func submit() {
            onSubmit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
            if let textView = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                isComposingText = textView.hasMarkedText()
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            textView.insertionPointColor = textColor
            textView.textColor = textColor
            isComposingText = textView.hasMarkedText()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isComposingText = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }
    }
}
