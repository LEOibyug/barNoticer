import CoreGraphics
import Foundation

struct ReminderSettings: Equatable {
    static let didChangeNotification = Notification.Name("ReminderSettingsDidChange")
    static let previewDidChangeNotification = Notification.Name("ReminderSettingsPreviewDidChange")
    static let boundaryPreviewDidChangeNotification = Notification.Name("ReminderSettingsBoundaryPreviewDidChange")
    static let panelPreviewDidChangeNotification = Notification.Name("ReminderSettingsPanelPreviewDidChange")
    static let previewDidEndNotification = Notification.Name("ReminderSettingsPreviewDidEnd")
    static let previewHotZoneFlashExpansionUserInfoKey = "hotZoneFlashExpansion"

    private static let aiPollingEnabledKey = "ReminderSettingsAIPollingEnabled"
    private static let pollingIntervalKey = "ReminderSettingsPollingInterval"
    private static let systemNotificationsEnabledKey = "ReminderSettingsSystemNotificationsEnabled"
    private static let toneKey = "ReminderSettingsTone"
    private static let dedupeWindowKey = "ReminderSettingsDedupeWindow"
    private static let hotZoneFlashExpansionKey = "ReminderSettingsHotZoneFlashExpansion"
    private static let reminderPanelOffsetXKey = "ReminderSettingsPanelOffsetX"
    private static let reminderPanelOffsetYKey = "ReminderSettingsPanelOffsetY"
    private static let reminderPanelWidthKey = "ReminderSettingsPanelWidth"
    private static let reminderPanelTopContentInsetKey = "ReminderSettingsPanelTopContentInset"

    var aiPollingEnabled: Bool = false
    var pollingInterval: TimeInterval = 1_800
    var systemNotificationsEnabled: Bool = true
    var tone: ReminderTone = .playful
    var dedupeWindow: TimeInterval = 1_800
    var hotZoneFlashExpansion: Double = 18
    var reminderPanelOffsetX: Double = 0
    var reminderPanelOffsetY: Double = 0
    var reminderPanelWidth: Double = 392
    var reminderPanelTopContentInset: Double = Double(ReminderPresentationTiming.defaultPanelTopContentInset)

    init(
        aiPollingEnabled: Bool = false,
        pollingInterval: TimeInterval = 1_800,
        systemNotificationsEnabled: Bool = true,
        tone: ReminderTone = .playful,
        dedupeWindow: TimeInterval = 1_800,
        hotZoneFlashExpansion: Double = 18,
        reminderPanelOffsetX: Double = 0,
        reminderPanelOffsetY: Double = 0,
        reminderPanelWidth: Double = 392,
        reminderPanelTopContentInset: Double = Double(ReminderPresentationTiming.defaultPanelTopContentInset)
    ) {
        self.aiPollingEnabled = aiPollingEnabled
        self.pollingInterval = pollingInterval
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.tone = tone
        self.dedupeWindow = dedupeWindow
        self.hotZoneFlashExpansion = hotZoneFlashExpansion
        self.reminderPanelOffsetX = reminderPanelOffsetX
        self.reminderPanelOffsetY = reminderPanelOffsetY
        self.reminderPanelWidth = reminderPanelWidth
        self.reminderPanelTopContentInset = reminderPanelTopContentInset
    }

