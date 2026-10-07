import XCTest
@testable import barNoticer

final class ReminderSettingsTests: XCTestCase {
    func testReminderSettingsUseConservativeDefaults() {
        let settings = ReminderSettings()

        XCTAssertFalse(settings.aiPollingEnabled)
        XCTAssertEqual(settings.pollingInterval, 1_800)
        XCTAssertTrue(settings.systemNotificationsEnabled)
        XCTAssertEqual(settings.tone, .playful)
        XCTAssertEqual(settings.dedupeWindow, 1_800)
        XCTAssertEqual(settings.hotZoneFlashExpansion, 18)
        XCTAssertEqual(settings.reminderPanelOffsetX, 0)
        XCTAssertEqual(settings.reminderPanelOffsetY, 0)
        XCTAssertEqual(settings.reminderPanelWidth, 392)
        XCTAssertEqual(settings.reminderPanelTopContentInset, 34)
        XCTAssertEqual(settings.reminderPanelAutoCloseDelay, 4)
    }

    func testReminderSettingsRoundTripAndNotifyChanges() {
        let suiteName = "ReminderSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var observed = false
        let token = NotificationCenter.default.addObserver(
            forName: ReminderSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            observed = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        ReminderSettings(
            aiPollingEnabled: true,
            pollingInterval: 900,
            systemNotificationsEnabled: false,
            tone: .furious,
            dedupeWindow: 3_600,
            hotZoneFlashExpansion: 32,
            reminderPanelOffsetX: 24,
            reminderPanelOffsetY: 18,
            reminderPanelWidth: 460,
            reminderPanelTopContentInset: 48,
            reminderPanelAutoCloseDelay: 8
        ).save(to: defaults)

        let stored = ReminderSettings(defaults: defaults)
        XCTAssertTrue(stored.aiPollingEnabled)
        XCTAssertEqual(stored.pollingInterval, 900)
        XCTAssertFalse(stored.systemNotificationsEnabled)
        XCTAssertEqual(stored.tone, .furious)
        XCTAssertEqual(stored.dedupeWindow, 3_600)
        XCTAssertEqual(stored.hotZoneFlashExpansion, 32)
        XCTAssertEqual(stored.reminderPanelOffsetX, 24)
        XCTAssertEqual(stored.reminderPanelOffsetY, 18)
        XCTAssertEqual(stored.reminderPanelWidth, 460)
        XCTAssertEqual(stored.reminderPanelTopContentInset, 48)
        XCTAssertEqual(stored.reminderPanelAutoCloseDelay, 8)
        XCTAssertTrue(observed)
    }

    func testReminderSettingsCanRequestPresentationPreview() {
        var previewExpansion: Double?
        let token = NotificationCenter.default.addObserver(
            forName: ReminderSettings.previewDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            previewExpansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
        }
        defer { NotificationCenter.default.removeObserver(token) }

        ReminderSettings.requestPresentationPreview(hotZoneFlashExpansion: 42)

        XCTAssertEqual(previewExpansion, 42)
    }

    func testReminderSettingsCanRequestBoundaryPreviewWithoutFullPresentation() {
        var boundaryExpansion: Double?
        var fullPreviewCount = 0
        let boundaryToken = NotificationCenter.default.addObserver(
            forName: ReminderSettings.boundaryPreviewDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            boundaryExpansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
        }
        let fullToken = NotificationCenter.default.addObserver(
            forName: ReminderSettings.previewDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            fullPreviewCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(boundaryToken)
            NotificationCenter.default.removeObserver(fullToken)
        }

        ReminderSettings.requestBoundaryPreview(hotZoneFlashExpansion: 21)

        XCTAssertEqual(boundaryExpansion, 21)
        XCTAssertEqual(fullPreviewCount, 0)
    }

    func testReminderPanelLayoutUsesNotchAnchoredFrameAndCollapsedHotZone() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let islandLayout = IslandLayoutSettings(hotZoneOffsetX: 20, hotZoneOffsetY: 12, hotZoneWidth: 220, hotZoneHeight: 36)
        let settings = ReminderSettings(
            reminderPanelOffsetX: 16,
            reminderPanelOffsetY: 10,
            reminderPanelWidth: 420,
            reminderPanelTopContentInset: 44
        )

        let finalFrame = settings.reminderPanelFrame(in: screen, islandLayout: islandLayout)
        let collapsedFrame = settings.reminderCollapsedFrame(in: screen, islandLayout: islandLayout)

        XCTAssertEqual(finalFrame.width, 420)
        XCTAssertEqual(finalFrame.height, ReminderPresentationTiming.panelBaseHeight + 44)
        XCTAssertEqual(finalFrame.midX, screen.midX + 16)
        XCTAssertEqual(finalFrame.maxY, screen.maxY - ReminderPresentationTiming.panelTopInset - 10)
        XCTAssertEqual(collapsedFrame, islandLayout.hotZoneFrame(in: screen))
    }

