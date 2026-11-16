import XCTest
@testable import barNoticer

final class SummaryStoreTests: XCTestCase {
    @MainActor
    func testInitializationAndReloadDoNotCreateMissingDirectory() {
        let directory = makeDirectoryURL()
        let store = SummaryStore(directoryURL: directory)

        store.reload()

        XCTAssertEqual(store.directoryURL, directory)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertNil(store.loadError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testSaveReloadAndNewInstancePreserveExactMetadataAndOneFilePerSummary() throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000.1234567)
        let older = SavedSummary(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "  一周回顾  ", periodStart: start, periodEnd: start.addingTimeInterval(604_800),
            content: "# 完成事项\n\n- 设计 ✅\n- 实现\n", createdAt: start.addingTimeInterval(700_000.7654321)
        )
        let newer = SavedSummary(
            title: "下一周", periodStart: older.periodEnd, periodEnd: older.periodEnd.addingTimeInterval(604_800),
            content: "继续推进", createdAt: older.createdAt.addingTimeInterval(604_800)
        )

        try store.save(newer)
        try store.save(older)
        XCTAssertEqual(store.summaries, [newer, older])
        try store.save(older)
        store.reload()

        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.summaries, [newer, older])
        XCTAssertEqual(SummaryStore(directoryURL: directory).summaries, [newer, older])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), [
            older.id.uuidString.lowercased() + ".json", newer.id.uuidString.lowercased() + ".json"
        ])
        let file = directory.appendingPathComponent(older.id.uuidString.lowercased() + ".json")
        let data = try Data(contentsOf: file)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["formatVersion"] as? Int, 1)
        XCTAssertEqual(payload["title"] as? String, "  一周回顾  ")
        XCTAssertEqual(payload["content"] as? String, "# 完成事项\n\n- 设计 ✅\n- 实现\n")
        XCTAssertTrue((payload["periodStart"] as? String)?.hasSuffix("Z") == true)
        XCTAssertTrue((payload["periodEnd"] as? String)?.hasSuffix("Z") == true)
        XCTAssertTrue((payload["createdAt"] as? String)?.hasSuffix("Z") == true)
    }

    @MainActor
    func testConflictingIDNeverOverwritesSavedFile() throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let summary = fixture()
        try store.save(summary)
        let file = directory.appendingPathComponent(summary.id.uuidString.lowercased() + ".json")
        let originalBytes = try Data(contentsOf: file)
        let conflict = SavedSummary(
            id: summary.id, title: summary.title, periodStart: summary.periodStart,
            periodEnd: summary.periodEnd, content: "不同正文", createdAt: summary.createdAt
        )

        XCTAssertThrowsError(try store.save(conflict)) { error in
            guard case let SummaryStoreError.conflictingID(id) = error else {
                return XCTFail("Expected conflicting summary ID, got \(error)")
            }
            XCTAssertEqual(id, summary.id)
        }

        XCTAssertEqual(store.summaries, [summary])
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        XCTAssertEqual(SummaryStore(directoryURL: directory).summaries, [summary])
    }

    @MainActor
    func testInvalidSummariesNeverCreateFilesOrObservedRecords() throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let valid = fixture()
        let invalid = [
            SavedSummary(title: " \n", periodStart: valid.periodStart, periodEnd: valid.periodEnd, content: "正文"),
            SavedSummary(title: "回顾", periodStart: valid.periodStart, periodEnd: valid.periodEnd, content: " \n"),
            SavedSummary(title: "回顾", periodStart: valid.periodStart, periodEnd: valid.periodStart, content: "正文"),
            SavedSummary(title: "回顾", periodStart: valid.periodEnd, periodEnd: valid.periodStart, content: "正文")
        ]

        for summary in invalid {
            XCTAssertThrowsError(try store.save(summary))
            XCTAssertTrue(store.summaries.isEmpty)
            XCTAssertNotNil(store.loadError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testReloadSurfacesBadFilesAndRetainsReadableSummariesWithoutChangingDisk() throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let valid = fixture()
        try store.save(valid)
        let malformedFile = directory.appendingPathComponent("broken.json")
        let malformedData = Data("{broken json".utf8)
        try malformedData.write(to: malformedFile)
        let ignoredFile = directory.appendingPathComponent("notes.txt")
        try Data("not a summary".utf8).write(to: ignoredFile)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var invalidRange = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(fixture())) as? [String: Any])
        invalidRange["periodEnd"] = invalidRange["periodStart"]
        let invalidRangeFile = directory.appendingPathComponent((invalidRange["id"] as! String).lowercased() + ".json")
        try JSONSerialization.data(withJSONObject: invalidRange).write(to: invalidRangeFile)
        var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(fixture())) as? [String: Any])
        unsupported["formatVersion"] = 99
        let unsupportedFile = directory.appendingPathComponent((unsupported["id"] as! String).lowercased() + ".json")
        try JSONSerialization.data(withJSONObject: unsupported).write(to: unsupportedFile)

        store.reload()

        XCTAssertEqual(store.summaries, [valid])
        let error = try XCTUnwrap(store.loadError)
        for file in [malformedFile, invalidRangeFile, unsupportedFile] {
            XCTAssertTrue(error.contains(file.lastPathComponent))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertFalse(error.contains("notes.txt"))
        XCTAssertEqual(try Data(contentsOf: malformedFile), malformedData)
        let reloaded = SummaryStore(directoryURL: directory)
        XCTAssertEqual(reloaded.summaries, [valid])
        XCTAssertNotNil(reloaded.loadError)
    }

    @MainActor
    func testDiskFailureLeavesExistingObservedRecordsAndFileIntact() throws {
        let directory = makeDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryStore(directoryURL: directory)
        let saved = fixture()
        try store.save(saved)
        let rejected = fixture()
        let blockedDestination = directory.appendingPathComponent(rejected.id.uuidString.lowercased() + ".json")
        try FileManager.default.createDirectory(at: blockedDestination, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.save(rejected))

        XCTAssertEqual(store.summaries, [saved])
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(SummaryStore(directoryURL: directory).summaries, [saved])
        let blocker = directory.appendingPathComponent("blocked-folder")
        try Data("keep".utf8).write(to: blocker)
        let blockedStore = SummaryStore(directoryURL: blocker)
        XCTAssertNotNil(blockedStore.loadError)
        XCTAssertThrowsError(try blockedStore.save(rejected))
        XCTAssertTrue(blockedStore.summaries.isEmpty)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "keep")
    }

    private func makeDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryStoreTests/\(UUID().uuidString)", isDirectory: true)
    }

    private func fixture() -> SavedSummary {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return SavedSummary(title: "每周回顾", periodStart: start, periodEnd: start.addingTimeInterval(604_800),
                            content: "完成设计与实现。", createdAt: start.addingTimeInterval(700_000))
    }
}
