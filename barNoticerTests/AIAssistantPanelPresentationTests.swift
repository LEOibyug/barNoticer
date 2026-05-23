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

    func testAssistantPanelUsesIntermediateHeightForLatestVisibleReply() {
        XCTAssertEqual(
            AIAssistantPanelChrome.size(outputKind: .response),
            AIAssistantPanelChrome.responseSize
        )
    }

    func testAssistantPanelExpandedHeightLeavesRoomForActionConfirmation() {
        XCTAssertEqual(
            AIAssistantPanelChrome.size(outputKind: .actionConfirmation),
            AIAssistantPanelChrome.expandedSize
        )
        XCTAssertGreaterThanOrEqual(AIAssistantPanelChrome.expandedSize.height, 500)
    }

    func testAssistantPanelKeepsThinkingStateCompactWithoutVisibleOutput() {
        XCTAssertEqual(
            AIAssistantPanelChrome.outputKind(response: "", proposals: [], state: .loading),
            .none
        )
    }

    func testAssistantPanelClassifiesLoggedReplyAsVisibleResponse() {
        let response = "已修改。[[todo:43BC1C81-B449-4148-8C0A-367832AB6994]] 截止时间现在是 5 月 28 日下午 3 点，距离现在还有大约 4 天多的时间。"

        XCTAssertEqual(
            AIAssistantPanelChrome.outputKind(response: response, proposals: [], state: .ready),
            .response
        )
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

    func testAssistantResponseScrollViewResetsWhenContentChanges() {
        XCTAssertTrue(AIAssistantPanelStyle.resetsResponseScrollOnContentChange)
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
