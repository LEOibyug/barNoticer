import XCTest
@testable import barNoticer

final class IslandQuickAddDraftTests: XCTestCase {
    func testSelectedPriorityIsKeptForSubmission() {
        let draft = IslandQuickAddDraft(title: "  修复动画  ", priority: .high)

        XCTAssertEqual(draft.trimmedTitle, "修复动画")
        XCTAssertEqual(draft.priority, .high)
        XCTAssertTrue(draft.canSubmit)
    }

    func testWhitespaceTitleCannotSubmit() {
        let draft = IslandQuickAddDraft(title: "   ", priority: .low)

        XCTAssertFalse(draft.canSubmit)
    }
}
