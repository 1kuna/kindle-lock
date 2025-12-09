import Foundation
import Security

/// Secure storage for sensitive authentication data using iOS Keychain
@MainActor
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let service = "com.kindlelock.app"

    private enum Keys {
        static let cookies = "amazon_cookies"
        static let deviceToken = "device_token"
        static let adpSessionToken = "adp_session_token"
    }

    private init() {}

    // MARK: - Cookies

    /// Store Amazon cookies using NSKeyedArchiver for reliable serialization
    func saveCookies(_ cookies: [HTTPCookie]) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: cookies,
            requiringSecureCoding: false
        )
        try save(data: data, forKey: Keys.cookies)
    }

    /// Load stored Amazon cookies
    func loadCookies() -> [HTTPCookie] {
        guard let data = load(forKey: Keys.cookies) else { return [] }

        do {
            if let cookies = try NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSArray.self, HTTPCookie.self],
                from: data
            ) as? [HTTPCookie] {
                return cookies
            }
        } catch {
            print("Failed to unarchive cookies: \(error)")
        }
        return []
    }

    /// Check if we have stored auth cookies
    var hasAuthCookies: Bool {
        let cookies = loadCookies()
        let requiredNames = ["at-main", "session-id"]
        return requiredNames.allSatisfy { name in
            cookies.contains { $0.name == name }
        }
    }

    // MARK: - Device Token

    func saveDeviceToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        try save(data: data, forKey: Keys.deviceToken)
    }

    func loadDeviceToken() -> String? {
        guard let data = load(forKey: Keys.deviceToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - ADP Session Token

    func saveADPSessionToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        try save(data: data, forKey: Keys.adpSessionToken)
    }

    func loadADPSessionToken() -> String? {
        guard let data = load(forKey: Keys.adpSessionToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Clear All

    func clearAll() {
        delete(forKey: Keys.cookies)
        delete(forKey: Keys.deviceToken)
        delete(forKey: Keys.adpSessionToken)
    }

    // MARK: - Private Keychain Operations

    private func save(data: Data, forKey key: String) throws {
        // Delete existing item first
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case encodingError
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingError:
            return "Failed to encode data for keychain"
        case .saveFailed(let status):
            return "Keychain save failed with status: \(status)"
        }
    }
}
