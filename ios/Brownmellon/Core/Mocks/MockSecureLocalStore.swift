import Foundation

/// In-memory stand-in for `KeychainSecureLocalStore` — resets on relaunch.
/// Used until Setup Mode is wired to the real Keychain-backed store, and
/// in tests/previews so nothing touches the real Keychain.
final class MockSecureLocalStore: SecureLocalStore {
    private var storage: [String: Data] = [:]

    func save<T: Codable>(_ value: T, forKey key: String) throws {
        storage[key] = try JSONEncoder().encode(value)
    }

    func load<T: Codable>(forKey key: String) throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
