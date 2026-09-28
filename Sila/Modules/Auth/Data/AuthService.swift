import Foundation

/// The production ``AuthServiceProtocol``.
///
/// Talks to `https://sila.gmai.sa/api/v1` through the injected
/// ``NetworkClient``, and owns the token lifecycle via ``AuthTokenStore``:
/// every successful call that yields a ``TokenPair`` persists it, and every
/// authenticated call transparently refreshes an expiring access token first.
public final class AuthService: AuthServiceProtocol {

    private let network: NetworkClient
    private let store: AuthTokenStore
    private let biometrics: BiometricAuthenticating
    private let analytics: AnalyticsClient
    /// Every refresh, from every caller, goes through this one.
    private let refresher = TokenRefresher()
    /// Returns when sign-out has waited for `/auth/logout` long enough.
    private let signOutDeadline: @Sendable () async -> Void

    /// - Parameter signOutDeadline: How long sign-out waits for the server
    ///   before the phone signs itself out without it. Defaults to
    ///   ``AppConfig/signOutDeadline``.
    public init(
        network: NetworkClient,
        store: AuthTokenStore,
        biometrics: BiometricAuthenticating,
        analytics: AnalyticsClient,
        signOutDeadline: @escaping @Sendable () async -> Void = { await Deadline.sleep(AppConfig.signOutDeadline) }
    ) {
        self.network = network
        self.store = store
        self.biometrics = biometrics
        self.analytics = analytics
        self.signOutDeadline = signOutDeadline
    }

    public var availableBiometry: BiometryKind { biometrics.availableBiometry }

    // MARK: - Registration & OTP

    public func register(email: String, password: String) async throws -> RegistrationResult {
        let request = try APIRequest.json(
            "/auth/register",
            body: RegisterRequestBody(email: normalise(email), password: password)
        )
        let result = try await network.send(request, as: RegistrationResult.self)
        analytics.track(.registerSubmitted)
        return result
    }

    public func sendOTP(email: String, purpose: OTPPurpose) async throws -> OTPSendResult {
        let request = try APIRequest.json(
            "/auth/otp/request",
            body: OTPRequestBody(email: normalise(email), purpose: purpose.rawValue)
        )
        let result = try await network.send(request, as: OTPSendResult.self)
        analytics.track(.otpRequested, properties: ["purpose": purpose.rawValue])
        return result
    }

    public func resetPassword(email: String, code: String, newPassword: String) async throws {
        struct Body: Encodable {
            let email: String
            let code: String
            let newPassword: String
        }
        struct Accepted: Decodable { let reset: Bool? }
        let request = try APIRequest.json(
            "/auth/password/reset",
            body: Body(email: normalise(email), code: code, newPassword: newPassword)
        )
        _ = try await network.send(request, as: Accepted.self)
        analytics.track(.passwordReset)
    }

    public func verifyOTP(email: String, code: String, purpose: OTPPurpose, password: String?) async throws -> TokenPair {
        let request = try APIRequest.json(
            "/auth/otp/verify",
            body: OTPVerifyBody(
                email: normalise(email),
                code: code,
                purpose: purpose.rawValue,
                password: password.flatMap(Self.sendableWithCode)
            )
        )
        let pair = try await network.send(request, as: TokenPair.self)
        await store.store(pair)
        analytics.track(.otpVerified, properties: ["purpose": purpose.rawValue])
        return pair
    }

    /// `password`, when the server would accept it beside a code: 8 to 128
    /// characters and at most 72 bytes (contract v26 §7.1). Anything else is
    /// refused before the code is looked at — `422` or `password_too_long` —
    /// and a password typed at sign-in can be exactly that: one set before
    /// the 72-byte rule still signs in, and would then keep its owner from
    /// ever confirming the address. Such a password is not sent, and the code
    /// is judged on its own, as it was before the field existed.
    static func sendableWithCode(_ password: String) -> String? {
        // The server counts code points, not what Swift calls characters.
        let length = password.unicodeScalars.count
        guard (8...128).contains(length), password.utf8.count <= 72 else { return nil }
        return password
    }

    // MARK: - Sign in / out

    public func signIn(email: String, password: String) async throws -> TokenPair {
        let request = try APIRequest.json(
            "/auth/login",
            body: LoginRequestBody(email: normalise(email), password: password)
        )
        do {
            let pair = try await network.send(request, as: TokenPair.self)
            await store.store(pair)
            if biometrics.availableBiometry != .none {
                // The label is what the Face ID prompt will *say*. It prefers
                // the handle to the account's email because a phone-registered
                // account's email is a placeholder nobody should ever read.
                await store.enableBiometrics(
                    for: normalise(email),
                    label: pair.user.biometricIdentityLabel
                )
            }
            analytics.track(.signInSucceeded)
            return pair
        } catch {
            analytics.track(.signInFailed)
            throw error
        }
    }

