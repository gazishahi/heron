import Foundation
import Security

/// Minimal generic-password Keychain wrapper — the first Keychain use in the app, kept
/// deliberately small. One fixed service; `account` is the provider id ("anthropic", …).
/// Single-machine storage only (no iCloud sync, no access groups), matching the v1
/// no-multi-user-collaboration non-goal.
public enum KeychainStore {
    private static let service = "com.shahi.side.provider-credential"

    /// Under tests, an in-memory store: tests never read or write the person's real Keychain.
    /// They did, and a test build (signed ad hoc, a new signature every build) asking for a key
    /// the real Side had saved raised macOS's Keychain prompt, and the test run hung waiting for
    /// someone to answer it (2026-09-30; the audit's H15, tests touching the owner's own state).
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: [String: String] = [:]

    @discardableResult
    public static func set(secret: String, account: String) -> Bool {
        if isTesting { memoryLock.withLock { memory[account] = secret }; return true }
        // Generic-password items have no upsert — delete-then-add is the standard idiom.
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func get(account: String) -> String? {
        if isTesting { return memoryLock.withLock { memory[account] } }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        if isTesting { memoryLock.withLock { memory[account] = nil }; return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func hasSecret(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }
}
