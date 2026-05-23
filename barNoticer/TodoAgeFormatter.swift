import Foundation

enum TodoAgeFormatter {
    static func elapsedText(since createdAt: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(createdAt))

        let minute: TimeInterval = 60
        let hour = minute * 60
        let day = hour * 24
        let week = day * 7
        let month = day * 30
        let year = day * 365

        if elapsed < hour {
            return "一小时内"
        }

        switch elapsed {
        case ..<day:
            return elapsedText(elapsed, primary: (hour, "小时"), secondary: (minute, "分钟"))
        case ..<week:
            return elapsedText(elapsed, primary: (day, "天"), secondary: (hour, "小时"))
        case ..<month:
            return elapsedText(elapsed, primary: (week, "周"), secondary: (day, "天"))
        case ..<year:
            return elapsedText(elapsed, primary: (month, "个月"), secondary: (week, "周"))
        default:
            return elapsedText(elapsed, primary: (year, "年"), secondary: (month, "个月"))
        }
    }

    private static func elapsedText(
        _ elapsed: TimeInterval,
        primary: (duration: TimeInterval, label: String),
        secondary: (duration: TimeInterval, label: String)
    ) -> String {
        let primaryCount = Int(elapsed / primary.duration)
        let remaining = elapsed - TimeInterval(primaryCount) * primary.duration
        let secondaryCount = Int(remaining / secondary.duration)

        if secondaryCount > 0 {
            return "\(primaryCount)\(primary.label)\(secondaryCount)\(secondary.label)前"
        }

        return "\(primaryCount)\(primary.label)前"
    }
}
