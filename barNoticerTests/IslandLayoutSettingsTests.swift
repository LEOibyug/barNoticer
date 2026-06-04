import XCTest
@testable import barNoticer

final class IslandLayoutSettingsTests: XCTestCase {
    func testDefaultHotZoneFrameIsCenteredAtTopOfScreen() {
        let settings = IslandLayoutSettings()
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let frame = settings.hotZoneFrame(in: screenFrame)

        XCTAssertEqual(frame.origin.x, 610)
        XCTAssertEqual(frame.origin.y, 864)
        XCTAssertEqual(frame.width, 220)
        XCTAssertEqual(frame.height, 36)
    }

    func testOffsetsMoveHotZoneAndIslandRightAndDown() {
        let settings = IslandLayoutSettings(
            hotZoneOffsetX: 20,
            hotZoneOffsetY: 12,
            hotZoneWidth: 260,
            hotZoneHeight: 42,
            islandOffsetX: -18,
            islandOffsetY: 16,
            islandTopContentInset: 40
        )
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let hotZoneFrame = settings.hotZoneFrame(in: screenFrame)
        let islandFrame = settings.islandFrame(in: screenFrame)

        XCTAssertEqual(hotZoneFrame.origin.x, 610)
        XCTAssertEqual(hotZoneFrame.origin.y, 846)
        XCTAssertEqual(hotZoneFrame.width, 260)
        XCTAssertEqual(hotZoneFrame.height, 42)
        XCTAssertEqual(islandFrame.origin.x, 506)
        XCTAssertEqual(islandFrame.origin.y, 518)
        XCTAssertEqual(islandFrame.height, 358)
    }

    func testDefaultIslandFrameIncludesTopContentInset() {
        let settings = IslandLayoutSettings()
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let islandFrame = settings.islandFrame(in: screenFrame)

        XCTAssertEqual(settings.islandTopContentInset, 34)
        XCTAssertEqual(islandFrame.origin.y, 540)
        XCTAssertEqual(islandFrame.height, 352)
    }

    func testCollapsedIslandFrameReusesHotZoneFrame() {
        let settings = IslandLayoutSettings(
            hotZoneOffsetX: 24,
            hotZoneOffsetY: 14,
            hotZoneWidth: 260,
            hotZoneHeight: 44,
            islandOffsetX: -40,
            islandOffsetY: 30
        )
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(settings.collapsedIslandFrame(in: screenFrame), settings.hotZoneFrame(in: screenFrame))
    }

    func testWideModeIslandIsThreeTimesStandardWidth() {
        let settings = IslandLayoutSettings(mode: .wide)
        let screenFrame = CGRect(x: 0, y: 0, width: 1800, height: 1000)

        let frame = settings.islandFrame(in: screenFrame)

        XCTAssertEqual(frame.width, IslandLayoutSettings.defaultIslandSize.width * 3)
        XCTAssertEqual(frame.origin.x, 312)
    }

    func testLayoutKeysAreIndependentPerMode() {
        XCTAssertNotEqual(
            IslandLayoutSettings.hotZoneOffsetXKey(for: .standard),
            IslandLayoutSettings.hotZoneOffsetXKey(for: .wide)
        )
        XCTAssertNotEqual(
            IslandLayoutSettings.islandTopContentInsetKey(for: .standard),
            IslandLayoutSettings.islandTopContentInsetKey(for: .wide)
        )
    }

    func testLayoutChangeNotificationDoesNotStartPreview() {
        var didChangeCount = 0
        var previewChangeCount = 0
        let center = NotificationCenter.default

        let didChangeObserver = center.addObserver(
            forName: IslandLayoutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            didChangeCount += 1
        }
        let previewObserver = center.addObserver(
            forName: IslandLayoutSettings.previewDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            previewChangeCount += 1
        }
        defer {
            center.removeObserver(didChangeObserver)
            center.removeObserver(previewObserver)
        }

        IslandLayoutSettings.notifyLayoutChanged()

        XCTAssertEqual(didChangeCount, 1)
        XCTAssertEqual(previewChangeCount, 0)
    }

    func testEndingPreviewSendsPreviewEndNotification() {
        var didEndPreview = false
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: IslandLayoutSettings.previewDidEndNotification,
            object: nil,
            queue: nil
        ) { _ in
            didEndPreview = true
        }
        defer {
            center.removeObserver(observer)
        }

        IslandLayoutSettings.notifyChanged(previewKind: nil)

        XCTAssertTrue(didEndPreview)
    }

    func testModeSwitchAnimationDurationIsDeliberatelyRelaxed() {
        XCTAssertGreaterThanOrEqual(IslandAnimationTimings.modeSwitchDuration, 0.58)
    }

    func testWideModeShowsAllItemsForEachPriority() {
        let items = (0..<10).map { index in
            TodoItem(title: "High \(index)", priority: .high)
        } + [
            TodoItem(title: "Medium", priority: .medium),
            TodoItem(title: "Low", priority: .low)
        ]

        let visible = IslandWideTodoPolicy.items(for: .high, from: items)

        XCTAssertEqual(visible.count, 10)
        XCTAssertEqual(visible.map(\.title), (0..<10).map { "High \($0)" })
    }

    func testStandardModeShowsAllActiveItemsInsteadOfTruncating() {
        let items = (0..<8).map { index in
            TodoItem(title: "Item \(index)", priority: .medium)
        }

        let visible = IslandStandardTodoPolicy.items(from: items)

        XCTAssertEqual(visible.count, 8)
        XCTAssertEqual(visible.map(\.title), (0..<8).map { "Item \($0)" })
    }

    func testGroupingModeDefaultsToPriorityAndPersistsByRawValue() {
        XCTAssertEqual(IslandGroupingMode(rawValue: "priority"), .priority)
        XCTAssertEqual(IslandGroupingMode(rawValue: "group"), .group)
        XCTAssertEqual(IslandGroupingMode.defaultMode, .priority)
        XCTAssertEqual(IslandGroupingMode.storageKey, "island.groupingMode")
    }

    func testWideGroupLayoutScrollsHorizontallyOnlyAfterThreeGroups() {
        XCTAssertFalse(IslandWideGroupLayoutPolicy.needsHorizontalScroll(groupCount: 3))
        XCTAssertTrue(IslandWideGroupLayoutPolicy.needsHorizontalScroll(groupCount: 4))
    }

    func testWideGroupColumnsScrollVerticallyWhenContentOverflows() {
        XCTAssertTrue(IslandWideGroupLayoutPolicy.allowsVerticalColumnScroll)
    }

    func testWideGroupLayoutUsesThreeBalancedColumnSlots() {
        let availableWidth: CGFloat = 1140

        XCTAssertEqual(
            IslandWideGroupLayoutPolicy.columnWidth(availableWidth: availableWidth),
            (availableWidth - IslandWideGroupLayoutPolicy.columnSpacing * 2) / 3
        )
        XCTAssertEqual(
            IslandWideGroupLayoutPolicy.contentWidth(groupCount: 2, availableWidth: availableWidth),
            availableWidth
        )
        XCTAssertEqual(
            IslandWideGroupLayoutPolicy.contentWidth(groupCount: 4, availableWidth: availableWidth),
            IslandWideGroupLayoutPolicy.columnWidth(availableWidth: availableWidth) * 4 + IslandWideGroupLayoutPolicy.columnSpacing * 3
        )
    }
}
