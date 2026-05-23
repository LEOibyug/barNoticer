import Foundation

enum IslandDisplayMode: String, CaseIterable, Identifiable {
    case standard
    case wide

    static let storageKey = "island.displayMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "普通"
        case .wide: "宽体"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "capsule"
        case .wide: "rectangle.split.3x1"
        }
    }

    var widthMultiplier: CGFloat {
        switch self {
        case .standard: 1
        case .wide: 3
        }
    }

    var storagePrefix: String {
        switch self {
        case .standard: "island"
        case .wide: "island.wide"
        }
    }
}
