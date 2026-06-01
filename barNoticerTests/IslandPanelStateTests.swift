import XCTest
@testable import barNoticer

final class IslandPanelStateTests: XCTestCase {
    func testIslandPanelsCanJoinAllSpacesWithoutMovingBetweenSpaces() {
        XCTAssertTrue(IslandPanelPresentation.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(IslandPanelPresentation.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(IslandPanelPresentation.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(IslandPanelPresentation.collectionBehavior.contains(.stationary))
        XCTAssertTrue(IslandPanelPresentation.collectionBehavior.contains(.ignoresCycle))
    }

    func testIslandSummaryStyleKeepsSecondaryTextReadableOnBlackIsland() {
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.secondaryTextOpacity, 0.74)
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.tertiaryTextOpacity, 0.64)
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.subtleTextOpacity, 0.6)
        XCTAssertGreaterThanOrEqual(IslandSummaryStyle.itemBackgroundOpacity, 0.1)
    }

    func testIslandSummaryRefreshesRelativeTimeEveryMinute() {
        XCTAssertLessThanOrEqual(IslandSummaryRefreshPolicy.timelineInterval, 60)
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

    func testOpeningTransitionCanRecoverAfterTimeout() throws {
        var state = IslandPanelState()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNotNil(state.beginShowing(now: startedAt))
        XCTAssertNil(state.beginShowing())
        state.recoverIfTransitionTimedOut(now: startedAt.addingTimeInterval(3), timeout: 2)

        XCTAssertNotNil(state.beginShowing())
    }

    func testClosingTransitionCanRecoverAfterTimeout() throws {
        var state = IslandPanelState()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let transition = try XCTUnwrap(state.beginShowing(now: startedAt))
        XCTAssertTrue(state.finishShowing(transition))
        _ = state.beginHiding(now: startedAt.addingTimeInterval(1))
        state.recoverIfTransitionTimedOut(now: startedAt.addingTimeInterval(4), timeout: 2)

        XCTAssertNotNil(state.beginShowing())
    }

    func testInvisiblePanelReconcilesShownStateToHidden() throws {
        var state = IslandPanelState()

        let transition = try XCTUnwrap(state.beginShowing())
        XCTAssertTrue(state.finishShowing(transition))
        XCTAssertNil(state.beginShowing())

        state.reconcile(isPanelVisible: false)

        XCTAssertNotNil(state.beginShowing())
    }
}
