import AppKit
import XCTest
@testable import barNoticer

@MainActor
final class MainWindowPresentationTests: XCTestCase {
    func testIslandDoesNotReusePanelsAsMainWindow() {
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)

        XCTAssertFalse(NotchIslandController.shouldReuseAsMainWindow(panel))
        XCTAssertTrue(NotchIslandController.shouldReuseAsMainWindow(window))
    }
}
