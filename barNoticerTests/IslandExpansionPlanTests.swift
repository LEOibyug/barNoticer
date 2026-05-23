import XCTest
@testable import barNoticer

final class IslandExpansionPlanTests: XCTestCase {
    func testExpansionStartsFromCollapsedHotZoneFrame() {
        let settings = IslandLayoutSettings(
            hotZoneOffsetX: 18,
            hotZoneOffsetY: 11,
            hotZoneWidth: 242,
            hotZoneHeight: 38,
            islandOffsetX: -20,
            islandOffsetY: 16
        )
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let plan = IslandExpansionPlan(settings: settings, screenFrame: screenFrame)

        XCTAssertEqual(plan.startFrame, settings.hotZoneFrame(in: screenFrame))
        XCTAssertEqual(plan.endFrame, settings.islandFrame(in: screenFrame))
    }

    func testContentFadeWaitsUntilShellHasStartedExpanding() {
        let plan = IslandExpansionPlan(settings: IslandLayoutSettings(), screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))

        XCTAssertGreaterThan(plan.contentFadeDelay, 0)
        XCTAssertLessThan(plan.contentFadeDelay, plan.duration)
    }
}
