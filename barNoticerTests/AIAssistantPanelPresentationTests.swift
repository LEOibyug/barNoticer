import AppKit
import XCTest
@testable import barNoticer

@MainActor
final class AIAssistantPanelPresentationTests: XCTestCase {
    func testAssistantPanelCanBecomeKeyForTextInput() {
        let panel = AIAssistantPanelChrome.makePanel(contentView: NSView())

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testAssistantPanelRequestsCloseWhenLosingKeyFocus() {
        var didRequestClose = false
        let panel = AIAssistantPanelChrome.makePanel(contentView: NSView()) {
            didRequestClose = true
        }

        panel.resignKey()

        XCTAssertTrue(didRequestClose)
    }

    func testAssistantPanelUsesCompactSpotlightLikeInputHeight() {
        XCTAssertLessThanOrEqual(AIAssistantPanelChrome.size.height, 140)
    }

    func testAssistantPanelDoesNotExpandForHiddenConversationContextAlone() {
        XCTAssertEqual(
            AIAssistantPanelChrome.size(hasVisibleConversation: true, hasTransientOutput: false),
            AIAssistantPanelChrome.compactSize
        )
    }

    func testAssistantPanelExpandsForLatestVisibleOutput() {
        XCTAssertEqual(
            AIAssistantPanelChrome.size(hasVisibleConversation: true, hasTransientOutput: true),
            AIAssistantPanelChrome.expandedSize
        )
    }

    func testAssistantPanelExpandedHeightLeavesRoomForActionConfirmation() {
        XCTAssertGreaterThanOrEqual(AIAssistantPanelChrome.expandedSize.height, 500)
    }

    func testAssistantPanelStyleUsesHighContrastDarkSurfaces() {
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.panelBackgroundOpacity, 0.92)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.inputBackgroundOpacity, 0.68)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.responseBackgroundOpacity, 0.68)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.proposalBackgroundOpacity, 0.58)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.todoCardBackgroundOpacity, 0.52)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.secondaryTextOpacity, 0.84)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.tertiaryTextOpacity, 0.74)
        XCTAssertGreaterThanOrEqual(AIAssistantPanelStyle.subtleTextOpacity, 0.72)
    }

    func testAssistantProgressOverlaysPromptInsteadOfAddingInputSubrow() {
        XCTAssertEqual(AIAssistantPanelStyle.progressPlacement, .promptOverlay)
        XCTAssertEqual(AIAssistantPanelStyle.promptFieldHeight, 28)
    }

    func testAssistantPanelUsesDarkAppearanceForMaterialSampling() {
        let panel = AIAssistantPanelChrome.makePanel(contentView: NSView())

        XCTAssertEqual(panel.appearance?.name, .darkAqua)
        XCTAssertEqual(panel.contentView?.appearance?.name, .darkAqua)
    }

    func testAssistantPanelClipsContentToRoundedBounds() throws {
        let panel = AIAssistantPanelChrome.makePanel(contentView: NSView())
        let contentView = try XCTUnwrap(panel.contentView)

        XCTAssertTrue(contentView.wantsLayer)
        XCTAssertTrue(contentView.layer?.masksToBounds == true)
        XCTAssertEqual(contentView.layer?.cornerRadius, AIAssistantPanelChrome.cornerRadius)
    }

    func testAssistantPromptInputUsesTransparentTextField() throws {
        let field = TransparentPromptField()

        XCTAssertFalse(field.drawsBackground)
        XCTAssertEqual(field.backgroundColor, .clear)
        XCTAssertEqual(field.textColor, .white)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isBordered)
    }

    func testPromptEditorDoesNotStorePlaceholderAsTextContent() throws {
        let field = TransparentPromptField()
        TransparentPromptEditor.synchronize(field, with: "")

        XCTAssertEqual(field.stringValue, "")
    }
}
