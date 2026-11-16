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
        XCTAssertTrue(NotchPopupPresence.isPresenting)
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

        // 初始展开帧也必须完全留在当前屏幕可用区域内。
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX - 0.5)
        XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY - 0.5)
        XCTAssertLessThanOrEqual(window.frame.maxY, visible.maxY + 0.5)
        XCTAssertGreaterThan(window.frame.width, 0)
        XCTAssertGreaterThan(window.frame.height, 0)
    }

    func testContentGrowsDownwardBelowNotchAndMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        // 自动隐藏菜单栏时 visibleFrame 可抵达屏幕顶边，仍需避开刘海安全区。
        let visible = CGRect(x: 0, y: 24, width: 1_512, height: 958)
        let settings = IslandLayoutSettings(hotZoneOffsetX: 120)
        let compact = TodoCreationPanelChrome.frame(
            contentHeight: 300, screenFrame: screen, visibleFrame: visible,
            safeAreaTopInset: 38, settings: settings
        )
        let expanded = TodoCreationPanelChrome.frame(
            contentHeight: 600, screenFrame: screen, visibleFrame: visible,
            safeAreaTopInset: 38, settings: settings
        )

        XCTAssertEqual(compact, CGRect(x: 556, y: 636, width: 640, height: 300))
        XCTAssertEqual(expanded, CGRect(x: 556, y: 336, width: 640, height: 600))
    }

    func testGeometryClampsToExternalAndSmallDisplaysWithCustomHotZone() {
        let cases: [(screen: CGRect, visible: CGRect, settings: IslandLayoutSettings, expected: CGRect)] = [
            (
                CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                CGRect(x: -1_920, y: 0, width: 1_920, height: 1_055),
                IslandLayoutSettings(),
                CGRect(x: -1_280, y: 136, width: 640, height: 900)
            ),
            (
                CGRect(x: 200, y: -300, width: 480, height: 320),
                CGRect(x: 200, y: -280, width: 480, height: 276),
                IslandLayoutSettings(hotZoneOffsetX: 2_000, hotZoneOffsetY: 2_000),
                CGRect(x: 212, y: -268, width: 456, height: 160)
            )
        ]
        for testCase in cases {
            let frame = TodoCreationPanelChrome.frame(
                contentHeight: 900, screenFrame: testCase.screen, visibleFrame: testCase.visible,
                safeAreaTopInset: 0, settings: testCase.settings
            )
            XCTAssertEqual(frame, testCase.expected)
        }
    }

    func testExpansionStartsAtSameTopAnchorInsideFinalFrame() {
        let expanded = CGRect(x: 300, y: 400, width: 640, height: 420)
        let collapsed = TodoCreationPanelChrome.collapsedFrame(for: expanded)

        XCTAssertEqual(collapsed, CGRect(x: 300, y: 772, width: 640, height: 48))
        XCTAssertTrue(expanded.contains(collapsed))
    }
}
