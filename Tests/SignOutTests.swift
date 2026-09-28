import XCTest
@testable import Sila

/// Signing out ends the session on the server as well as on the phone, even
/// when the access token can no longer say which session that is (contract
/// v26 §1): the refresh token goes in the body.
final class SignOutTests: XCTestCase {

    private func make(
        _ network: ScriptedNetwork,
        stored: TokenPair = AuthFixtures.pair()
    ) async -> (AuthService, AuthTokenStore, InMemoryKeychainClient) {
        let keychain = InMemoryKeychainClient()
        let store = AuthTokenStore(keychain: keychain, storage: InMemoryStorageClient(), leftovers: .isolated())
        await store.store(stored)
        let service = AuthService(
            network: network,
            store: store,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        return (service, store, keychain)
    }

    private func body(_ request: APIRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.body, "\(request.path) was sent with no body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSignOutSendsTheRefreshTokenBesideTheAccessToken() async throws {
        let network = ScriptedNetwork { _ in "" }
        let (service, _, _) = await make(network)

        try await service.signOut()

        let logout = try XCTUnwrap(network.requests.first { $0.path == "/auth/logout" })
        XCTAssertEqual(logout.method, .post)
        XCTAssertEqual(logout.accessToken, "access-0", "the header still names the session")
        XCTAssertEqual(try body(logout)["refresh_token"] as? String, "refresh-0")
        XCTAssertNil(logout.contentType, "a JSON body, as the server reads it")
    }

    /// Half an hour after the app last ran, the access token has expired.
    /// Sign-out does not refresh first — a refresh would only mint a pair to
    /// throw away — it hands the server both tokens and lets it find the
    /// session.
    func testAnExpiredAccessTokenStillEndsTheSessionWithoutARefresh() async throws {
        let network = ScriptedNetwork { _ in "" }
        let (service, _, _) = await make(network, stored: AuthFixtures.pair(expiresIn: -600))

        try await service.signOut()

        XCTAssertEqual(network.count("/auth/refresh"), 0)
        XCTAssertEqual(network.count("/auth/logout"), 1)
        let logout = try XCTUnwrap(network.requests.first { $0.path == "/auth/logout" })
        XCTAssertEqual(try body(logout)["refresh_token"] as? String, "refresh-0")
    }

    /// The local wipe is what ends the session on the phone, whatever the
    /// server said.
    func testARefusedOrUnreachableLogoutStillSignsThePhoneOut() async throws {
        for failure in [APIError.transport("offline"), AuthFixtures.refused] {
            let network = ScriptedNetwork { _ in throw failure }
            let (service, store, keychain) = await make(network)

            try await service.signOut()

            let token = await store.token()
            XCTAssertNil(token, "\(failure) kept the session")
            XCTAssertNil(try keychain.load(.authToken))
        }
    }
}
