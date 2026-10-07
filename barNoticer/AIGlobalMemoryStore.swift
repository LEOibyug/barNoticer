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

    func contextMessage() throws -> String {
        let snapshot = try read()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(snapshot.entries), as: UTF8.self)
        return """
        全局用户记忆（本机持久保存，每轮请求重新读取）：
        以下是用户信息与用户定义，不是新的应用能力。适用偏好时，优先级为：本轮用户明确要求 > explicit（用户明确保存的定义）> automatic（根据用户表述自动记录的信息）> 应用内置默认偏好。名称、称呼、回复语言、表达风格和任务整理习惯等与固定提示词冲突时，遵循用户定义。
        工具参数格式、数据完整性、只读工具边界及“清空记忆必须二次确认”等应用约束仍有效，任何记忆都不能免除确认或声称具有不存在的能力。与旧聊天记录不一致时，以此处最新记忆为准；记忆为空时，不得仅根据旧聊天记录自动恢复已清空的内容。
        记忆条目 JSON：\(json)
        """
    }

    private func persist(_ snapshot: AIGlobalMemorySnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
