import Foundation
import Security

/// Keys used by Sila's keychain items.
public struct KeychainKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// The persisted ``AuthToken``.
    public static let authToken = KeychainKey("auth.token")
    /// The email associated with the stored biometric credential.
    ///
    /// Retained for sign-in-form prefill and as the display fallback for
    /// credentials saved before ``biometricLabel`` existed.
    public static let biometricEmail = KeychainKey("auth.biometric.email")
    /// The human-readable identity the biometric prompt names — the handle
    /// when the account has one, else the phone, else the email. Kept separate
    /// from ``biometricEmail`` because a phone-registered account's email is a
    /// machine placeholder that must never be put in front of the user at the
    /// exact moment the prompt is asking for trust.
    public static let biometricLabel = KeychainKey("auth.biometric.label")
    /// The cached ``AuthUser`` used to route on cold launch before `/auth/me` returns.
    public static let cachedUser = KeychainKey("auth.user")
}

/// Failures the keychain can surface.
public enum KeychainError: Error, Equatable {
    /// `SecItemAdd`/`SecItemUpdate`/`SecItemDelete` returned a non-success status.
    case status(OSStatus)
    /// The stored blob could not be decoded into the requested type.
    case decoding(String)
}

/// The mockable seam for secret storage.
///
/// Items are written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
/// tokens never leave the device via iCloud Keychain or an encrypted backup,
/// and are unreadable while the device is locked.
public protocol KeychainClient: Sendable {
    /// Writes raw bytes, replacing any existing item for `key`.
    func save(_ data: Data, for key: KeychainKey) throws
    /// Reads raw bytes, or `nil` when the item does not exist.
    func load(_ key: KeychainKey) throws -> Data?
    /// Deletes an item. Deleting a missing item is not an error.
    func delete(_ key: KeychainKey) throws
    /// Deletes every item this app owns.
    func deleteAll() throws
}

extension KeychainClient {
    /// Encodes and stores a `Codable` value.
    public func save<T: Encodable>(_ value: T, for key: KeychainKey) throws {
        let data = try JSONCoding.encoder.encode(value)
        try save(data, for: key)
    }

    /// Loads and decodes a `Codable` value, returning `nil` when absent.
    /// - Throws: ``KeychainError/decoding(_:)`` when a stored blob is unreadable.
    public func load<T: Decodable>(_ key: KeychainKey, as type: T.Type) throws -> T? {
        guard let data = try load(key) else { return nil }
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw KeychainError.decoding("Stored \(T.self) is unreadable: \(error)")
        }
    }

    /// Stores a UTF-8 string.
    public func saveString(_ value: String, for key: KeychainKey) throws {
        try save(Data(value.utf8), for: key)
    }

    /// Loads a UTF-8 string.
    public func loadString(_ key: KeychainKey) throws -> String? {
        guard let data = try load(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Production ``KeychainClient`` built on `SecItem*`.
public struct SystemKeychainClient: KeychainClient {

    private let service: String

    /// - Parameter service: `kSecAttrService` value. Defaults to the app's bundle id.
    public init(service: String = "com.socialsa.sila") {
        self.service = service
    }

    public func save(_ data: Data, for key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus)
        }
    }

    public func load(_ key: KeychainKey) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func delete(_ key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

/// In-memory ``KeychainClient`` for tests, previews and the simulator's
/// occasionally hostile keychain.
public final class InMemoryKeychainClient: KeychainClient, @unchecked Sendable {

    private var box: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ data: Data, for key: KeychainKey) throws {
        lock.lock(); defer { lock.unlock() }
        box[key.rawValue] = data
    }

    public func load(_ key: KeychainKey) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return box[key.rawValue]
    }

    public func delete(_ key: KeychainKey) throws {
        lock.lock(); defer { lock.unlock() }
        box[key.rawValue] = nil
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        box.removeAll()
    }
}
