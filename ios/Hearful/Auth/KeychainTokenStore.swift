import Foundation
import Security

/// The session token, in the Keychain rather than UserDefaults: it is a
/// credential, and it must survive reinstalls no better than one.
///
/// Accessibility is AfterFirstUnlock, not WhenUnlocked: App Intents run in
/// this process from the lock screen ("Hey Siri, play the latest…"), and a
/// WhenUnlocked item would make Siri fail whenever the phone is in a pocket.
enum KeychainTokenStore {
    private static let service = "com.henrydashwood.hearful"
    private static let account = "session-token"

    static var token: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func clear() {
        token = nil
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
