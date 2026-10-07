import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import barNoticer

@MainActor
final class TodoCreationPanelTests: XCTestCase {
    func testRapidCloseReopenKeepsWindowVisible() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let controller = TodoCreationPanelController(modelContext: container.mainContext)
        defer { controller.close() }

        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        let window = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        })
        controller.close()
        controller.show()
        try await Task.sleep(for: .milliseconds(400))

        // 关闭动画期间重新打开：旧 completion 不得隐藏新窗口。
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
    }

    func testPanelFrameStaysWithinVisibleScreen() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let controller = TodoCreationPanelController(modelContext: container.mainContext)
        defer { controller.close() }

        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        let window = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        })

        // 四边都限制在可见屏幕区域内，四周至少 12 pt。
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX - 0.5)
        XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY - 0.5)
        XCTAssertLessThanOrEqual(window.frame.maxY, visible.maxY + 0.5)
        XCTAssertGreaterThan(window.frame.width, 0)
        XCTAssertGreaterThan(window.frame.height, 0)
    }
}
