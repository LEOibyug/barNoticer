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

    func testGoogleAIStudioPresetAndResponseFormatEnvironmentKeyBehavior() throws {
        let suiteName = "GeminiSettingsEnvTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let credentialDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiSettingsEnvTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: credentialDir)
        }
        let store = AIAPIKeyStore(defaults: defaults, directoryURL: credentialDir)

        // 有环境变量时新增 Google AI Studio 默认使用环境变量，且不将环境变量写入本机凭据存储
        var envDraft = AISettingsDraft(
            defaults: defaults,
            keyStore: store,
            environment: [AIEnvironmentAPIKey.geminiVariableName: "  AIza-env-secret  "]
        )
        envDraft.addGoogleAIStudioProvider()
        XCTAssertEqual(envDraft.provider.name, "Google AI Studio")
        XCTAssertEqual(envDraft.provider.responseFormat, .gemini)
        XCTAssertEqual(envDraft.provider.baseURL, AIResponseFormat.gemini.defaultBaseURL)
        XCTAssertEqual(envDraft.provider.model, AIResponseFormat.gemini.defaultModel)
        XCTAssertEqual(envDraft.provider.apiKeySource, .environment)
        XCTAssertEqual(envDraft.resolvedAPIKey, "AIza-env-secret")
        XCTAssertTrue(envDraft.canDiscover)
        XCTAssertTrue(envDraft.canTestConnection)
        XCTAssertEqual(store.readAPIKey(for: envDraft.provider.id), "")
        XCTAssertEqual(store.readAPIKey(), "")
        let rawDefaults = String(decoding: try XCTUnwrap(defaults.data(forKey: AIProviderCollection.storageKey)), as: UTF8.self)
        XCTAssertFalse(rawDefaults.contains("AIza-env-secret"))

        // 切换为手动输入并填写 Key 后，立即生效且可正常持久化手动 Key
        envDraft.provider.apiKeySource = .manual
        XCTAssertEqual(envDraft.resolvedAPIKey, "")
        XCTAssertFalse(envDraft.canTestConnection)
        envDraft.apiKey = "AIza-manual-secret"
        XCTAssertEqual(envDraft.resolvedAPIKey, "AIza-manual-secret")
        XCTAssertTrue(envDraft.canTestConnection)
        XCTAssertEqual(store.readAPIKey(for: envDraft.provider.id), "AIza-manual-secret")

        // 切离 Gemini 时重置 apiKeySource 为 manual，确保非 Gemini 协议绝不使用 GEMINI_API_KEY
        envDraft.provider.apiKeySource = .environment
        envDraft.setResponseFormat(.chatCompletions)
        XCTAssertEqual(envDraft.provider.apiKeySource, .manual)
        XCTAssertEqual(envDraft.provider.effectiveAPIKeySource, .manual)

        // 空白非 Gemini 配置切到 Gemini 且无手动 Key 时，自动填入默认 Base URL 并启用环境变量
        envDraft.addProvider()
        envDraft.setResponseFormat(.gemini)
        XCTAssertEqual(envDraft.baseURLText, AIResponseFormat.gemini.defaultBaseURL)
        XCTAssertEqual(envDraft.provider.apiKeySource, .environment)

        // 无环境变量时新增 Google AI Studio 保持手动输入模式
        var noEnvDraft = AISettingsDraft(defaults: defaults, keyStore: store, environment: [:])
        noEnvDraft.addGoogleAIStudioProvider()
        XCTAssertEqual(noEnvDraft.provider.apiKeySource, .manual)
        XCTAssertFalse(noEnvDraft.hasEnvironmentGeminiAPIKey)
        XCTAssertFalse(noEnvDraft.canDiscover)
        XCTAssertFalse(noEnvDraft.canTestConnection)
        noEnvDraft.apiKey = "AIza-typed"
        XCTAssertTrue(noEnvDraft.canDiscover)
        XCTAssertTrue(noEnvDraft.canTestConnection)
    }

    func testLegacyProviderCollectionDecodesWithoutAPIKeySource() throws {
        let suiteName = "LegacyProviderDecodeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let legacy: [String: Any] = [
            "activeID": id.uuidString,
            "mode": "single",
            "providers": [[
                "id": id.uuidString,
                "name": "Legacy",
                "baseURL": "https://example.com/v1",
                "responseFormat": "chatCompletions",
                "apiKey": "",
                "model": "gpt-4o-mini"
            ]]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AIProviderCollection.storageKey)
        let loaded = AIProviderCollection.load(from: defaults)
        XCTAssertEqual(loaded.providers.first?.apiKeySource, .manual)
    }

    func testMoveAndRemoveProviderByIDKeepEditingAndSelectNeighborFallback() {
        let suiteName = "ProviderListOpsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIAPIKeyStore(defaults: defaults)

        var draft = AISettingsDraft(defaults: defaults, keyStore: store)
        let firstID = draft.provider.id
        draft.provider.name = "A"

        draft.addProvider()
        let secondID = draft.provider.id
        draft.provider.name = "B"

        draft.addProvider()
        let thirdID = draft.provider.id
        draft.provider.name = "C"

        // 编辑 C 时移动 A 与 B，不应改变当前 editingID
        draft.moveProvider(id: firstID, by: 1)
        XCTAssertEqual(draft.collection.providers.map(\.id), [secondID, firstID, thirdID])
        XCTAssertEqual(draft.editingID, thirdID)

        // 删除非当前激活也非当前编辑的 B，应保持 activeID 与 editingID 不变
        draft.setActive(firstID)
        draft.removeProvider(id: secondID)
        XCTAssertEqual(draft.collection.providers.map(\.id), [firstID, thirdID])
        XCTAssertEqual(draft.collection.activeID, firstID)
        XCTAssertEqual(draft.editingID, thirdID)

        // 删除当前编辑与激活的配置时，切换到相邻保留项
        draft.setActive(thirdID)
        draft.removeProvider(id: thirdID)
        XCTAssertEqual(draft.collection.providers.map(\.id), [firstID])
        XCTAssertEqual(draft.collection.activeID, firstID)
        XCTAssertEqual(draft.editingID, firstID)
    }
}
