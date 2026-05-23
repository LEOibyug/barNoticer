import XCTest
@testable import barNoticer

final class IslandPanelStateTests: XCTestCase {
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
}
