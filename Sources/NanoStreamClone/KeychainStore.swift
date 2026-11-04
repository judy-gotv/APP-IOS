import Foundation
import Security

/// Minimal Keychain storage for Xtream passwords only.
///
/// Previously passwords were JSON-encoded in plain text into UserDefaults
/// together with the whole library (`nanostream.state.v4`) and also sent as
/// GET query parameters. Usernames stay in the playlist model (they are
/// needed for display and editing); passwords never enter UserDefaults,
/// SavedState, logs, or URLs built for display again.
///
/// API surface is intentionally tiny and uses only the standard SecItem
/// functions, so no new dependency is introduced.
enum KeychainStore {
    private static let service = "com.k20.nanostream.clone.xtream"
    private static let proxyService = "com.k20.nanostream.clone.proxy"

    /// Saves and read-back verifies. Returns false when the write (or the
    /// verification read) fails; callers must NOT clear the previous
    /// password on failure, or the credential is lost with no copy left.
    /// Accessibility is explicit: unlocked-device only, matching the
    /// previous system default for generic passwords (no iCloud sync).
    @discardableResult
    static func savePassword(_ password: String, for playlistID: UUID) -> Bool {
        guard !password.isEmpty else { deletePassword(for: playlistID); return true }
        // Compile-fix round: the parameter `password` shadows the
        // static helper password(for:), so the unqualified call
        // resolved to the String value. Qualify with the type name.
        return save(Data(password.utf8), service: service, account: playlistID.uuidString, verify: { KeychainStore.password(for: playlistID) == password })
    }

    static func password(for playlistID: UUID) -> String? {
        read(service: service, account: playlistID.uuidString)
    }

    static func deletePassword(for playlistID: UUID) {
        delete(service: service, account: playlistID.uuidString)
    }

    /// Round-5 fix (A01): the HTTP proxy password used to live in
    /// UserDefaults (@AppStorage "httpProxy") in plain text, and the
    /// round-4 authentication fix turned that dormant copy into a live
    /// one (sent on every request). Proxy passwords now live in the
    /// Keychain like Xtream passwords. The account is the canonical
    /// stripped proxy identity ("user@host:port" or "host:port"), so a
    /// password is only ever sent to the exact proxy it was entered
    /// for — changing the proxy address or username cannot silently
    /// reuse an old password against a different proxy.
    @discardableResult
    static func saveProxyPassword(_ password: String, forProxy proxy: String) -> Bool {
        guard !password.isEmpty else { deleteProxyPassword(forProxy: proxy); return true }
        return save(Data(password.utf8), service: proxyService, account: proxy, verify: { proxyPassword(forProxy: proxy) == password })
    }

    static func proxyPassword(forProxy proxy: String) -> String? {
        read(service: proxyService, account: proxy)
    }

    static func deleteProxyPassword(forProxy proxy: String) {
        delete(service: proxyService, account: proxy)
    }

    /// Round-8 fix (C02): rotation deletes only ever removed the single
    /// last-recorded identity, so proxy passwords orphaned during the
    /// round-5/6 rotation era (before any rotation delete existed) could
    /// never be cleaned up — and switching back to an old identity
    /// silently resurrected them. Enumerate every account stored under
    /// the proxy service so the settings page can offer a "clear all"
    /// sweep; a query that matches nothing returns an empty list, never
    /// an error, and the caller decides what to delete.
    static func allProxyAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: proxyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { !$0.isEmpty }
    }

    static func hasAnyProxyPassword() -> Bool {
        !allProxyAccounts().isEmpty
    }

    /// Deletes every stored proxy password, whatever identity it was
    /// saved under. Callers must also drop httpProxyLastIdentity and
    /// invalidate the cached session (the settings button does both);
    /// an inline password still in the field will migrate into the
    /// Keychain when the field is left (departure confirmation) — not
    /// on the next fetch while the field is still open (round-12
    /// A02) — which is the intended "stored passwords only" scope.
    static func deleteAllProxyPasswords() {
        for account in allProxyAccounts() {
            deleteProxyPassword(forProxy: account)
        }
    }

    // Dev round 10 (D-02/D-07): one shared secret store for the
    // user-configured translation and transcription endpoints. Base
    // URLs are not secrets and live in UserDefaults; keys NEVER do.
    // Accounts are fixed per purpose so a translation key is never
    // silently reused against a transcription endpoint or vice versa.
    private static let secretService = "com.k20.nanostream.clone.secrets"

    @discardableResult
    static func saveSecret(_ secret: String, forAccount account: String) -> Bool {
        guard !secret.isEmpty else { deleteSecret(forAccount: account); return true }
        return save(Data(secret.utf8), service: secretService, account: account, verify: { readSecret(forAccount: account) == secret })
    }

    static func readSecret(forAccount account: String) -> String? {
        read(service: secretService, account: account)
    }

    static func deleteSecret(forAccount account: String) {
        delete(service: secretService, account: account)
    }

    // Fixed accounts, one per purpose (see above).
    static let translateAPIKeyAccount = "translate.api.key"
    static let translateAIKeyAccount = "translate.ai.key"
    static let liveSubAPIKeyAccount = "livesub.api.key"
    static let liveSubAIKeyAccount = "livesub.ai.key"

    private static func save(_ data: Data, service: String, account: String, verify: () -> Bool) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Round-4 mitigation (C14, still suspect until a device
                // with a legacy item proves it): if the update missed
                // because a pre-round-3 item was written without an
                // explicit accessible attribute, the add then collides
                // with that same item. Retry the update with a query
                // that does not constrain accessible, so the legacy item
                // matches regardless of how it was written. The read-back
                // verification below still gates success either way.
                var legacyQuery = query
                legacyQuery.removeValue(forKey: kSecAttrAccessible as String)
                guard SecItemUpdate(legacyQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess else { return false }
            } else if addStatus != errSecSuccess {
                return false
            }
        } else if status != errSecSuccess {
            return false
        }
        // Read-back verification: a reported success that cannot be read
        // back is treated as a failure, not as a stored password.
        return verify()
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }
        return password
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
