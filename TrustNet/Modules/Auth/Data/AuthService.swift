import Foundation

/// The production ``AuthServiceProtocol``.
///
/// Talks to `https://portal.gmai.sa/socialsa/api/v1` through the injected
/// ``NetworkClient``, and owns the token lifecycle via ``AuthTokenStore``:
/// every successful call that yields a ``TokenPair`` persists it, and every
/// authenticated call transparently refreshes an expiring access token first.
public final class AuthService: AuthServiceProtocol {

    private let network: NetworkClient
    private let store: AuthTokenStore
    private let biometrics: BiometricAuthenticating
    private let analytics: AnalyticsClient

    public init(
        network: NetworkClient,
        store: AuthTokenStore,
        biometrics: BiometricAuthenticating,
        analytics: AnalyticsClient
    ) {
        self.network = network
        self.store = store
        self.biometrics = biometrics
        self.analytics = analytics
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

    public func verifyOTP(email: String, code: String, purpose: OTPPurpose) async throws -> TokenPair {
        let request = try APIRequest.json(
            "/auth/otp/verify",
            body: OTPVerifyBody(email: normalise(email), code: code, purpose: purpose.rawValue)
        )
        let pair = try await network.send(request, as: TokenPair.self)
        await store.store(pair)
        analytics.track(.otpVerified, properties: ["purpose": purpose.rawValue])
        return pair
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
                await store.enableBiometrics(for: normalise(email))
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
            throw APIError.biometricFailed("No saved TrustNet sign-in on this device.")
        }
        guard let token = await store.token() else {
            throw APIError.biometricFailed("Your saved session has expired. Sign in with your password.")
        }

        try await biometrics.authenticate(
            reason: "Sign in to TrustNet as \(email)"
        )

        let pair = try await refreshToken(token)
        analytics.track(.biometricSignIn)
        return pair
    }

    public func refreshToken(_ token: AuthToken) async throws -> TokenPair {
        let request = try APIRequest.json(
            "/auth/refresh",
            body: RefreshRequestBody(refreshToken: token.refreshToken)
        )
        do {
            let pair = try await network.send(request, as: TokenPair.self)
            await store.store(pair)
            return pair
        } catch {
            // A rejected refresh token means the session is unrecoverable.
            if let apiError = error as? APIError, Self.isUnrecoverable(apiError) {
                await store.clear()
            }
            throw error
        }
    }

    public func signOut() async throws {
        if let token = await store.token() {
            let request = APIRequest(path: "/auth/logout", method: .post, accessToken: token.accessToken)
            // A failed logout must never trap the user in a signed-in state —
            // the local wipe below is what actually ends the session.
            try? await network.send(request)
        }
        await store.clear()
        analytics.track(.signedOut)
    }

    /// `true` when the server has told us the credentials can never work again.
    static func isUnrecoverable(_ error: APIError) -> Bool {
        switch error {
        case .unauthenticated:
            return true
        case let .http(status, _):
            return status == 401 || status == 403
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