    func testReminderPanelAutoCloseDelayIsConfigurable() {
        let shortDelay = ReminderSettings(reminderPanelAutoCloseDelay: 1)
        let longDelay = ReminderSettings(reminderPanelAutoCloseDelay: 10)

        XCTAssertEqual(shortDelay.reminderPanelAutoCloseDelay, 1)
        XCTAssertEqual(longDelay.reminderPanelAutoCloseDelay, 10)
    }

    func testReminderContentClearsNotchWithMinimumUserInset() {
        let settings = ReminderSettings(reminderPanelTopContentInset: 12)
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let frame = settings.reminderPanelFrame(in: screen, islandLayout: IslandLayoutSettings(), safeAreaTop: 38)
        let inset = settings.reminderContentTopInset(safeAreaTop: 38)

        XCTAssertLessThanOrEqual(frame.maxY - 16 - inset, 1066)
        XCTAssertEqual(frame.height - inset, 226)
    }

    func testReminderContentClearsNotchWhenPanelIsMovedUp() {
        let settings = ReminderSettings(reminderPanelOffsetY: -24, reminderPanelTopContentInset: 12)
        let screen = CGRect(x: 100, y: -200, width: 1710, height: 1112)
        let frame = settings.reminderPanelFrame(in: screen, islandLayout: IslandLayoutSettings(), safeAreaTop: 38)
        let inset = settings.reminderContentTopInset(safeAreaTop: 38)

        XCTAssertLessThanOrEqual(frame.maxY - 16 - inset, 866)
        XCTAssertEqual(frame.height - inset, 226)
    }

    func testReminderKeepsLargerUserInsetAndExternalDisplayLayout() {
        let settings = ReminderSettings(reminderPanelTopContentInset: 60)
        XCTAssertEqual(settings.reminderContentTopInset(safeAreaTop: 38), 60)
        XCTAssertEqual(settings.reminderContentTopInset(safeAreaTop: 0), 60)

        let lowered = ReminderSettings(reminderPanelOffsetY: 80, reminderPanelTopContentInset: 12)
        XCTAssertEqual(lowered.reminderContentTopInset(safeAreaTop: 38), 12)
    }

    func testReminderPanelWaitsForHaloToFinish() {
        XCTAssertGreaterThanOrEqual(ReminderPresentationTiming.flashDuration, 1)
        XCTAssertEqual(ReminderPresentationTiming.panelDelayAfterFlash, ReminderPresentationTiming.flashDuration)
    }

    func testReminderPanelRevealKeepsContentAtFinalLayoutSizeDuringAnimation() {
        let finalFrame = CGRect(x: 520, y: 610, width: 400, height: 260)
        let collapsedFrame = CGRect(x: 620, y: 830, width: 200, height: 36)

        let geometry = ReminderPanelRevealGeometry(collapsedFrameInScreen: collapsedFrame, finalFrameInScreen: finalFrame)

        XCTAssertEqual(geometry.contentFrame, CGRect(x: 0, y: 0, width: 400, height: 260))
        XCTAssertEqual(geometry.collapsedFrameInContentCoordinates, CGRect(x: 100, y: 220, width: 200, height: 36))
    }

    func testReminderSettingsCanEndPresentationPreview() {
        var didEnd = false
        let token = NotificationCenter.default.addObserver(
            forName: ReminderSettings.previewDidEndNotification,
            object: nil,
            queue: nil
        ) { _ in
            didEnd = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        ReminderSettings.endPresentationPreview()

        XCTAssertTrue(didEnd)
    }

    func testManualReminderSampleTriggersPresentationPreview() {
        var previewExpansion: Double?
        let token = NotificationCenter.default.addObserver(
            forName: ReminderSettings.previewDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            previewExpansion = notification.userInfo?[ReminderSettings.previewHotZoneFlashExpansionUserInfoKey] as? Double
        }
        defer { NotificationCenter.default.removeObserver(token) }

        ReminderPresentationPreviewAction.trigger(hotZoneFlashExpansion: 28)

        XCTAssertEqual(ReminderPresentationPreviewAction.title, "提醒示例")
        XCTAssertEqual(previewExpansion, 28)
    }

    func testSidebarHasIndependentReminderSettingsSelection() {
        XCTAssertNotEqual(SidebarSelection.reminderSettings, SidebarSelection.aiSettings)
        XCTAssertNotEqual(SidebarSelection.reminderSettings, SidebarSelection.islandSettings)
        XCTAssertNotEqual(SidebarSelection.reminderSettings, SidebarSelection.appSettings)
    }
}