    public func signInBiometric() async throws -> TokenPair {
        guard let email = await store.biometricEmail() else {
            throw APIError.biometricFailed(L10n.t("auth.biometric.error.noSavedSignIn"))
        }
        guard let token = await store.token() else {
            throw APIError.biometricFailed(L10n.t("auth.biometric.error.sessionExpired"))
        }

        // The prompt names the identity, not the credential: the stored label
        // (handle → phone → email), falling back to the email for credentials
        // saved before labels existed.
        let label = await store.biometricLabel() ?? email
        try await biometrics.authenticate(
            reason: L10n.t("auth.biometric.prompt", label)
        )

        let pair = try await refreshToken(token)
        analytics.track(.biometricSignIn)
        return pair
    }

    /// Rotates the pair, single-flight: callers that arrive while a refresh is
    /// running share its result, and a caller holding a token that has already
    /// been rotated gets the stored pair without another round trip.
    public func refreshToken(_ token: AuthToken) async throws -> TokenPair {
        try await refresher.run { [network, store] in
            try await Self.rotate(from: token, network: network, store: store)
        }
    }

    /// One refresh. Only ever runs inside ``refresher``.
    ///
    /// - Parameter seen: The token the caller read. It may be stale by now:
    ///   the store is re-read first, and the stored refresh token is the one
    ///   sent, because the one the caller saw may already have been used.
    private static func rotate(
        from seen: AuthToken,
        network: NetworkClient,
        store: AuthTokenStore
    ) async throws -> TokenPair {
        guard let current = await store.token() else { throw APIError.unauthenticated }
        // A refresh finished just before this caller arrived. Its pair is the
        // session now, and while it is fresh there is nothing to do.
        if current.refreshToken != seen.refreshToken, !current.expiresSoon(), let user = await store.user() {
            return TokenPair(token: current, user: user)
        }

        let request = try APIRequest.json(
            "/auth/refresh",
            body: RefreshRequestBody(refreshToken: current.refreshToken)
        )
        let pair: TokenPair
        do {
            pair = try await network.send(request, as: TokenPair.self)
        } catch {
            // A refused refresh token means that session is over, but only
            // that one: if the store has moved on meanwhile, it is kept.
            if let apiError = error as? APIError, isUnrecoverable(apiError) {
                await store.clear(ifRefreshTokenIs: current.refreshToken)
            }
            throw error
        }

        if await store.store(pair, replacing: current.refreshToken) {
            return pair
        }
        // Signed out, or signed in afresh, while the refresh was out: what is
        // stored now is the session, and the rotated pair is not brought back.
        guard let now = await store.token(), let user = await store.user() else {
            throw APIError.unauthenticated
        }
        return TokenPair(token: now, user: user)
    }

    public func signOut() async throws {
        if let token = await store.token() {
            // The refresh token travels in the body as well as the access
            // token in the header (contract v26 §1). An access token that has
            // expired still names its session, but one the server cannot read
            // at all does not, and then the refresh token is what says which
            // session to end — rather than leaving a thirty-day token alive on
            // the server after the phone has forgotten it.
            let request = try? APIRequest.json(
                "/auth/logout",
                body: LogoutRequestBody(refreshToken: token.refreshToken),
                accessToken: token.accessToken
            )
            // A failed logout must never trap the user in a signed-in state —
            // the local wipe below is what actually ends the session. Nor may
            // a slow one: offline, the request would wait up to forty-five
            // seconds for a connection (`AppConfig.connectivityWait`), and
            // sign-out waited with it. The server gets a few seconds
            // (`AppConfig.signOutDeadline`); then the request is abandoned and
            // the phone signs out without it.
            if let request {
                let network = network
                await Deadline.run({ try? await network.send(request) }, until: signOutDeadline)
            }
        }
        await store.clear()
        analytics.track(.signedOut)
    }

    /// `true` when the server has told us the credentials can never work again.
    ///
    /// That is a `401`, and nothing else. A `403` from the API always carries
    /// a code (suspended, deletion pending, unverified), none of which means
    /// the token is dead; a bare `403` with no code is a proxy or a firewall
    /// page, which says nothing about the session at all.
    static func isUnrecoverable(_ error: APIError) -> Bool {
        switch error {
        case .unauthenticated:
            return true
        case let .http(status, _):
            return status == 401
        case let .api(_, _, status):
            return status == 401
        default:
            return false
        }
    }

    // MARK: - Session queries

    public func currentUser() async throws -> AuthUser {
        let token = try await validAccessToken()
        let request = APIRequest(path: "/auth/me", accessToken: token)
        let user = try await network.send(request, as: AuthUser.self)
        await store.updateUser(user)
        return user
    }

    public func verificationStatus() async throws -> VerificationStatusReport {
        let token = try await validAccessToken()
        let request = APIRequest(path: "/verification/status", accessToken: token)
        return try await network.send(request, as: VerificationStatusReport.self)
    }

    public func biometricEmail() async -> String? {
        await store.biometricEmail()
    }

    // MARK: - Helpers

    /// Returns an access token that is good for at least another minute,
    /// refreshing the pair first if necessary.
    private func validAccessToken() async throws -> String {
        guard let token = await store.token() else { throw APIError.unauthenticated }
        guard token.expiresSoon() else { return token.accessToken }
        let refreshed = try await refreshToken(token)
        return refreshed.token.accessToken
    }

    private func normalise(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
