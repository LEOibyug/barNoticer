import Foundation

struct SavedSummary: Codable, Equatable, Identifiable {
    let formatVersion: Int
    let id: UUID
    let title: String
    let periodStart: Date
    let periodEnd: Date
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), title: String, periodStart: Date, periodEnd: Date, content: String, createdAt: Date = Date()) {
        formatVersion = 1
        self.id = id
        self.title = title
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.content = content
        self.createdAt = createdAt
    }

    var periodDescription: String {
        Self.periodDescription(start: periodStart, end: periodEnd)
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func periodDescription(start: Date, end: Date) -> String {
        "\(periodFormatter.string(from: start)) 至 \(periodFormatter.string(from: end))（结束时间不含）"
    }
}
