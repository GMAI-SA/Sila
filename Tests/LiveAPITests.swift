import XCTest
@testable import Sila

/// Round-trips a real backend — the staging API, see ``LiveTarget`` — through
/// the app's own networking and decoding stack. Every other test in this suite
/// runs against fixtures, so this is the only place a change in the *server's*
/// payload shape can be caught — a wire format that drifts (dates, enum
/// spellings, error envelopes) breaks the app while the fixture tests stay
/// green.
///
/// Opt-in, because it needs the network and a seeded account:
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
/// TEST_RUNNER_SILA_LIVE_EMAIL=... TEST_RUNNER_SILA_LIVE_PASSWORD=... \
///   xcodebuild ... test -only-testing:SilaTests/LiveAPITests
/// ```
final class LiveAPITests: XCTestCase {

    private var credentials: (email: String, password: String)?

    override func setUpWithError() throws {
        _ = try LiveTarget.api()
        credentials = try LiveTarget.credentials()
    }

    private func makeService() -> AuthService {
        AuthService(
            network: LiveTarget.network(),
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
