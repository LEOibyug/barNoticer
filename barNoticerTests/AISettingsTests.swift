import XCTest
@testable import barNoticer

final class AISettingsTests: XCTestCase {
    func testSidebarHasIndependentAISettingsSelection() {
        XCTAssertNotEqual(SidebarSelection.aiSettings, SidebarSelection.islandSettings)
    }

    func testSidebarHasIndependentAppSettingsSelection() {
        XCTAssertNotEqual(SidebarSelection.appSettings, SidebarSelection.islandSettings)
        XCTAssertNotEqual(SidebarSelection.appSettings, SidebarSelection.aiSettings)
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
        draft.apiKey = "test-api-key-auto"
        draft.shortcut = AIKeyboardShortcut(keyCode: 0, modifiers: [.command, .option])
        draft.requiresActionConfirmation = false

        let settings = AISettings(defaults: defaults)
        XCTAssertEqual(settings.baseURL.absoluteString, "https://example.com/v1")
        XCTAssertEqual(settings.model, "custom-model")
        XCTAssertEqual(settings.shortcut, AIKeyboardShortcut(keyCode: 0, modifiers: [.command, .option]))
        XCTAssertFalse(settings.requiresActionConfirmation)
        XCTAssertEqual(keyStore.readAPIKey(), "test-api-key-auto")
    }

    func testExistingProviderCollectionKeepsProfilesAndPersistsIndependentReasoningEfforts() throws {
        let suiteName = "AIReasoningSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstID = UUID(), secondID = UUID()
        let legacy: [String: Any] = ["activeID": firstID.uuidString, "mode": "ordered", "providers": [
            ["id": firstID.uuidString, "name": "Existing", "baseURL": "https://first.example/v1",
             "responseFormat": "responses", "apiKey": "first-secret", "model": "first-model"],
            ["id": secondID.uuidString, "name": "Other", "baseURL": "https://second.example/v1",
             "responseFormat": "chatCompletions", "apiKey": "second-secret", "model": "second-model"]
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AIProviderCollection.storageKey)
        let migrated = AIProviderCollection.load(from: defaults)
        XCTAssertEqual(migrated.providers.map(\.id), [firstID, secondID])
        XCTAssertEqual(migrated.providers.map(\.apiKey), ["first-secret", "second-secret"])
        let scrubbedRaw = String(decoding: try XCTUnwrap(defaults.data(forKey: AIProviderCollection.storageKey)), as: UTF8.self)
        XCTAssertFalse(scrubbedRaw.contains("first-secret"))
        XCTAssertFalse(scrubbedRaw.contains("second-secret"))
        XCTAssertTrue(migrated.providers.allSatisfy { $0.reasoningEffort == nil })
        XCTAssertEqual(migrated.mode, .ordered)

        var draft = AISettingsDraft(defaults: defaults, keyStore: AIAPIKeyStore(defaults: defaults))
        draft.provider.reasoningEffort = .high
        draft.editingID = secondID
        draft.provider.reasoningEffort = AIReasoningEffort.none
        var restored = AISettings(defaults: defaults)
        XCTAssertEqual(restored.providerRoutes?.map(\.reasoningEffort), [.high, AIReasoningEffort.none])
        XCTAssertEqual(restored.reasoningEffort, .high)
        XCTAssertEqual(AIProviderCollection.load(from: defaults).activeID, firstID)

        draft.provider.reasoningEffort = nil
        restored = AISettings(defaults: defaults)
        XCTAssertNil(restored.providerRoutes?.last?.reasoningEffort)
        XCTAssertEqual(restored.providerRoutes?.map(\.model), ["first-model", "second-model"])
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

    func testAPIKeyStoreKeepsSecretsOutOfUserDefaultsAndMigratesLegacyKeys() throws {
        let suiteName = "AIAPIKeyStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let credentialDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIAPIKeyStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: credentialDir)
        }
        let store = AIAPIKeyStore(defaults: defaults, directoryURL: credentialDir)

        XCTAssertEqual(store.readAPIKey(), "")

        store.saveAPIKey("test-api-key-local")

        XCTAssertEqual(store.readAPIKey(), "test-api-key-local")
        XCTAssertNil(defaults.string(forKey: AIAPIKeyStore.apiKeyKey))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.credentialFileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
        let values = try store.credentialFileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        // 旧版 UserDefaults 明文 Key 在读取时自动迁移并清除明文。
        defaults.set("legacy-plaintext-key", forKey: AIAPIKeyStore.apiKeyKey)
        XCTAssertEqual(store.readAPIKey(), "legacy-plaintext-key")
        XCTAssertNil(defaults.string(forKey: AIAPIKeyStore.apiKeyKey))

        // 供应商配置中的 apiKey 不以明文留在 UserDefaults JSON 中。
        let providerID = UUID()
        let collection = AIProviderCollection(
            providers: [AIProviderConfiguration(id: providerID, name: "P1", baseURL: "https://example.com/v1", apiKey: "provider-secret", model: "m")],
            activeID: providerID
        )
        collection.save(to: defaults, keyStore: store)
        let rawData = try XCTUnwrap(defaults.data(forKey: AIProviderCollection.storageKey))
        let rawString = String(decoding: rawData, as: UTF8.self)
        XCTAssertFalse(rawString.contains("provider-secret"))
        XCTAssertEqual(AIProviderCollection.load(from: defaults, keyStore: store).providers.first?.apiKey, "provider-secret")

        // 移除供应商后同步清理对应凭据。
        let remainingID = UUID()
        let updatedCollection = AIProviderCollection(
            providers: [AIProviderConfiguration(id: remainingID, name: "P2", baseURL: "https://example.com/v1", apiKey: "next-secret", model: "m")],
            activeID: remainingID
        )
        updatedCollection.save(to: defaults, keyStore: store)
        XCTAssertEqual(store.readAPIKey(for: providerID), "")
        XCTAssertEqual(store.readAPIKey(for: remainingID), "next-secret")
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
