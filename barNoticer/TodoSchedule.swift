import Foundation

enum TodoScheduleKind: String, CaseIterable, Codable, Equatable, Identifiable {
    case none
    case singleDeadline
    case multipleTimes
    case recurring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "无时间"
        case .singleDeadline:
            return "单次 DDL"
        case .multipleTimes:
            return "多个时间点"
        case .recurring:
            return "重复事项"
        }
    }
}

enum TodoRecurrenceRule: Codable, Equatable, Hashable, Identifiable {
    case daily
    case weekly
    case monthly
    case everyNDays(Int)

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .daily:
            return "daily"
        case .weekly:
            return "weekly"
        case .monthly:
            return "monthly"
        case let .everyNDays(days):
            return "every_n_days:\(max(1, days))"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "daily":
            self = .daily
        case "weekly":
            self = .weekly
        case "monthly":
            self = .monthly
        default:
            let prefix = "every_n_days:"
            guard rawValue.hasPrefix(prefix),
                  let days = Int(rawValue.dropFirst(prefix.count)),
                  days > 0
            else {
                return nil
            }
            self = .everyNDays(days)
        }
    }

    var title: String {
        switch self {
        case .daily:
            return "每天"
        case .weekly:
            return "每周"
        case .monthly:
            return "每月"
        case let .everyNDays(days):
            return "每\(days)天"
        }
    }

    var intervalDays: Int? {
        if case let .everyNDays(days) = self {
            return days
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let rule = TodoRecurrenceRule(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported recurrence rule: \(rawValue)")
        }
        self = rule
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TodoSchedulePolicy {
    static func nextOccurrence(
        deadlineAt: Date?,
        scheduledTimes: [Date],
        recurrenceRule: TodoRecurrenceRule?,
        recurrenceAnchor: Date?,
        lastCompletedOccurrenceAt: Date?,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        if let recurrenceRule, let recurrenceAnchor {
            return nextRecurringOccurrence(
                rule: recurrenceRule,
                anchor: recurrenceAnchor,
                lastCompletedOccurrenceAt: lastCompletedOccurrenceAt,
                after: now,
                calendar: calendar
            )
        }

        if !scheduledTimes.isEmpty {
            return scheduledTimes
                .filter { $0 > now }
                .sorted()
                .first
        }

        return deadlineAt
    }

    static func nextRecurringOccurrence(
        rule: TodoRecurrenceRule,
        anchor: Date,
        lastCompletedOccurrenceAt: Date?,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let lowerBound = max(now, lastCompletedOccurrenceAt ?? .distantPast)
        var occurrence = anchor

        while occurrence <= lowerBound {
            occurrence = addingOneInterval(rule: rule, to: occurrence, preservingDayFrom: anchor, calendar: calendar)
        }

        return occurrence
    }

    private static func addingOneInterval(
        rule: TodoRecurrenceRule,
        to date: Date,
        preservingDayFrom anchor: Date,
        calendar: Calendar
    ) -> Date {
        switch rule {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date.addingTimeInterval(7 * 86_400)
        case .monthly:
            return nextMonthlyDate(after: date, preservingDayFrom: anchor, calendar: calendar)
        case let .everyNDays(days):
            return calendar.date(byAdding: .day, value: max(1, days), to: date) ?? date.addingTimeInterval(TimeInterval(max(1, days)) * 86_400)
        }
    }

    private static func nextMonthlyDate(after date: Date, preservingDayFrom anchor: Date, calendar: Calendar) -> Date {
        let anchorComponents = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: date) else { return date }
        let monthRange = calendar.range(of: .day, in: .month, for: nextMonth)
        let day = min(anchorComponents.day ?? 1, monthRange?.count ?? anchorComponents.day ?? 1)
        var components = calendar.dateComponents([.year, .month], from: nextMonth)
        components.day = day
        components.hour = anchorComponents.hour
        components.minute = anchorComponents.minute
        components.second = anchorComponents.second
        components.nanosecond = anchorComponents.nanosecond
        return calendar.date(from: components) ?? nextMonth
    }
}

extension JSONEncoder {
    static var iso8601Encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
