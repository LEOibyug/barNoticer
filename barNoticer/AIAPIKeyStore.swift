import Foundation
import Security

nonisolated struct AIAPIKeyStore {
    static let shared = AIAPIKeyStore()
    static let apiKeyKey = "AISettingsAPIKey"

    private static let scopeIDKey = "AIAPIKeyStoreScopeID"
    private static let keychainService = "com.LEOibyug.barNoticer.ai-api-keys"
    private static let activeAccount = "active"
    private static let ioLock = NSLock()

    let defaults: UserDefaults
    private let explicitDirectoryURL: URL?
    private let allowDataProtectionKeychain: Bool

    init(defaults: UserDefaults = .standard, directoryURL: URL? = nil) {
        self.defaults = defaults
        self.explicitDirectoryURL = directoryURL
        self.allowDataProtectionKeychain = (defaults === UserDefaults.standard && directoryURL == nil)
    }

    var credentialFileURL: URL {
        directoryURL(createScopeIfNeeded: true).appendingPathComponent("api-keys.json")
    }

    func readAPIKey() -> String {
        migrateLegacyDefaultKeyIfPresent()
        return readSecret(account: Self.activeAccount) ?? ""
    }

    func saveAPIKey(_ value: String) {
        defaults.removeObject(forKey: Self.apiKeyKey)
        if value.isEmpty {
            deleteSecret(account: Self.activeAccount)
        } else {
            saveSecret(value, account: Self.activeAccount)
        }
    }

    func readAPIKey(for providerID: UUID) -> String {
        readSecret(account: Self.account(for: providerID)) ?? ""
    }

    func saveAPIKey(_ value: String, for providerID: UUID) {
        let account = Self.account(for: providerID)
        if value.isEmpty {
            deleteSecret(account: account)
        } else {
            saveSecret(value, account: account)
        }
    }

    func pruneProviderKeys(keeping activeIDs: Set<UUID>) {
        let keptAccounts = Set(activeIDs.map(Self.account(for:))).union([Self.activeAccount])
        Self.ioLock.withLock {
            let fileURL = existingCredentialFileURL()
            if let fileURL, var secrets = readFileSecrets(at: fileURL) {
                let beforeCount = secrets.count
                secrets = secrets.filter { keptAccounts.contains($0.key) }
                if secrets.count != beforeCount {
                    writeFileSecrets(secrets, to: fileURL)
                }
            }
            if allowDataProtectionKeychain {
                pruneKeychainAccounts(keeping: keptAccounts)
            }
        }
    }

    private static func account(for providerID: UUID) -> String {
        providerID.uuidString.lowercased()
    }

    private func migrateLegacyDefaultKeyIfPresent() {
        guard let legacy = defaults.string(forKey: Self.apiKeyKey) else { return }
        defaults.removeObject(forKey: Self.apiKeyKey)
        if !legacy.isEmpty {
            saveSecret(legacy, account: Self.activeAccount)
        }
    }

    private func readSecret(account: String) -> String? {
        Self.ioLock.withLock {
            if allowDataProtectionKeychain {
                switch readKeychainSecret(account: account) {
                case let .found(value):
                    return value
                case .notFound:
                    if let fileURL = existingCredentialFileURL(),
                       var secrets = readFileSecrets(at: fileURL),
                       let migrated = secrets.removeValue(forKey: account) {
                        if saveKeychainSecret(migrated, account: account) {
                            writeFileSecrets(secrets, to: fileURL)
                        }
                        return migrated
                    }
                    return nil
                case .unavailable:
                    break
                }
            }
            guard let fileURL = existingCredentialFileURL(),
                  let secrets = readFileSecrets(at: fileURL) else { return nil }
            return secrets[account]
        }
    }

    private func saveSecret(_ value: String, account: String) {
        Self.ioLock.withLock {
            if allowDataProtectionKeychain, saveKeychainSecret(value, account: account) {
                if let fileURL = existingCredentialFileURL(),
                   var secrets = readFileSecrets(at: fileURL),
                   secrets.removeValue(forKey: account) != nil {
                    writeFileSecrets(secrets, to: fileURL)
                }
                return
            }
            let fileURL = directoryURL(createScopeIfNeeded: true).appendingPathComponent("api-keys.json")
            var secrets = readFileSecrets(at: fileURL) ?? [:]
            secrets[account] = value
            writeFileSecrets(secrets, to: fileURL)
        }
    }

    private func deleteSecret(account: String) {
        Self.ioLock.withLock {
            if allowDataProtectionKeychain {
                deleteKeychainSecret(account: account)
            }
            guard let fileURL = existingCredentialFileURL(),
                  var secrets = readFileSecrets(at: fileURL),
                  secrets.removeValue(forKey: account) != nil else { return }
            writeFileSecrets(secrets, to: fileURL)
        }
    }

    private func existingCredentialFileURL() -> URL? {
        guard let dir = directoryURLIfPresent() else { return nil }
        let fileURL = dir.appendingPathComponent("api-keys.json")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private func directoryURLIfPresent() -> URL? {
        if let explicitDirectoryURL {
            return explicitDirectoryURL
        }
        if defaults === UserDefaults.standard {
            return URL.applicationSupportDirectory
                .appendingPathComponent("barNoticer/Credentials", isDirectory: true)
        }
        guard let scopeID = defaults.string(forKey: Self.scopeIDKey), !scopeID.isEmpty else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("barNoticer-Credentials/\(scopeID)", isDirectory: true)
    }

    private func directoryURL(createScopeIfNeeded: Bool) -> URL {
        if let existing = directoryURLIfPresent() {
            return existing
        }
        let scopeID: String
        if let stored = defaults.string(forKey: Self.scopeIDKey), !stored.isEmpty {
            scopeID = stored
        } else if createScopeIfNeeded {
            scopeID = UUID().uuidString
            defaults.set(scopeID, forKey: Self.scopeIDKey)
        } else {
            scopeID = UUID().uuidString
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("barNoticer-Credentials/\(scopeID)", isDirectory: true)
    }

    private func readFileSecrets(at fileURL: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func writeFileSecrets(_ secrets: [String: String], to fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        if secrets.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONEncoder().encode(secrets)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // 凭证写入失败时不降级回 UserDefaults 明文，避免静默泄露凭据。
        }
    }

    private enum KeychainReadResult {
        case found(String)
        case notFound
        case unavailable
    }

    private func readKeychainSecret(account: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .notFound
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable
        }
    }

    @discardableResult
    private func saveKeychainSecret(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private func deleteKeychainSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func pruneKeychainAccounts(keeping keptAccounts: Set<String>) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String, !keptAccounts.contains(account) {
                deleteKeychainSecret(account: account)
            }
        }
    }
}
