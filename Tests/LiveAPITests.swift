import XCTest
@testable import TrustNet

/// Round-trips the real deployed backend through the app's own networking and
/// decoding stack. Every other test in this suite runs against fixtures, so
/// this is the only place a change in the *server's* payload shape can be
/// caught — a wire format that drifts (dates, enum spellings, error envelopes)
/// breaks the app while the fixture tests stay green.
///
/// Opt-in, because it needs the network and a seeded account:
/// ```
/// TRUSTNET_LIVE_API=1 TRUSTNET_LIVE_EMAIL=... TRUSTNET_LIVE_PASSWORD=... \
///   xcodebuild ... test -only-testing:TrustNetTests/LiveAPITests
/// ```
final class LiveAPITests: XCTestCase {

    private var credentials: (email: String, password: String)?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TRUSTNET_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set TRUSTNET_LIVE_API=1")
        }
        guard let email = env["TRUSTNET_LIVE_EMAIL"],
              let password = env["TRUSTNET_LIVE_PASSWORD"] else {
            throw XCTSkip("Set TRUSTNET_LIVE_EMAIL and TRUSTNET_LIVE_PASSWORD")
        }
        credentials = (email, password)
    }

    private func makeService() -> AuthService {
        AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
    }

    /// Sign in, read the account back, rotate the tokens, then sign out —
    /// decoding `TokenPair`, `AuthUser` and the date format straight off the wire.
    func testSignInThenMeThenRefresh() async throws {
        let creds = try XCTUnwrap(credentials)
        let service = makeService()

        let pair = try await service.signIn(email: creds.email, password: creds.password)
        XCTAssertFalse(pair.token.accessToken.isEmpty)
        XCTAssertFalse(pair.token.refreshToken.isEmpty)
        XCTAssertGreaterThan(pair.token.expiresAt, Date(), "access token should expire in the future")
        XCTAssertEqual(pair.user.email.lowercased(), creds.email.lowercased())
        XCTAssertTrue(pair.user.emailVerified)

        let me = try await service.currentUser()
        XCTAssertEqual(me.id, pair.user.id)

        let report = try await service.verificationStatus()
        XCTAssertEqual(report.status, me.verificationStatus, "/verification/status and /auth/me must agree")

        let rotated = try await service.refreshToken(pair.token)
        XCTAssertNotEqual(rotated.token.refreshToken, pair.token.refreshToken, "refresh token must rotate")

        try await service.signOut()
    }

    /// The server's error envelope must decode into a typed `APIError`, not a
    /// generic decoding failure — the sign-in screen branches on these codes.
    func testWrongPasswordDecodesTypedError() async throws {
        let creds = try XCTUnwrap(credentials)
        let service = makeService()

        do {
            _ = try await service.signIn(email: creds.email, password: "definitely-not-the-password")
            XCTFail("expected the server to reject a wrong password")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCredentials)
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    /// Registering an address that already exists is the conflict the register
    /// screen surfaces inline.
    func testDuplicateRegistrationDecodesTypedError() async throws {
        let creds = try XCTUnwrap(credentials)
        let service = makeService()

        do {
            _ = try await service.register(email: creds.email, password: "Passw0rd!234")
            XCTFail("expected the server to reject a duplicate registration")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .emailTaken)
        }
    }
}
