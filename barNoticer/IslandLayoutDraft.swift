import Foundation

struct IslandLayoutDraft: Equatable {
    var hotZoneOffsetX: Double
    var hotZoneOffsetY: Double
    var hotZoneWidth: Double
    var hotZoneHeight: Double
    var islandOffsetX: Double
    var islandOffsetY: Double
    var islandTopContentInset: Double

    init(settings: IslandLayoutSettings) {
        hotZoneOffsetX = Double(settings.hotZoneOffsetX)
        hotZoneOffsetY = Double(settings.hotZoneOffsetY)
        hotZoneWidth = Double(settings.hotZoneWidth)
        hotZoneHeight = Double(settings.hotZoneHeight)
        islandOffsetX = Double(settings.islandOffsetX)
        islandOffsetY = Double(settings.islandOffsetY)
        islandTopContentInset = Double(settings.islandTopContentInset)
    }

    static let standardDefaults = IslandLayoutDraft(settings: IslandLayoutSettings(mode: .standard))

    static func load(mode: IslandDisplayMode, defaults: UserDefaults = .standard) -> IslandLayoutDraft {
        IslandLayoutDraft(settings: IslandLayoutSettings(defaults: defaults, mode: mode))
    }

    func save(mode: IslandDisplayMode, defaults: UserDefaults = .standard) {
        defaults.set(hotZoneOffsetX, forKey: IslandLayoutSettings.hotZoneOffsetXKey(for: mode))
        defaults.set(hotZoneOffsetY, forKey: IslandLayoutSettings.hotZoneOffsetYKey(for: mode))
        defaults.set(hotZoneWidth, forKey: IslandLayoutSettings.hotZoneWidthKey(for: mode))
        defaults.set(hotZoneHeight, forKey: IslandLayoutSettings.hotZoneHeightKey(for: mode))
        defaults.set(islandOffsetX, forKey: IslandLayoutSettings.islandOffsetXKey(for: mode))
        defaults.set(islandOffsetY, forKey: IslandLayoutSettings.islandOffsetYKey(for: mode))
        defaults.set(islandTopContentInset, forKey: IslandLayoutSettings.islandTopContentInsetKey(for: mode))
    }

    static func reset(mode: IslandDisplayMode, defaults: UserDefaults = .standard) {
        let draft = IslandLayoutDraft(settings: IslandLayoutSettings(mode: mode))
        draft.save(mode: mode, defaults: defaults)
    }
}
