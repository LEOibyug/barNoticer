import Combine
import Foundation

struct AIGlobalMemoryEntry: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        case explicit
        case automatic
        var title: String { self == .explicit ? "用户指定" : "自动记录" }
    }

    var id: String { key }
    let key: String
    var content: String
    var source: Source
    var updatedAt: Date
}

struct AIGlobalMemorySnapshot: Codable, Equatable {
    var revision: UUID
    var epoch: UUID
    var entries: [AIGlobalMemoryEntry]

    static let empty = Self(revision: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
                            epoch: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), entries: [])
}

struct AIGlobalMemoryClearRequest: Identifiable {
    let id = UUID()
    let revision: UUID
    let entryCount: Int
    fileprivate init(revision: UUID, entryCount: Int) {
        self.revision = revision
        self.entryCount = entryCount
    }
}

enum AIGlobalMemoryError: LocalizedError {
    case invalidEntry, capacityExceeded, explicitEntryProtected, changedSinceConfirmation, clearedDuringRequest, changedDuringRequest, confirmationRequired

    var errorDescription: String? {
        switch self {
        case .invalidEntry: return "记忆名称需为 1～64 字，内容需为 1～1000 字，不能留空。"
        case .capacityExceeded: return "全局记忆已达容量上限（最多 64 条、合计 16000 字），请合并或精简已有记忆。"
        case .explicitEntryProtected: return "不能用自动推断覆盖用户明确保存的记忆，请以用户定义为准。"
        case .changedSinceConfirmation: return "全局记忆已发生变化，请重新发起清空并确认。"
        case .clearedDuringRequest: return "全局记忆已清空，本轮请求已停止，避免旧请求重新写入记忆。请重新发送。"
        case .changedDuringRequest: return "全局记忆已更新，已丢弃使用旧记忆生成的提醒文案。"
        case .confirmationRequired: return "清空全局记忆必须由用户在确认弹窗中再次确认。"
        }
    }
}

@MainActor
final class AIGlobalMemoryStore: ObservableObject {
    static let shared = AIGlobalMemoryStore()
    static let didChangeNotification = Notification.Name("AIGlobalMemoryDidChange")
    private static let storageKey = "AIGlobalMemory.v1"
    private let defaults: UserDefaults
    private var changeObserver: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        changeObserver = NotificationCenter.default.publisher(for: Self.didChangeNotification).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func read() throws -> AIGlobalMemorySnapshot {
        guard let data = defaults.data(forKey: Self.storageKey) else { return .empty }
        return try JSONDecoder().decode(AIGlobalMemorySnapshot.self, from: data)
    }

    func save(key: String, content: String, source: AIGlobalMemoryEntry.Source) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(key.count), (1...1_000).contains(content.count) else {
            throw AIGlobalMemoryError.invalidEntry
        }
        var snapshot = try read()
        if let index = snapshot.entries.firstIndex(where: { $0.key == key }) {
            let previous = snapshot.entries[index]
            guard previous.source != .explicit || source == .explicit || previous.content == content else {
                throw AIGlobalMemoryError.explicitEntryProtected
            }
            let effectiveSource: AIGlobalMemoryEntry.Source = previous.source == .explicit ? .explicit : source
            if previous.content == content, previous.source == effectiveSource { return }
            snapshot.entries[index] = .init(key: key, content: content, source: effectiveSource, updatedAt: Date())
        } else {
            snapshot.entries.append(.init(key: key, content: content, source: source, updatedAt: Date()))
        }
        guard snapshot.entries.count <= 64,
              snapshot.entries.reduce(0, { $0 + $1.key.count + $1.content.count }) <= 16_000 else {
            throw AIGlobalMemoryError.capacityExceeded
        }
        snapshot.revision = UUID()
        try persist(snapshot)
    }

    func requestClear(expectedRevision: UUID? = nil) throws -> AIGlobalMemoryClearRequest {
        let snapshot = try read()
        if let expectedRevision, expectedRevision != snapshot.revision {
            throw AIGlobalMemoryError.changedSinceConfirmation
        }
        return AIGlobalMemoryClearRequest(revision: snapshot.revision, entryCount: snapshot.entries.count)
    }

    /// Only UI confirmation actions call this. The model has no tool that accepts a confirmation token.
    func confirmClear(_ request: AIGlobalMemoryClearRequest) throws {
        guard try read().revision == request.revision else { throw AIGlobalMemoryError.changedSinceConfirmation }
        try persist(AIGlobalMemorySnapshot(revision: UUID(), epoch: UUID(), entries: []))
    }

    /// Serialized only when the model explicitly requests the read tool.
    func toolContent() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(read().entries), as: UTF8.self)
    }

    private func persist(_ snapshot: AIGlobalMemorySnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
