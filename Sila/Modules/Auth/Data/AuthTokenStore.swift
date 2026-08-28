import Foundation

/// Owns the on-device lifetime of the session secrets.
///
/// An `actor` so concurrent callers (a screen refreshing while a background
/// task refreshes the token) cannot interleave reads and writes.
///
/// - The ``AuthToken`` lives in the keychain with
///   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
/// - The last ``AuthUser`` is cached alongside it purely so the splash screen
///   can route before `/auth/me` returns.
/// - The password is **never** written anywhere.
public actor AuthTokenStore {

    private let keychain: KeychainClient
    private let storage: StorageClient

    private var cachedToken: AuthToken?
    private var cachedUser: AuthUser?
    private var didHydrate = false

    public init(keychain: KeychainClient, storage: StorageClient) {
        self.keychain = keychain
        self.storage = storage
    }

    /// The stored token, loading it from the keychain on first access.
    public func token() -> AuthToken? {
        hydrateIfNeeded()
        return cachedToken
    }

    /// The cached user, loading it from the keychain on first access.
    public func user() -> AuthUser? {
        hydrateIfNeeded()
        return cachedUser
    }

    /// Persists a freshly issued pair, replacing anything already stored.
    public func store(_ pair: TokenPair) {
        hydrateIfNeeded()
        cachedToken = pair.token
        cachedUser = pair.user
        try? keychain.save(pair.token, for: .authToken)
        try? keychain.save(pair.user, for: .cachedUser)
        storage.set(pair.user.email, for: .lastSignedInEmail)
    }

    /// Updates only the cached user (e.g. after `/auth/me` or a status poll).
    public func updateUser(_ user: AuthUser) {
        hydrateIfNeeded()
        cachedUser = user
        try? keychain.save(user, for: .cachedUser)
    }

    /// Marks this device as biometric-enabled for `email`.
    public func enableBiometrics(for email: String) {
        try? keychain.saveString(email, for: .biometricEmail)
        storage.setFlag(true, for: .biometricEnabled)
    }

    /// The email a biometric credential exists for, if any.
    public func biometricEmail() -> String? {
        guard storage.flag(.biometricEnabled) else { return nil }
        return try? keychain.loadString(.biometricEmail)
    }

    /// Wipes token, cached user and biometric credential.
    public func clear() {
        cachedToken = nil
        cachedUser = nil
        didHydrate = true
        try? keychain.delete(.authToken)
        try? keychain.delete(.cachedUser)
        try? keychain.delete(.biometricEmail)
        storage.setFlag(false, for: .biometricEnabled)
    }

    private func hydrateIfNeeded() {
        guard !didHydrate else { return }
        didHydrate = true
        cachedToken = (try? keychain.load(.authToken, as: AuthToken.self)) ?? nil
        cachedUser = (try? keychain.load(.cachedUser, as: AuthUser.self)) ?? nil
    }
}
