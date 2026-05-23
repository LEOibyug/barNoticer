import CoreGraphics
import Foundation

struct IslandLayoutSettings: Equatable {
    static let didChangeNotification = Notification.Name("IslandLayoutSettingsDidChange")
    static let previewDidChangeNotification = Notification.Name("IslandLayoutSettingsPreviewDidChange")
    static let previewDidEndNotification = Notification.Name("IslandLayoutSettingsPreviewDidEnd")
    static let previewKindUserInfoKey = "previewKind"

    enum PreviewKind: String {
        case hotZone
        case island
    }

    static let hotZoneOffsetXKey = hotZoneOffsetXKey(for: .standard)
    static let hotZoneOffsetYKey = hotZoneOffsetYKey(for: .standard)
    static let hotZoneWidthKey = hotZoneWidthKey(for: .standard)
    static let hotZoneHeightKey = hotZoneHeightKey(for: .standard)
    static let islandOffsetXKey = islandOffsetXKey(for: .standard)
    static let islandOffsetYKey = islandOffsetYKey(for: .standard)
    static let islandTopContentInsetKey = islandTopContentInsetKey(for: .standard)

    static let defaultHotZoneSize = CGSize(width: 220, height: 36)
    static let defaultIslandSize = CGSize(width: 392, height: 318)
    static let defaultIslandTopInset: CGFloat = 8
    static let defaultIslandTopContentInset: CGFloat = 34

    static func hotZoneOffsetXKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).hotZoneOffsetX"
    }

    static func hotZoneOffsetYKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).hotZoneOffsetY"
    }

    static func hotZoneWidthKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).hotZoneWidth"
    }

    static func hotZoneHeightKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).hotZoneHeight"
    }

    static func islandOffsetXKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).panelOffsetX"
    }

    static func islandOffsetYKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).panelOffsetY"
    }

    static func islandTopContentInsetKey(for mode: IslandDisplayMode) -> String {
        "\(mode.storagePrefix).topContentInset"
    }

    static func notifyChanged(previewKind: PreviewKind?) {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)

        if let previewKind {
            NotificationCenter.default.post(
                name: previewDidChangeNotification,
                object: nil,
                userInfo: [previewKindUserInfoKey: previewKind.rawValue]
            )
        } else {
            NotificationCenter.default.post(name: previewDidEndNotification, object: nil)
        }
    }

    static func notifyLayoutChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    var mode: IslandDisplayMode = .standard
    var hotZoneOffsetX: CGFloat = 0
    var hotZoneOffsetY: CGFloat = 0
    var hotZoneWidth: CGFloat = Self.defaultHotZoneSize.width
    var hotZoneHeight: CGFloat = Self.defaultHotZoneSize.height
    var islandOffsetX: CGFloat = 0
    var islandOffsetY: CGFloat = 0
    var islandTopContentInset: CGFloat = Self.defaultIslandTopContentInset

    init(
        mode: IslandDisplayMode = .standard,
        hotZoneOffsetX: CGFloat = 0,
        hotZoneOffsetY: CGFloat = 0,
        hotZoneWidth: CGFloat = Self.defaultHotZoneSize.width,
        hotZoneHeight: CGFloat = Self.defaultHotZoneSize.height,
        islandOffsetX: CGFloat = 0,
        islandOffsetY: CGFloat = 0,
        islandTopContentInset: CGFloat = Self.defaultIslandTopContentInset
    ) {
        self.mode = mode
        self.hotZoneOffsetX = hotZoneOffsetX
        self.hotZoneOffsetY = hotZoneOffsetY
        self.hotZoneWidth = hotZoneWidth
        self.hotZoneHeight = hotZoneHeight
        self.islandOffsetX = islandOffsetX
        self.islandOffsetY = islandOffsetY
        self.islandTopContentInset = islandTopContentInset
    }

    init(defaults: UserDefaults) {
        let storedMode = defaults.string(forKey: IslandDisplayMode.storageKey)
        let mode = storedMode.flatMap(IslandDisplayMode.init(rawValue:)) ?? .standard
        self.init(defaults: defaults, mode: mode)
    }

    init(defaults: UserDefaults, mode: IslandDisplayMode) {
        self.init(
            mode: mode,
            hotZoneOffsetX: CGFloat(defaults.double(forKey: Self.hotZoneOffsetXKey(for: mode))),
            hotZoneOffsetY: CGFloat(defaults.double(forKey: Self.hotZoneOffsetYKey(for: mode))),
            hotZoneWidth: defaults.object(forKey: Self.hotZoneWidthKey(for: mode)) == nil ? Self.defaultHotZoneSize.width : CGFloat(defaults.double(forKey: Self.hotZoneWidthKey(for: mode))),
            hotZoneHeight: defaults.object(forKey: Self.hotZoneHeightKey(for: mode)) == nil ? Self.defaultHotZoneSize.height : CGFloat(defaults.double(forKey: Self.hotZoneHeightKey(for: mode))),
            islandOffsetX: CGFloat(defaults.double(forKey: Self.islandOffsetXKey(for: mode))),
            islandOffsetY: CGFloat(defaults.double(forKey: Self.islandOffsetYKey(for: mode))),
            islandTopContentInset: defaults.object(forKey: Self.islandTopContentInsetKey(for: mode)) == nil ? Self.defaultIslandTopContentInset : CGFloat(defaults.double(forKey: Self.islandTopContentInsetKey(for: mode)))
        )
    }

    func hotZoneFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - hotZoneWidth / 2 + hotZoneOffsetX,
            y: screenFrame.maxY - hotZoneHeight - hotZoneOffsetY,
            width: hotZoneWidth,
            height: hotZoneHeight
        )
    }

    func islandFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - islandPanelWidth / 2 + islandOffsetX,
            y: screenFrame.maxY - Self.defaultIslandTopInset - islandPanelHeight - islandOffsetY,
            width: islandPanelWidth,
            height: islandPanelHeight
        )
    }

    func collapsedIslandFrame(in screenFrame: CGRect) -> CGRect {
        hotZoneFrame(in: screenFrame)
    }

    private var islandPanelHeight: CGFloat {
        Self.defaultIslandSize.height + islandTopContentInset
    }

    var islandPanelWidth: CGFloat {
        Self.defaultIslandSize.width * mode.widthMultiplier
    }
}
