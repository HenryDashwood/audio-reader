import Foundation
import Security

/// The extension shares a scoped credential through Keychain, never the queue files.
/// Existing app-group entitlements also grant this Keychain access group.
nonisolated enum CaptureSessionStore {
    struct Session: Codable, Equatable, Sendable {
        let account: CaptureInbox.Account
        let token: String
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.henrydashwood.hearful.capture-session",
         kSecAttrAccount as String: "session",
         kSecAttrAccessGroup as String: CaptureInbox.groupID]
    }

    static func read() -> Session? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func write(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CaptureInbox.InboxError.unavailable }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
