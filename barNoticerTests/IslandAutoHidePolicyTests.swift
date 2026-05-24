import XCTest
@testable import barNoticer

final class IslandAutoHidePolicyTests: XCTestCase {
    func testPointerOutsideIslandAndHotZoneEndsEditingBeforeAutoHide() {
        let decision = IslandAutoHidePolicy.decision(
            pointerInIsland: false,
            pointerInHotZone: false,
            isPreviewingIsland: false
        )

        XCTAssertTrue(decision.shouldHide)
        XCTAssertTrue(decision.shouldEndEditing)
    }

    func testPointerInsideIslandDoesNotEndEditingOrHide() {
        let decision = IslandAutoHidePolicy.decision(
            pointerInIsland: true,
            pointerInHotZone: false,
            isPreviewingIsland: false
        )

        XCTAssertFalse(decision.shouldHide)
        XCTAssertFalse(decision.shouldEndEditing)
    }

    func testPreviewingIslandDoesNotEndEditingOrHide() {
        let decision = IslandAutoHidePolicy.decision(
            pointerInIsland: false,
            pointerInHotZone: false,
            isPreviewingIsland: true
        )

        XCTAssertFalse(decision.shouldHide)
        XCTAssertFalse(decision.shouldEndEditing)
    }
}
