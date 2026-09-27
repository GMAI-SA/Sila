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
    private let leftovers: SessionLeftovers

    private var cachedToken: AuthToken?
    private var cachedUser: AuthUser?
    private var didHydrate = false

    /// - Parameters:
    ///   - keychain: Where the secrets live.
    ///   - storage: Flags and the last email; also where the install marker is kept.
    ///   - leftovers: What ``clear()`` sweeps besides the keychain.
    public init(
        keychain: KeychainClient,
        storage: StorageClient,
        leftovers: SessionLeftovers = SessionLeftovers()
    ) {
        self.keychain = keychain
        self.storage = storage
        self.leftovers = leftovers
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

    /// Persists a pair rotated from `refreshToken`, but only while that is
    /// still the session on this device.
    ///
    /// A refresh takes a network round trip. If the person signed out, or
    /// signed in again, while it was out, the pair it brings back belongs to a
    /// session that has ended, and storing it would bring that session back.
    /// - Returns: `false` when the store holds something else now.
    public func store(_ pair: TokenPair, replacing refreshToken: String) -> Bool {
        hydrateIfNeeded()
        guard cachedToken?.refreshToken == refreshToken else { return false }
        store(pair)
        return true
    }

    /// Updates only the cached user (e.g. after `/auth/me` or a status poll).
    public func updateUser(_ user: AuthUser) {
        hydrateIfNeeded()
        cachedUser = user
        try? keychain.save(user, for: .cachedUser)
    }

    /// Marks this device as biometric-enabled for `email`.
    ///
    /// - Parameters:
    ///   - email: The address the credential belongs to — still stored, because
    ///     it prefills the sign-in form.
    ///   - label: What the biometric prompt should *call* the account — the
    ///     handle when there is one, else the phone, else the email. `nil`
    ///     stores no label, and display falls back to the email.
    public func enableBiometrics(for email: String, label: String? = nil) {
        try? keychain.saveString(email, for: .biometricEmail)
        if let label, !label.isEmpty {
            try? keychain.saveString(label, for: .biometricLabel)
        } else {
            try? keychain.delete(.biometricLabel)
        }
        storage.setFlag(true, for: .biometricEnabled)
    }

    /// The email a biometric credential exists for, if any.
    public func biometricEmail() -> String? {
        guard storage.flag(.biometricEnabled) else { return nil }
        return try? keychain.loadString(.biometricEmail)
    }

    /// What the biometric prompt should call the saved account.
    ///
    /// The stored label when one exists; otherwise the stored email, so a
    /// credential saved by a build that predates labels keeps working exactly
    /// as it always did.
    public func biometricLabel() -> String? {
        guard storage.flag(.biometricEnabled) else { return nil }
        if let label = try? keychain.loadString(.biometricLabel), !label.isEmpty {
            return label
        }
        return try? keychain.loadString(.biometricEmail)
    }

    /// Wipes token, cached user and biometric credential, and sweeps what the
    /// session left on disk: the account export and the shared URL cache.
    public func clear() {
        cachedToken = nil
        cachedUser = nil
        didHydrate = true
        try? keychain.delete(.authToken)
        try? keychain.delete(.cachedUser)
        try? keychain.delete(.biometricEmail)
        try? keychain.delete(.biometricLabel)
        storage.setFlag(false, for: .biometricEnabled)
        leftovers.sweep()
    }

    /// Wipes the session only if it is still the one whose refresh token the
    /// server just refused.
    ///
    /// A refusal is a fact about the token that was sent. If the store has
    /// moved on since — a new sign-in, or a pair another caller rotated — the
    /// refusal says nothing about what is stored now, and wiping it would sign
    /// somebody out of a perfectly good session.
    /// - Returns: `true` when the session was wiped.
    @discardableResult
    public func clear(ifRefreshTokenIs refreshToken: String) -> Bool {
        hydrateIfNeeded()
        guard cachedToken?.refreshToken == refreshToken else { return false }
        clear()
        return true
    }

    private func hydrateIfNeeded() {
        guard !didHydrate else { return }
        didHydrate = true
        forgetAPreviousInstallIfNeeded()
        cachedToken = (try? keychain.load(.authToken, as: AuthToken.self)) ?? nil
        cachedUser = (try? keychain.load(.cachedUser, as: AuthUser.self)) ?? nil
    }

    /// Wipes a session left over from an earlier install of the app, before
    /// anything reads it.
    ///
    /// iOS deletes an app's UserDefaults along with the app but keeps its
    /// Keychain items. Somebody who deletes Sila to sign out of a shared or
    /// handed-down phone would otherwise be signed straight back in by
    /// reinstalling it within the refresh token's thirty days, with their
    /// cached account — verified name included — still there.
    private func forgetAPreviousInstallIfNeeded() {
        guard !storage.flag(.installed) else { return }
        // Builds from before the marker write the last email at every
        // sign-in. It surviving means UserDefaults survived: an update, not a
        // reinstall, and the session is the person's own.
        if storage.value(for: .lastSignedInEmail, as: String.self) != nil {
            storage.setFlag(true, for: .installed)
            return
        }
        do {
            // Read before deleting. An item kept `WhenUnlocked` cannot be read
            // while the phone is locked, and before the first unlock after a
            // restart UserDefaults reads back empty as well, which would look
            // exactly like a reinstall. A read that throws decides nothing: the
            // marker stays unset and the next launch asks again.
            _ = try keychain.load(.authToken)
            try keychain.deleteAll()
            storage.setFlag(true, for: .installed)
        } catch {
            return
        }
    }
}
