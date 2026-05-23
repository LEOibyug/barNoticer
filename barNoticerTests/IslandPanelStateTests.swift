import XCTest
@testable import barNoticer

final class IslandPanelStateTests: XCTestCase {
    func testIslandSummaryStyleKeepsSecondaryTextReadableOnBlackIsland() {
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.secondaryTextOpacity, 0.74)
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.tertiaryTextOpacity, 0.64)
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.subtleTextOpacity, 0.6)
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.itemBackgroundOpacity, 0.1)
    }

    func testRepeatedShowWhileOpeningDoesNotRestartTransition() {
        var state = IslandPanelState()

        XCTAssertNotNil(state.beginShowing())
        XCTAssertNil(state.beginShowing())
    }

    func testShowCanStartAfterHiddenOrClosing() {
        var state = IslandPanelState()

        XCTAssertNotNil(state.beginShowing())
        state.beginHiding()

        XCTAssertNotNil(state.beginShowing())
    }

    func testStaleHideCompletionDoesNotOverrideNewShowTransition() throws {
        var state = IslandPanelState()

        _ = state.beginShowing()
        let hideTransition = state.beginHiding()
        let showTransition = try XCTUnwrap(state.beginShowing())

        XCTAssertFalse(state.finishHiding(hideTransition))
        XCTAssertTrue(state.finishShowing(showTransition))
    }

    func testStaleShowCompletionDoesNotOverrideHideTransition() throws {
        var state = IslandPanelState()

        let showTransition = try XCTUnwrap(state.beginShowing())
        _ = state.beginHiding()

        XCTAssertFalse(state.finishShowing(showTransition))
    }
}
