import XCTest
@testable import barNoticer

final class AISettingsTests: XCTestCase {
    func testSidebarHasIndependentAISettingsSelection() {
        XCTAssertNotEqual(SidebarSelection.aiSettings, SidebarSelection.islandSettings)
    }

    func testAISettingsDraftPersistsChangesImmediately() {
        let suiteName = "AISettingsDraftTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let keyStore = AIAPIKeyStore(defaults: defaults)
        var draft = AISettingsDraft(defaults: defaults, keyStore: keyStore)

        draft.baseURLText = "https://example.com/v1"
        draft.model = "custom-model"
        draft.apiKey = "sk-auto"
        draft.shortcut = AIKeyboardShortcut(keyCode: 0, modifiers: [.command, .option])
        draft.requiresActionConfirmation = false

        let settings = AISettings(defaults: defaults)
        XCTAssertEqual(settings.baseURL.absoluteString, "https://example.com/v1")
        XCTAssertEqual(settings.model, "custom-model")
        XCTAssertEqual(settings.shortcut, AIKeyboardShortcut(keyCode: 0, modifiers: [.command, .option]))
        XCTAssertFalse(settings.requiresActionConfirmation)
        XCTAssertEqual(keyStore.readAPIKey(), "sk-auto")
    }

    func testDefaultSettingsUseOpenAICompatibleChatCompletions() {
        let settings = AISettings()

        XCTAssertEqual(settings.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(settings.model, "gpt-4o-mini")
        XCTAssertTrue(settings.requiresActionConfirmation)
        XCTAssertEqual(settings.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testActionConfirmationPreferenceRoundTrips() {
        let suiteName = "AISettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var settings = AISettings(
            baseURL: URL(string: "https://example.com/v1")!,
            model: "model",
            shortcut: .default,
            requiresActionConfirmation: false
        )
        settings.save(to: defaults)

        XCTAssertFalse(AISettings(defaults: defaults).requiresActionConfirmation)

        settings.requiresActionConfirmation = true
        settings.save(to: defaults)

        XCTAssertTrue(AISettings(defaults: defaults).requiresActionConfirmation)
    }

    func testValidationRequiresNonEmptyModelAndHTTPBaseURL() {
        XCTAssertTrue(AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model").isValid)
        XCTAssertFalse(AISettings(baseURL: URL(string: "file:///tmp/api")!, model: "model").isValid)
        XCTAssertFalse(AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "   ").isValid)
    }

    func testShortcutRoundTripsReadableDescription() {
        let shortcut = AIKeyboardShortcut(keyCode: 49, modifiers: [.command, .option])

        XCTAssertEqual(shortcut.displayValue, "⌘⌥Space")
    }

    func testConnectivityCheckRequestUsesMinimalPromptWithoutTools() throws {
        let request = try AIConnectivityCheckRequest.make(
            settings: AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model"),
            apiKey: "key"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")

        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertEqual(object?["model"] as? String, "model")
        XCTAssertNil(object?["tools"])
        XCTAssertEqual(object?["max_tokens"] as? Int, 12)
    }

    func testAPIKeyStorePersistsInApplicationDefaults() {
        let suiteName = "AIAPIKeyStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AIAPIKeyStore(defaults: defaults)

        XCTAssertEqual(store.readAPIKey(), "")

        store.saveAPIKey("sk-local")

        XCTAssertEqual(store.readAPIKey(), "sk-local")
        XCTAssertEqual(defaults.string(forKey: AIAPIKeyStore.apiKeyKey), "sk-local")
    }

    func testChatRequestPreservesAssistantReasoningContent() throws {
        let request = try AIChatRequestBuilder.make(
            messages: [
                AIChatMessage(
                    role: "assistant",
                    content: "",
                    reasoningContent: "internal reasoning token",
                    toolCalls: [
                        AIToolCall(
                            id: "call_1",
                            type: "function",
                            function: .init(name: "list_active_todos", arguments: "{}")
                        )
                    ]
                )
            ],
            settings: AISettings(baseURL: URL(string: "https://example.com/v1")!, model: "model"),
            apiKey: "key",
            tools: []
        )

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.first?["reasoning_content"] as? String, "internal reasoning token")
    }
}
