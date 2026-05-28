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

    func makeNSView(context: Context) -> TransparentPromptField {
        let field = TransparentPromptField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: TransparentPromptField, context: Context) {
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
            text = field.stringValue
            if let textView = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                isComposingText = textView.hasMarkedText()
            }
            try? AppDebugLogStore.shared.write(.debug, category: "AIInput", message: "Prompt field changed", metadata: ["length": "\(field.stringValue.count)"])
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            textView.insertionPointColor = .white
            textView.textColor = .white
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
