import Combine
import Foundation

enum SummaryStoreError: LocalizedError {
    case invalidSummary
    case unsupportedVersion(Int)
    case conflictingID(UUID)
    case duplicateID(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidSummary:
            return "总结标题和正文不能为空，且结束时间必须晚于开始时间。"
        case let .unsupportedVersion(version):
            return "不支持的总结文件版本：\(version)。"
        case let .conflictingID(id):
            return "总结 ID 已存在且内容不同，未覆盖原文件：\(id.uuidString)。"
        case let .duplicateID(id):
            return "多个总结文件使用了同一 ID：\(id.uuidString)，请检查重复文件。"
        }
    }
}

@MainActor
final class SummaryStore: ObservableObject {
    static let shared = SummaryStore()

    let directoryURL: URL
    @Published private(set) var summaries: [SavedSummary] = []
    @Published private(set) var loadError: String?
    private var fileURLsByID: [UUID: URL] = [:]

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("barNoticer/Summaries", isDirectory: true)
        reload()
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            summaries = []
            fileURLsByID = [:]
            loadError = nil
            return
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            loadError = "读取总结目录失败：\(error.localizedDescription)"
            return
        }

        var loaded: [SavedSummary] = []
        var loadedURLs: [UUID: URL] = [:]
        var errors: [String] = []
        for file in files {
            do {
                let summary = try Self.read(file)
                guard loadedURLs[summary.id] == nil else {
                    throw SummaryStoreError.duplicateID(summary.id)
                }
                loaded.append(summary)
                loadedURLs[summary.id] = file
            } catch {
                errors.append("\(file.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        summaries = Self.sorted(loaded)
        fileURLsByID = loadedURLs
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func save(_ summary: SavedSummary) throws {
        do {
            try Self.validate(summary)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let destination = fileURLsByID[summary.id] ?? directoryURL.appendingPathComponent(Self.filename(for: summary.id))
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Self.read(destination) == summary else {
                    throw SummaryStoreError.conflictingID(summary.id)
                }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .custom { date, encoder in
                    var container = encoder.singleValueContainer()
                    try container.encode(Self.encodeDate(date))
                }
                let data = try encoder.encode(summary)
                let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try data.write(to: temporaryURL, options: .atomic)
                // Moving a complete file publishes it without replacing an existing UUID file.
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            }
            summaries = Self.sorted(summaries.filter { $0.id != summary.id } + [summary])
            fileURLsByID[summary.id] = destination
        } catch {
            loadError = "保存总结失败：\(error.localizedDescription)"
            throw error
        }
    }

    private static func filename(for id: UUID) -> String {
        id.uuidString.lowercased() + ".json"
    }

    private static func sorted(_ summaries: [SavedSummary]) -> [SavedSummary] {
        summaries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func validate(_ summary: SavedSummary) throws {
        guard summary.formatVersion == 1 else { throw SummaryStoreError.unsupportedVersion(summary.formatVersion) }
        guard !summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.periodStart.timeIntervalSinceReferenceDate.isFinite,
              summary.periodEnd.timeIntervalSinceReferenceDate.isFinite,
              summary.createdAt.timeIntervalSinceReferenceDate.isFinite,
              summary.periodEnd > summary.periodStart else {
            throw SummaryStoreError.invalidSummary
        }
    }

    private static func read(_ url: URL) throws -> SavedSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = decodeDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "日期必须是 ISO8601 日期时间。")
            }
            return date
        }
        let summary = try decoder.decode(SavedSummary.self, from: Data(contentsOf: url))
        try validate(summary)
        return summary
    }

    // Retain subsecond timestamps rather than truncating them to whole seconds.
    private nonisolated static func encodeDate(_ date: Date) -> String {
        var seconds = floor(date.timeIntervalSinceReferenceDate)
        let fraction = date.timeIntervalSinceReferenceDate - seconds
        var nanoseconds = Int((fraction * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        let formatter = ISO8601DateFormatter()
        let base = formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
        return String(base.dropLast()) + String(format: ".%09dZ", nanoseconds)
    }

    private nonisolated static func decodeDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let dot = text.firstIndex(of: ".") {
            let fractionalStart = text.index(after: dot)
            let fractionalEnd = text[fractionalStart...].firstIndex(where: { !$0.isNumber }) ?? text.endIndex
            let digits = text[fractionalStart..<fractionalEnd]
            guard !digits.isEmpty, digits.count <= 9,
                  let fraction = Double("0." + digits),
                  let base = formatter.date(from: String(text[..<dot]) + text[fractionalEnd...]) else { return nil }
            return Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate + fraction)
        }
        return formatter.date(from: text)
    }
}
