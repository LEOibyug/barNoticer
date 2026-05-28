import Foundation

enum TodoDeadlineFormatter {
    static func cardText(for item: TodoItem, now: Date = Date()) -> String? {
        guard !item.isCompleted else { return nil }
        guard let date = item.nextOccurrence(after: now) else { return nil }
        switch item.scheduleKind {
        case .none:
            return nil
        case .singleDeadline:
            return cardText(for: date, now: now)
        case .multipleTimes:
            return "下次 \(shortText(for: date, now: now)) · \(remainingText(until: date, now: now))"
        case .recurring:
            let rule = item.recurrenceRule?.title ?? "重复"
            return "\(rule) · 下次 \(shortText(for: date, now: now)) · \(remainingText(until: date, now: now))"
        }
    }

    static func cardText(for date: Date, now: Date = Date()) -> String {
        "DDL \(shortText(for: date, now: now)) · \(remainingText(until: date, now: now))"
    }

    static func shortText(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)

        if calendar.isDateInToday(date) {
            return "今天 \(time)"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(time)"
        }
        return dateFormatter.string(from: date)
    }

    static func stateText(for date: Date, now: Date = Date()) -> String {
        if date < now {
            return "已逾期"
        }
        if date.timeIntervalSince(now) <= 86_400 {
            return "24小时内"
        }
        return "有截止"
    }

    static func remainingText(until date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 0 {
            return "已逾期\(durationText(abs(interval)))"
        }
        return "剩余\(durationText(interval))"
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 3_600 {
            return "一小时内"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600

        if days > 0 {
            return hours > 0 ? "\(days)天\(hours)小时" : "\(days)天"
        }
        return "\(max(1, hours))小时"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
