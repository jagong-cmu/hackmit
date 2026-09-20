import Foundation
import Security

/// Keychain-backed `SecureLocalStore` for the v2 features' caregiver settings
/// and wearer notes (diet profile, sound-alert settings, memory notes) —
/// encrypted at rest and never synced anywhere.
///
/// One Keychain generic-password item per key. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// keeps values off backups/other devices while still readable after the
/// wearer unlocks the phone once post-boot — sound alerts and memory recall
/// have to work without the wearer re-authenticating first.
struct KeychainSecureLocalStore: SecureLocalStore {
    private let service: String

    init(service: String = "com.brownmellon.securestore") {
        self.service = service
    }

    func save<T: Codable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(forKey: key)

        // SecItemUpdate fails (errSecItemNotFound) on first write, so try
        // update first and fall back to add — avoids a delete+add race.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    func load<T: Codable>(forKey key: String) throws -> T? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.osStatus(status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

enum KeychainError: Error {
    case osStatus(OSStatus)
}
