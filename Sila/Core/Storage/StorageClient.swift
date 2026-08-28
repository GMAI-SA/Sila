import Foundation

/// The mockable seam for non-sensitive local persistence.
///
/// Phase 1 stores only flags and the last-used email address, so a
/// `UserDefaults` implementation is sufficient. The protocol exists so that
/// swapping in SwiftData for later phases touches no call site.
///
/// > Important: Never put tokens or PII here — that is ``KeychainClient``'s job.
public protocol StorageClient: Sendable {
    /// Reads a `Codable` value, returning `nil` when absent or corrupt.
    func value<T: Decodable>(for key: StorageKey, as type: T.Type) -> T?
    /// Writes a `Codable` value.
    func set<T: Encodable>(_ value: T, for key: StorageKey)
    /// Removes a value.
    func remove(_ key: StorageKey)
    /// Reads a boolean flag, defaulting to `false`.
    func flag(_ key: StorageKey) -> Bool
    /// Writes a boolean flag.
    func setFlag(_ value: Bool, for key: StorageKey)
}

/// Namespaced keys accepted by ``StorageClient``.
public struct StorageKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Whether the user has opted into biometric sign-in.
    public static let biometricEnabled = StorageKey("com.socialsa.sila.biometricEnabled")
    /// Last email successfully used to sign in, prefilled on the sign-in screen.
    public static let lastSignedInEmail = StorageKey("com.socialsa.sila.lastSignedInEmail")
    /// Whether the welcome screen has ever been shown.
    public static let hasSeenWelcome = StorageKey("com.socialsa.sila.hasSeenWelcome")
}

/// `UserDefaults`-backed ``StorageClient``.
public final class UserDefaultsStorageClient: StorageClient, @unchecked Sendable {

    private let defaults: UserDefaults

    /// - Parameter defaults: Injectable suite. Tests pass a throwaway suite name.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value<T: Decodable>(for key: StorageKey, as type: T.Type) -> T? {
        if type == String.self { return defaults.string(forKey: key.rawValue) as? T }
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONCoding.decoder.decode(T.self, from: data)
    }

    public func set<T: Encodable>(_ value: T, for key: StorageKey) {
        if let string = value as? String {
            defaults.set(string, forKey: key.rawValue)
            return
        }
        guard let data = try? JSONCoding.encoder.encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    public func remove(_ key: StorageKey) {
        defaults.removeObject(forKey: key.rawValue)
    }

    public func flag(_ key: StorageKey) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    public func setFlag(_ value: Bool, for key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }
}

/// In-memory ``StorageClient`` for tests and previews.
public final class InMemoryStorageClient: StorageClient, @unchecked Sendable {

    private var box: [String: Any] = [:]
    private let lock = NSLock()

    public init() {}

    public func value<T: Decodable>(for key: StorageKey, as type: T.Type) -> T? {
        lock.lock(); defer { lock.unlock() }
        return box[key.rawValue] as? T
    }

    public func set<T: Encodable>(_ value: T, for key: StorageKey) {
        lock.lock(); defer { lock.unlock() }
        box[key.rawValue] = value
    }

    public func remove(_ key: StorageKey) {
        lock.lock(); defer { lock.unlock() }
        box[key.rawValue] = nil
    }

    public func flag(_ key: StorageKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (box[key.rawValue] as? Bool) ?? false
    }

    public func setFlag(_ value: Bool, for key: StorageKey) {
        lock.lock(); defer { lock.unlock() }
        box[key.rawValue] = value
    }
}
