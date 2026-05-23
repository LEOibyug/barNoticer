import Foundation
import SwiftUI

enum TodoPriority: String, CaseIterable, Codable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        }
    }

    var systemImage: String {
        switch self {
        case .high: "flag.fill"
        case .medium: "flag"
        case .low: "flag.slash"
        }
    }

    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }

    var islandColor: Color {
        switch self {
        case .high: Color(red: 1.0, green: 0.34, blue: 0.34)
        case .medium: Color(red: 1.0, green: 0.73, blue: 0.28)
        case .low: Color(red: 0.62, green: 0.78, blue: 1.0)
        }
    }

    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}
