import Foundation

final class ReminderHistoryStore {
    private let defaults: UserDefaults
    private let storageKey = "ReminderHistoryEntries"
    private let maxEntries = 80

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entries() -> [ReminderHistoryEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder.reminder.decode([ReminderHistoryEntry].self, from: data)
        else {
            return []
        }
        return decoded.sorted { $0.timestamp > $1.timestamp }
    }

    func recentEntries(now: Date = Date(), limit: Int = 5, within interval: TimeInterval = 7_200) -> [ReminderHistoryEntry] {
        Array(entries()
            .filter { now.timeIntervalSince($0.timestamp) <= interval }
            .prefix(limit))
    }

    func record(_ entry: ReminderHistoryEntry) {
        var all = entries()
        all.insert(entry, at: 0)
        all = Array(all.prefix(maxEntries))
        if let data = try? JSONEncoder.reminder.encode(all) {
            defaults.set(data, forKey: storageKey)
        }
    }

    func hasRecentTrigger(_ trigger: ReminderTrigger, now: Date = Date(), dedupeWindow: TimeInterval) -> Bool {
        entries().contains { entry in
            entry.trigger == trigger && now.timeIntervalSince(entry.timestamp) <= dedupeWindow
        }
    }

    func hasRecentReference(_ todoID: UUID, now: Date = Date(), dedupeWindow: TimeInterval) -> Bool {
        entries().contains { entry in
            entry.referencedTodoIDs.contains(todoID) && now.timeIntervalSince(entry.timestamp) <= dedupeWindow
        }
    }

    func hasRecentReference(_ todoID: UUID, excluding trigger: ReminderTrigger, now: Date = Date(), dedupeWindow: TimeInterval) -> Bool {
        entries().contains { entry in
            entry.trigger != trigger && entry.referencedTodoIDs.contains(todoID) && now.timeIntervalSince(entry.timestamp) <= dedupeWindow
        }
    }

    func mark(id: UUID, status: ReminderHistoryEntry.Status) {
        var all = entries()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].status = status
        if let data = try? JSONEncoder.reminder.encode(all) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

private extension JSONEncoder {
    static var reminder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var reminder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
