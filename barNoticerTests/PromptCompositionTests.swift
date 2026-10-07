import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class PromptCompositionTests: XCTestCase {
    func testAssistantUsesNativePlaceholderWhileCompositionBindingIsStale() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let model = AIAssistantModel(modelContext: container.mainContext)
        let host = NSHostingView(rootView: AIAssistantPanelView(model: model, close: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 128), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        // Let initial SwiftUI layout and its asynchronous focus request settle
        // before beginning the simulated input method session.
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(promptField(in: host))
        XCTAssertEqual(field.placeholderAttributedString?.string, "询问 AI，或写下当日总结")

        // Keep the SwiftUI bindings stale to model an input method that has
        // not yet delivered controlTextDidChange. Native placeholder drawing
        // must use the editor's live text instead of those bindings.
        field.delegate = nil
        window.makeFirstResponder(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(model.prompt, "")
        XCTAssertFalse(model.isComposingPromptText)
        XCTAssertEqual(editor.string, "ni")
        XCTAssertTrue(editor.hasMarkedText())

        // Publishing the delayed composition state must not change the
        // rendered input: there must be no SwiftUI placeholder underneath it.
        let pendingStateImage = try renderedImage(of: host)
        model.isComposingPromptText = true
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let synchronizedStateImage = try renderedImage(of: host)
        XCTAssertEqual(pendingStateImage, synchronizedStateImage)
        XCTAssertEqual(editor.string, "ni")
        XCTAssertTrue(editor.hasMarkedText())
    }

    private func renderedImage(of view: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func promptField(in view: NSView) -> TransparentPromptField? {
        if let field = view as? TransparentPromptField { return field }
        return view.subviews.lazy.compactMap { self.promptField(in: $0) }.first
    }

    func testMarkedPinyinHidesPlaceholderBeforeChineseIsCommitted() throws {
        var text = ""
        var composing = false
        let coordinator = TransparentPromptEditor.Coordinator(
            text: Binding(get: { text }, set: { text = $0 }),
            isComposingText: Binding(get: { composing }, set: { composing = $0 }),
            onSubmit: {}
        )
        let field = TransparentPromptField()
        field.delegate = coordinator
        let window = makeWindow(field: field)
        defer { window.orderOut(nil) }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(composing)
        XCTAssertFalse(PromptPlaceholderVisibility.shouldShowPlaceholder(text: text, isComposingText: composing))

        TransparentPromptEditor.synchronize(field, with: text)
        XCTAssertEqual(editor.string, "ni")
        XCTAssertTrue(editor.hasMarkedText())

        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text, "你")
        XCTAssertFalse(composing)
        XCTAssertFalse(PromptPlaceholderVisibility.shouldShowPlaceholder(text: text, isComposingText: composing))

        editor.selectAll(nil)
        editor.deleteBackward(nil)
        XCTAssertEqual(text, "")
        XCTAssertTrue(PromptPlaceholderVisibility.shouldShowPlaceholder(text: text, isComposingText: composing))
    }

    func testASCIIInputHidesPlaceholderAndReturnSubmits() throws {
        var text = ""
        var composing = false
        var submitted = false
        let coordinator = TransparentPromptEditor.Coordinator(
            text: Binding(get: { text }, set: { text = $0 }),
            isComposingText: Binding(get: { composing }, set: { composing = $0 }),
            onSubmit: { submitted = true }
        )
        let field = TransparentPromptField()
        field.delegate = coordinator
        let window = makeWindow(field: field)
        defer { window.orderOut(nil) }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(text, "hello")
        XCTAssertFalse(composing)
        XCTAssertFalse(PromptPlaceholderVisibility.shouldShowPlaceholder(text: text, isComposingText: composing))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(submitted)
    }

    func testSwiftUIRefreshDoesNotReplaceUncommittedPinyin() throws {
        let field = TransparentPromptField()
        let window = makeWindow(field: field)
        defer { window.orderOut(nil) }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        TransparentPromptEditor.synchronize(field, with: "")

        XCTAssertEqual(editor.string, "ni")
        XCTAssertTrue(editor.hasMarkedText())
    }

    func testReturnDuringCompositionDoesNotSubmitPrompt() throws {
        var submitted = false
        let coordinator = TransparentPromptEditor.Coordinator(
            text: .constant(""), isComposingText: .constant(true), onSubmit: { submitted = true }
        )
        let editor = NSTextView()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        let handled = coordinator.control(TransparentPromptField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertFalse(handled)
        XCTAssertFalse(submitted)
    }

    func testCompositionStateUsesActiveEditorWhenNotificationHasNoUserInfo() throws {
        var composing = false
        let coordinator = TransparentPromptEditor.Coordinator(
            text: .constant(""),
            isComposingText: Binding(get: { composing }, set: { composing = $0 }),
            onSubmit: {}
        )
        let field = TransparentPromptField()
        let window = makeWindow(field: field)
        defer { window.orderOut(nil) }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

        XCTAssertTrue(composing)
    }

    private func makeWindow(field: TransparentPromptField) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = field
        window.makeFirstResponder(field)
        field.selectText(nil)
        return window
    }
}
