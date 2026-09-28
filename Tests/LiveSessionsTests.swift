import XCTest
@testable import Sila

/// Contract v26 on the staging API (see ``LiveTarget``), through the app's
/// own services and view models: the password travels with the code, and
/// sign-out ends the server's session even when the access token cannot say
/// which one it is.
///
/// Needs no account: each test registers a disposable
/// `itest-ios-…@example.com` address and reads its codes from staging's dev
/// peek. Opt-in:
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
///   xcodebuild … test -only-testing:SilaTests/LiveSessionsTests
/// ```
final class LiveSessionsTests: XCTestCase {

    private static let ownerPassword = "Owner!Passw0rd"
    private static let strangerPassword = "Stranger!Passw0rd"

    override func setUpWithError() throws {
        _ = try LiveTarget.api()
    }

    private func makeService() -> AuthService {
        AuthService(
            network: LiveTarget.network(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: .isolated()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func disposableEmail() -> String {
        "itest-ios-\(UUID().uuidString.prefix(12).lowercased())@example.com"
    }

    private func peek(_ email: String) async throws -> String {
        let answer = try await LiveTarget.dev("otp/peek", query: [URLQueryItem(name: "email", value: email)])
        return try XCTUnwrap(answer["code"] as? String, "no code recorded for \(email)")
    }

    /// Past the one-code-a-minute cooldown, without waiting a minute.
    private func age(_ email: String) async throws {
        _ = try await LiveTarget.dev("auth/age", body: ["email": email, "seconds": 120])
    }

    /// accounts F4 (contract v26 §7.1). A stranger registered the owner's
    /// address first; the owner registered it too, pressed "resend", and
    /// typed that code. A resent code carries nobody's password, and with two
    /// registrations on file the server cannot know whose to keep — so only
    /// the password the code screen sends makes the owner's the account's.
    @MainActor
    func testTheCodeScreenMakesTheOwnersPasswordTheAccountsOverAStrangers() async throws {
        let email = disposableEmail()
        let stranger = makeService()
        _ = try await stranger.register(email: email, password: Self.strangerPassword)
        try await age(email)

        let owner = makeService()
        let register = RegisterViewModel(service: owner)
        register.email = email
        register.password = Self.ownerPassword
        register.confirmPassword = Self.ownerPassword
        await register.submit()
        XCTAssertEqual(register.consumeRegisteredEmail(), email, "\(String(describing: register.toast))")
        let password = register.consumeRegisteredPassword()
        XCTAssertEqual(password, Self.ownerPassword)

        try await age(email)
        let code = OTPVerificationViewModel(email: email, purpose: .register, password: password, service: owner)
        await code.resend()
        code.paste(try await peek(email))
        await code.verify()
        XCTAssertNotNil(code.consumeVerifiedPair(), "\(code.errorMessage ?? "no error")")

        let signedIn = try await makeService().signIn(email: email, password: Self.ownerPassword)
        XCTAssertTrue(signedIn.user.emailVerified)
        do {
            _ = try await makeService().signIn(email: email, password: Self.strangerPassword)
            XCTFail("the stranger's password opened the owner's account")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCredentials)
        }
    }

    /// The code screen after a sign-in that answered `email_unverified`
    /// sends the password just typed.
    @MainActor
    func testTheCodeScreenAfterSignInSendsThePasswordJustTyped() async throws {
        let email = disposableEmail()
        _ = try await makeService().register(email: email, password: Self.strangerPassword)
        try await age(email)
        _ = try await makeService().register(email: email, password: Self.ownerPassword)
        try await age(email)

        let service = makeService()
        let signIn = SignInViewModel(service: service)
        signIn.email = email
        signIn.password = Self.ownerPassword
        await signIn.submit()
        XCTAssertEqual(signIn.consumeNeedsEmailVerification(), email, "\(String(describing: signIn.toast))")
        let password = signIn.consumePasswordForCode()
        XCTAssertEqual(password, Self.ownerPassword)

        let code = OTPVerificationViewModel(email: email, purpose: .login, password: password, service: service)
        code.paste(try await peek(email))
        await code.verify()
        XCTAssertNotNil(code.consumeVerifiedPair(), "\(code.errorMessage ?? "no error")")

        _ = try await makeService().signIn(email: email, password: Self.ownerPassword)
    }

    /// Contract v26 §1: an access token the server cannot read names no
    /// session, and the refresh token in the body does. Without it the
    /// server answered `401 sign_in_required`, the app wiped the phone
    /// anyway, and the thirty-day refresh token stayed good on the server.
    func testSignOutWithAnUnreadableAccessTokenStillEndsTheSession() async throws {
        let email = disposableEmail()
        let service = makeService()
        _ = try await service.register(email: email, password: Self.ownerPassword)
        let pair = try await service.verifyOTP(email: email, code: try await peek(email), purpose: .register, password: Self.ownerPassword)

        let staleStore = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: .isolated())
        await staleStore.store(TokenPair(
            token: AuthToken(accessToken: "no-longer-a-token", refreshToken: pair.token.refreshToken, expiresAt: Date().addingTimeInterval(-3600)),
            user: pair.user
        ))
        let stale = AuthService(
            network: LiveTarget.network(),
            store: staleStore,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        try await stale.signOut()

        let elsewhere = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: .isolated())
        await elsewhere.store(pair)
        let copy = AuthService(
            network: LiveTarget.network(),
            store: elsewhere,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        do {
            _ = try await copy.refreshToken(pair.token)
            XCTFail("the session outlived sign-out")
        } catch let error as APIError {
            XCTAssertTrue(AuthService.isUnrecoverable(error), "\(error)")
        }
    }
}
