import AppKit
import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class IslandPointerTrackingTests: XCTestCase {
    func testMouseEntryFromHiddenPanelDoesNotReopenIt() throws {
        let controller = try makeController()
        let panel = try showPanel(using: controller)
        defer { panel.orderOut(nil) }
        let contentView = try XCTUnwrap(panel.contentView)

        // AppKit can deliver a tracking event after the window has been hidden.
        panel.orderOut(nil)
        contentView.mouseEntered(with: try mouseEnteredEvent(for: panel))

        XCTAssertFalse(panel.isVisible)
    }

    func testMouseEntryFromDetachedContentDoesNotReopenPanel() throws {
        let controller = try makeController()
        let panel = try showPanel(using: controller)
        defer { panel.orderOut(nil) }
        let contentView = try XCTUnwrap(panel.contentView)
        let event = try mouseEnteredEvent(for: panel)

        panel.orderOut(nil)
        panel.contentView = nil
        contentView.mouseEntered(with: event)

        XCTAssertFalse(panel.isVisible)
    }

    private func makeController() throws -> NotchIslandController {
        let container = try TestSupport.makeInMemoryContainer()
        return NotchIslandController(modelContainer: container)
    }

    private func showPanel(using controller: NotchIslandController) throws -> NSPanel {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.showIsland()
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        } as? NSPanel)
        XCTAssertTrue(panel.isVisible)
        return panel
    }

    private func mouseEnteredEvent(for panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }
}