    init(defaults: UserDefaults) {
        self.init(
            aiPollingEnabled: defaults.bool(forKey: Self.aiPollingEnabledKey),
            pollingInterval: defaults.object(forKey: Self.pollingIntervalKey) == nil ? 1_800 : max(300, defaults.double(forKey: Self.pollingIntervalKey)),
            systemNotificationsEnabled: defaults.object(forKey: Self.systemNotificationsEnabledKey) == nil ? true : defaults.bool(forKey: Self.systemNotificationsEnabledKey),
            tone: defaults.string(forKey: Self.toneKey).flatMap(ReminderTone.init(rawValue:)) ?? .playful,
            dedupeWindow: defaults.object(forKey: Self.dedupeWindowKey) == nil ? 1_800 : max(300, defaults.double(forKey: Self.dedupeWindowKey)),
            hotZoneFlashExpansion: defaults.object(forKey: Self.hotZoneFlashExpansionKey) == nil ? 18 : max(0, defaults.double(forKey: Self.hotZoneFlashExpansionKey)),
            reminderPanelOffsetX: defaults.double(forKey: Self.reminderPanelOffsetXKey),
            reminderPanelOffsetY: defaults.double(forKey: Self.reminderPanelOffsetYKey),
            reminderPanelWidth: defaults.object(forKey: Self.reminderPanelWidthKey) == nil ? 392 : max(320, defaults.double(forKey: Self.reminderPanelWidthKey)),
            reminderPanelTopContentInset: defaults.object(forKey: Self.reminderPanelTopContentInsetKey) == nil ? Double(ReminderPresentationTiming.defaultPanelTopContentInset) : max(12, defaults.double(forKey: Self.reminderPanelTopContentInsetKey))
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(aiPollingEnabled, forKey: Self.aiPollingEnabledKey)
        defaults.set(pollingInterval, forKey: Self.pollingIntervalKey)
        defaults.set(systemNotificationsEnabled, forKey: Self.systemNotificationsEnabledKey)
        defaults.set(tone.rawValue, forKey: Self.toneKey)
        defaults.set(dedupeWindow, forKey: Self.dedupeWindowKey)
        defaults.set(hotZoneFlashExpansion, forKey: Self.hotZoneFlashExpansionKey)
        defaults.set(reminderPanelOffsetX, forKey: Self.reminderPanelOffsetXKey)
        defaults.set(reminderPanelOffsetY, forKey: Self.reminderPanelOffsetYKey)
        defaults.set(reminderPanelWidth, forKey: Self.reminderPanelWidthKey)
        defaults.set(reminderPanelTopContentInset, forKey: Self.reminderPanelTopContentInsetKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    static func requestPresentationPreview(hotZoneFlashExpansion: Double) {
        NotificationCenter.default.post(
            name: previewDidChangeNotification,
            object: nil,
            userInfo: [previewHotZoneFlashExpansionUserInfoKey: hotZoneFlashExpansion]
        )
    }

    static func requestBoundaryPreview(hotZoneFlashExpansion: Double) {
        NotificationCenter.default.post(
            name: boundaryPreviewDidChangeNotification,
            object: nil,
            userInfo: [previewHotZoneFlashExpansionUserInfoKey: hotZoneFlashExpansion]
        )
    }

    static func requestPanelPreview() {
        NotificationCenter.default.post(name: panelPreviewDidChangeNotification, object: nil)
    }

    static func endPresentationPreview() {
        NotificationCenter.default.post(name: previewDidEndNotification, object: nil)
    }

    func reminderCollapsedFrame(in screenFrame: CGRect, islandLayout: IslandLayoutSettings) -> CGRect {
        islandLayout.hotZoneFrame(in: screenFrame)
    }

    func reminderPanelFrame(in screenFrame: CGRect, islandLayout: IslandLayoutSettings) -> CGRect {
        CGRect(
            x: screenFrame.midX - CGFloat(reminderPanelWidth) / 2 + CGFloat(reminderPanelOffsetX),
            y: screenFrame.maxY - ReminderPresentationTiming.panelTopInset - reminderPanelHeight - CGFloat(reminderPanelOffsetY),
            width: CGFloat(reminderPanelWidth),
            height: reminderPanelHeight
        )
    }

    var reminderPanelHeight: CGFloat {
        ReminderPresentationTiming.panelBaseHeight + CGFloat(reminderPanelTopContentInset)
    }
}

struct ReminderPanelRevealGeometry: Equatable {
    let collapsedFrameInScreen: CGRect
    let finalFrameInScreen: CGRect

    var contentFrame: CGRect {
        CGRect(origin: .zero, size: finalFrameInScreen.size)
    }

    var collapsedFrameInContentCoordinates: CGRect {
        CGRect(
            x: collapsedFrameInScreen.minX - finalFrameInScreen.minX,
            y: collapsedFrameInScreen.minY - finalFrameInScreen.minY,
            width: collapsedFrameInScreen.width,
            height: collapsedFrameInScreen.height
        )
    }
}

enum ReminderPresentationPreviewAction {
    static let title = "提醒示例"

    static func trigger(hotZoneFlashExpansion: Double) {
        ReminderSettings.requestPresentationPreview(hotZoneFlashExpansion: hotZoneFlashExpansion)
    }
}

enum ReminderPresentationTiming {
    static let panelAutoCloseDelay: TimeInterval = 4
    static let flashDuration: TimeInterval = 2.15
    static let panelDelayAfterFlash: TimeInterval = flashDuration
    static let panelExpansionDuration: TimeInterval = 0.72
    static let panelCollapseDuration: TimeInterval = 0.56
    static let panelTopInset: CGFloat = 8
    static let panelBaseHeight: CGFloat = 226
    static let defaultPanelTopContentInset: CGFloat = 34
}

enum ReminderFlashRippleStyle {
    static let ringCount = 5
    static let minimumExpansionStep: CGFloat = 4
    static let staggerDelay: TimeInterval = 0.18
    static let pulseDuration: TimeInterval = 1.02
    static let totalDuration: TimeInterval = pulseDuration + staggerDelay * Double(ringCount - 1)
}

enum ReminderTone: String, CaseIterable, Identifiable, Codable {
    case playful
    case professional
    case furious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playful:
            return "轻松有趣"
        case .professional:
            return "冷静专业"
        case .furious:
            return "暴躁催促"
        }
    }

    var promptDescription: String {
        switch self {
        case .playful:
            return "轻松、有一点趣味，但不要幼稚。"
        case .professional:
            return "冷静、简洁、专业。"
        case .furious:
            return "催促感强、直接，但不要辱骂用户。"
        }
    }
}
