import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import barNoticer

final class AIImageInputTests: XCTestCase {
    func testImageContentSurvivesConversationAndRequestEncoding() throws {
        let json = #"{"role":"user","content":[{"type":"text","text":"整理截图里的待办"},{"type":"image_url","image_url":{"url":"data:image/png;base64,aGVsbG8="}}]}"#
        let message = try JSONDecoder().decode(AIChatMessage.self, from: Data(json.utf8))
        let request = try AIChatRequestBuilder.make(
            messages: [message],
            settings: AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "vision"),
            apiKey: "test", tools: []
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["text"] as? String, "整理截图里的待办")
        XCTAssertEqual((parts[1]["image_url"] as? [String: String])?["url"], "data:image/png;base64,aGVsbG8=")
    }

    func testTextOnlyMessageKeepsStringContent() throws {
        let data = try JSONEncoder().encode(AIChatMessage(role: "user", content: "今天的任务"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["content"] as? String, "今天的任务")
    }

    func testLargeImageIsDownsampledAndInvalidDataRejected() throws {
        let attachment = try AIImageAttachment(data: imageData(width: 3_000, height: 1_500), name: "large.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: attachment.data))
        XCTAssertEqual(bitmap.pixelsWide, 2_048)
        XCTAssertEqual(bitmap.pixelsHigh, 1_024)
        XCTAssertTrue(attachment.dataURL.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertThrowsError(try AIImageAttachment(data: Data("not an image".utf8), name: "bad.png"))
        XCTAssertThrowsError(try AIImageAttachment(data: Data(count: 21 * 1_024 * 1_024), name: "large.png"))
    }

    @MainActor
    func testImageOnlySubmissionRetainsImageForFollowUpAndRejectsDuplicateSubmit() async throws {
        let (model, defaults, container) = try makeModel()
        _ = container
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        model.addImages([try AIImageAttachment(data: imageData(), name: "screenshot.png")])
        XCTAssertTrue(model.canSubmit)
        model.submit()
        XCTAssertEqual(model.state, .loading)
        XCTAssertTrue(model.images.isEmpty)
        model.submit()
        XCTAssertEqual(model.conversation.messages.filter { $0.role == "user" }.count, 1)
        for _ in 0..<100 where model.state == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.conversation.messages.first?.imageURLs.count, 1)
        let request = AIAssistantRequestBuilder.makeMessages(systemPrompt: "system", inlineContext: .init(content: "context"), conversation: model.conversation)
        XCTAssertEqual(request.first { $0.role == "user" }?.imageURLs.count, 1)
        model.startNewConversation()
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertTrue(model.conversation.messages.isEmpty)
    }

    @MainActor
    func testFailedSubmissionRestoresTextAndImagesWithoutDuplicatingHistory() async throws {
        let (model, defaults, container) = try makeModel()
        _ = container
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        AIAPIKeyStore(defaults: defaults).saveAPIKey("")
        model.prompt = "截图里的任务"
        model.addImages([try AIImageAttachment(data: imageData(), name: "screenshot.png")])
        model.submit()
        for _ in 0..<100 where model.state == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.state.isFailure)
        XCTAssertEqual(model.prompt, "截图里的任务")
        XCTAssertEqual(model.images.count, 1)
        XCTAssertTrue(model.conversation.messages.isEmpty)
    }

    @MainActor
    func testImageLimitAndRemovalControlImageOnlySubmission() throws {
        let (model, defaults, container) = try makeModel()
        _ = container
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let images = try (0..<4).map { try AIImageAttachment(data: imageData(), name: "\($0).png") }
        model.addImages(images)
        model.addImages([try AIImageAttachment(data: imageData(), name: "extra.png")])
        XCTAssertEqual(model.images.count, 4)
        XCTAssertNotNil(model.imageInputError)
        for image in images { model.removeImage(id: image.id) }
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.imageInputError)
    }

    @MainActor
    func testPastingScreenshotAddsAttachmentWithoutInsertingText() throws {
        let (model, defaults, container) = try makeModel()
        _ = container
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try imageData(), forType: .png)
        let editor = ImagePromptFieldEditor()
        editor.string = "整理这些任务"
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.onPasteImages = model.pasteImages
        XCTAssertTrue(editor.readablePasteboardTypes.contains(.png))
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .png))
        XCTAssertEqual(model.images.count, 1)
        XCTAssertEqual(editor.string, "整理这些任务")

        pasteboard.clearContents()
        pasteboard.setString("普通文字", forType: .string)
        XCTAssertFalse(model.pasteImages(from: pasteboard))
        XCTAssertEqual(model.images.count, 1)
    }

    @MainActor
    func testSessionResetCancelsSubmissionWithoutRestoringOldDraft() async throws {
        let (model, defaults, container) = try makeModel()
        _ = container
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        model.prompt = "旧输入"
        model.addImages([try AIImageAttachment(data: imageData(), name: "old.png")])
        model.submit()
        XCTAssertEqual(model.state, .loading)
        model.startNewConversation()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.prompt, "")
        XCTAssertEqual(model.response, "")
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertTrue(model.conversation.messages.isEmpty)
    }

    @MainActor
    func testPanelInstallsImagePasteEditorAndKeepsMarkedText() async throws {
        let (model, defaults, container) = try makeModel()
        _ = container
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        model.addImages([try AIImageAttachment(data: imageData(), name: "截图.png")])
        let host = NSHostingView(rootView: AIAssistantPanelView(model: model, close: {}))
        let panel = AIAssistantPanelChrome.makePanel(contentView: host)
        panel.setContentSize(AIAssistantPanelChrome.size(outputKind: .none, hasImages: true, hasImageError: false))
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        func findField(_ view: NSView) -> TransparentPromptField? {
            if let field = view as? TransparentPromptField { return field }
            return view.subviews.lazy.compactMap { findField($0) }.first
        }
        let field = try XCTUnwrap(findField(host))
        panel.makeFirstResponder(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? ImagePromptFieldEditor)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        TransparentPromptEditor.synchronize(field, with: model.prompt)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "ni")
        XCTAssertFalse(model.canSubmit)
        editor.insertText("请根据图片整理待办", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(model.canSubmit)
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "AI image input panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private let defaultsSuite = "AIImageInputTests-\(UUID().uuidString)"

    @MainActor
    func testFailureAfterCreatingTodoDoesNotRestoreDraftForDuplicateSubmission() async throws {
        FailureAfterToolURLProtocol.requestCount = 0
        let (model, defaults, container) = try makeModel(protocolClass: FailureAfterToolURLProtocol.self)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "vision", requiresActionConfirmation: false).save(to: defaults)
        model.prompt = "按图片创建事项"
        model.addImages([try AIImageAttachment(data: imageData(), name: "screenshot.png")])
        model.submit()
        for _ in 0..<100 where model.state == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.state.isFailure)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 1)
        XCTAssertTrue(model.prompt.isEmpty)
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.response.isEmpty)
    }

    @MainActor
    func testPendingConfirmationSurvivesReplyFailureWithoutRestoringDraft() async throws {
        FailureAfterToolURLProtocol.requestCount = 0
        let (model, defaults, container) = try makeModel(protocolClass: FailureAfterToolURLProtocol.self)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        model.prompt = "按图片创建事项"
        model.addImages([try AIImageAttachment(data: imageData(), name: "screenshot.png")])
        model.submit()
        for _ in 0..<100 where model.state == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.state.isFailure)
        XCTAssertEqual(model.proposals.count, 1)
        XCTAssertTrue(model.prompt.isEmpty)
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 0)
        model.applyAllProposals()
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 1)
        XCTAssertTrue(model.proposals.isEmpty)
    }

    @MainActor
    func testConfirmationCannotExecuteWhileRequestIsLoading() async throws {
        let (model, defaults, container) = try makeModel()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        model.prompt = "任务"
        model.submit()
        let proposal = AIActionProposal.completeTodo(id: UUID())
        model.stageOrApply([proposal], settings: AISettings(defaults: defaults))
        model.apply(proposal)
        model.applyAllProposals()
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.proposals.count, 1)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TodoItem>()).count, 0)
        model.startNewConversation()
    }

    @MainActor
    private func makeModel(protocolClass: AnyClass = ImageInputURLProtocol.self) throws -> (AIAssistantModel, UserDefaults, ModelContainer) {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "vision").save(to: defaults)
        let keyStore = AIAPIKeyStore(defaults: defaults)
        keyStore.saveAPIKey("test-key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let container = try ModelContainer(for: TodoItem.self, TodoGroup.self, DailySummary.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = AIAssistantModel(modelContext: container.mainContext,
                                     client: AIClient(session: URLSession(configuration: configuration)),
                                     apiKeyStore: keyStore, defaults: defaults)
        return (model, defaults, container)
    }

    private func imageData(width: Int = 16, height: Int = 16) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData!, 127, bitmap.bytesPerRow * height)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class ImageInputURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"已读取图片"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FailureAfterToolURLProtocol: URLProtocol {
    static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        if Self.requestCount > 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"create_todo","arguments":"{\"title\":\"截图中的任务\",\"priority\":\"high\"}"}}]}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
