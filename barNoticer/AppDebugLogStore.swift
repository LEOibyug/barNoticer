import Foundation

struct AppDebugLogStore {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    static let shared = AppDebugLogStore()

    let directory: URL
    let retentionDays: Int
    let maxFileSize: UInt64

    init(
        directory: URL? = nil,
        retentionDays: Int = 7,
        maxFileSize: UInt64 = 1_048_576
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.retentionDays = retentionDays
        self.maxFileSize = maxFileSize
    }

    var logFileURL: URL {
        directory.appendingPathComponent("barNoticer.log")
    }

    func write(
        _ level: Level,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cleanupIfNeeded()

        let line = [
            Self.timestampFormatter.string(from: Date()),
            "[\(level.rawValue)]",
            "[\(sanitize(category))]",
            sanitize(message),
            format(metadata: metadata)
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            + "\n"

        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: logFileURL, options: .atomic)
        }
    }

    private func cleanupIfNeeded() throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attributes[.size] as? UInt64,
           size > maxFileSize {
            try? FileManager.default.removeItem(at: logFileURL)
        }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        for file in files where file.lastPathComponent.hasSuffix(".log") {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func format(metadata: [String: String]) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key))=\(sanitize($0.value))" }
            .joined(separator: " ")
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("barNoticer/Logs", isDirectory: true)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
