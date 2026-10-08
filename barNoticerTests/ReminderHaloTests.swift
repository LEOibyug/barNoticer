import AppKit
import SwiftData
import XCTest
@testable import barNoticer

@MainActor
final class ReminderHaloTests: XCTestCase {
    func testScreenRefreshRepositionsAssistantEvenWhenSizeIsUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let controller = AIAssistantPanelController(modelContext: container.mainContext)
        let prior = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        defer { controller.close() }
        let panel = try XCTUnwrap(NSApp.windows.first { !prior.contains(ObjectIdentifier($0)) && $0.isVisible })
        // Let NSHostingView establish its intrinsic window constraints first.
        try await Task.sleep(for: .milliseconds(100))
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - 60, y: visible.minY - 60))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(panel.frame.size, size)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, visible.minY + 12)
        XCTAssertLessThanOrEqual(panel.frame.maxX, visible.maxX - 12)
    }

    func testReducedMotionPreviewShowsContentWithoutHalo() async throws {
        let fixture = try Fixture(reduceMotion: true)
        defer { fixture.close() }
        let prior = Set(NSApp.windows.map(ObjectIdentifier.init))
        fixture.notifications.post(name: ReminderSettings.previewDidChangeNotification, object: nil,
            userInfo: [ReminderSettings.previewHotZoneFlashExpansionUserInfoKey: 20.0])
        try await Task.sleep(for: .milliseconds(50))
        let windows = NSApp.windows.filter { !prior.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertFalse(windows.contains { $0.ignoresMouseEvents }, "Reduced-motion preview must not create an animated halo")
        XCTAssertTrue(windows.contains { !$0.ignoresMouseEvents && $0.level == .statusBar }, "Content must appear without the glow delay")
    }

    func testStaticPreviewIsVisibleAndExpansionChangesItsDrawnExtent() throws {
        let fixture = try Fixture(reduceMotion: true)
        defer { fixture.close() }
        let small = try previewBounds(expansion: 0, notifications: fixture.notifications)
        let large = try previewBounds(expansion: 20, notifications: fixture.notifications)
        XCTAssertEqual(large.width - small.width, 40, accuracy: 2)
        XCTAssertEqual(large.height - small.height, 40, accuracy: 2)
    }

    func testCustomBoundaryPersistsAndUsesScreenRelativeGeometry() throws {
        let fixture = try Fixture(reduceMotion: false)
        defer { fixture.close() }
        var settings = ReminderSettings()
        settings.haloBoundary = ReminderHaloBoundary(isCustom: true, offsetX: 35, offsetY: 12,
            width: 280, height: 48, cornerRadius: 16)
        settings.save(to: fixture.defaults)
        let restored = ReminderSettings(defaults: fixture.defaults)
        XCTAssertEqual(restored.haloBoundary, settings.haloBoundary)
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 900)
        let layout = IslandLayoutSettings(hotZoneOffsetX: 10, hotZoneOffsetY: 4)
        XCTAssertEqual(restored.haloBoundaryFrame(in: screen, islandLayout: layout),
            CGRect(x: -695, y: 936, width: 280, height: 48))
        var following = restored
        following.haloBoundary.isCustom = false
        XCTAssertEqual(following.haloBoundaryFrame(in: screen, islandLayout: layout),
            layout.hotZoneFrame(in: screen).insetBy(dx: -18, dy: -18))
    }

    func testPresenterUsesCustomBoundaryForPreviewAndPulse() throws {
        let fixture = try Fixture(reduceMotion: false)
        defer { fixture.close() }
        var settings = ReminderSettings()
        settings.haloBoundary = ReminderHaloBoundary(isCustom: true, offsetX: 21, offsetY: 35,
            width: 310, height: 54, cornerRadius: 12)
        settings.save(to: fixture.defaults)
        let expected = settings.haloBoundaryFrame(in: try XCTUnwrap(NSScreen.main).frame,
            islandLayout: IslandLayoutSettings(defaults: fixture.defaults))
        for notification in [ReminderSettings.boundaryPreviewDidChangeNotification, ReminderSettings.previewDidChangeNotification] {
            fixture.notifications.post(name: ReminderSettings.previewDidEndNotification, object: nil)
            fixture.notifications.post(name: notification, object: nil)
            let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is ReminderHaloView })
            XCTAssertEqual(window.frame.insetBy(dx: ReminderHaloView.drawingInset, dy: ReminderHaloView.drawingInset), expected)
        }
    }

    func testBoundaryStaysVisibleWhenRealReminderPulseEnds() async throws {
        let fixture = try Fixture(reduceMotion: false)
        defer { fixture.close() }
        fixture.notifications.post(name: ReminderSettings.boundaryPreviewDidChangeNotification, object: nil)
        let boundary = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && ($0.contentView as? ReminderHaloView)?.isPreview == true
        })
        fixture.presenter.present(decision: ReminderDecision(shouldRemind: true, message: "提醒",
            todoReferences: [], snoozeSuggestion: nil), trigger: .aiPoll,
            settings: ReminderSettings(systemNotificationsEnabled: false))
        try await Task.sleep(for: .seconds(ReminderPresentationTiming.flashDuration + 0.15))
        XCTAssertTrue(boundary.isVisible, "A real reminder must not dismiss the alignment reference")
        fixture.notifications.post(name: ReminderSettings.previewDidEndNotification, object: nil)
        XCTAssertFalse(boundary.isVisible)
    }

    func testPreviewReminderAndAssistantReplyShowHaloBeforeContent() async throws {
        let fixture = try Fixture(reduceMotion: false)
        defer { fixture.close() }
        let priorWindows = NSApp.windows
        defer { withExtendedLifetime(priorWindows) {} }
        let prior = Set(priorWindows.map(ObjectIdentifier.init))
        let triggers: [() -> Void] = [
            { fixture.notifications.post(name: ReminderSettings.previewDidChangeNotification, object: nil) },
            { fixture.presenter.present(decision: ReminderDecision(shouldRemind: true, message: "提醒",
                todoReferences: [], snoozeSuggestion: nil), trigger: .aiPoll,
                settings: ReminderSettings(systemNotificationsEnabled: false)) },
            { fixture.presenter.presentAssistantReply(AIAssistantReply(sessionID: UUID(), message: "回复",
                pendingActionCount: 0, isFailure: false), onOpenChat: {}) }
        ]
        func contentIsVisible() -> Bool {
            NSApp.windows.contains { !prior.contains(ObjectIdentifier($0)) && $0.isVisible
                && !$0.ignoresMouseEvents && $0.level == .statusBar }
        }
        for trigger in triggers {
            trigger()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(contentIsVisible(), "Content must not cover the initial halo")
            XCTAssertTrue(NSApp.windows.contains { !prior.contains(ObjectIdentifier($0)) && $0.isVisible
                && ($0.contentView as? ReminderHaloView)?.isPreview == false })
            for _ in 0..<100 where !contentIsVisible() {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(contentIsVisible(), "Content must appear after the halo")
            fixture.notifications.post(name: ReminderSettings.previewDidEndNotification, object: nil)
            try await Task.sleep(for: .milliseconds(350))
        }
    }

    private func previewBounds(expansion: Double, notifications: NotificationCenter) throws -> CGRect {
        let prior = Set(NSApp.windows.map(ObjectIdentifier.init))
        notifications.post(name: ReminderSettings.boundaryPreviewDidChangeNotification, object: nil,
            userInfo: [ReminderSettings.previewHotZoneFlashExpansionUserInfoKey: expansion])
        let window = try XCTUnwrap(NSApp.windows.first {
            !prior.contains(ObjectIdentifier($0)) && $0.isVisible && $0.ignoresMouseEvents
        })
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try XCTUnwrap(view.layer).render(in: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX, minX, "The static preview must paint a visible boundary")
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX + 1), height: max(0, maxY - minY + 1))
    }

    private struct Fixture {
        let container: ModelContainer
        let presenter: ReminderPresenter
        let suite = "HaloTests-\(UUID())"
        let defaults: UserDefaults
        let notifications = NotificationCenter()
        init(reduceMotion: Bool) throws {
            container = try TestSupport.makeInMemoryContainer()
            defaults = UserDefaults(suiteName: suite)!
            presenter = ReminderPresenter(modelContext: container.mainContext,
                historyStore: ReminderHistoryStore(defaults: defaults), defaults: defaults, notifications: notifications,
                reduceMotion: { reduceMotion })
        }
        func close() {
            notifications.post(name: ReminderSettings.previewDidEndNotification, object: nil)
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
