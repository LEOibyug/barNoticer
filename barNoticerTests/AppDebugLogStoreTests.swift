import XCTest
@testable import barNoticer

final class AppDebugLogStoreTests: XCTestCase {
    func testWritesSanitizedEventsToLogFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDebugLogStoreTests-\(UUID().uuidString)")
        let store = AppDebugLogStore(directory: directory, retentionDays: 7, maxFileSize: 8_192)

        try store.write(.info, category: "AI", message: "Started request", metadata: ["promptLength": "42"])

        let content = try String(contentsOf: store.logFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[INFO] [AI] Started request"))
        XCTAssertTrue(content.contains("promptLength=42"))
    }

    func testTruncatesOversizedLogBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDebugLogStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("barNoticer.log")
        try String(repeating: "x", count: 256).write(to: logURL, atomically: true, encoding: .utf8)
        let store = AppDebugLogStore(directory: directory, retentionDays: 7, maxFileSize: 64)

        try store.write(.info, category: "AI", message: "Fresh")

        let content = try String(contentsOf: store.logFileURL, encoding: .utf8)
        XCTAssertFalse(content.contains(String(repeating: "x", count: 128)))
        XCTAssertTrue(content.contains("Fresh"))
    }
}
