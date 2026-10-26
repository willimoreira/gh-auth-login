import Foundation
import Security

/// Armazenamento seguro (Keychain) para tokens e senhas de app das contas.
enum Keychain {
    private static let service = "com.willimoreira.jarvis.accounts"

    static func set(_ data: Data, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setCodable<T: Encodable>(_ value: T, for key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, for: key) }
    }

    static func codable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
