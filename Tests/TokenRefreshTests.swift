import XCTest
@testable import Sila

// MARK: - The server's rule

/// The server's rule for refresh tokens: each one works once. A second use
/// is refused `401`, exactly as `routers/auth.py` revokes on first use.
final class SingleUseRefreshServer: @unchecked Sendable {

    private let lock = NSLock()
    private var used: Set<String> = []
    private var issued = 0
    private let delay: UInt64

    /// - Parameter delay: How long each accepted refresh takes to answer.
    init(delay: TimeInterval = 0.2) {
        self.delay = UInt64(delay * 1_000_000_000)
    }

    func refresh(_ request: APIRequest) async throws -> String {
        let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
        let token = body?["refresh_token"] as? String ?? ""
        let number: Int? = lock.withLock {
            guard !used.contains(token) else { return nil }
            used.insert(token)
            issued += 1
            return issued
        }
        guard let number else { throw AuthFixtures.refused }
        try? await Task.sleep(nanoseconds: delay)
        return AuthFixtures.pairJSON(access: "access-\(number)", refresh: "refresh-\(number)")
    }
}

// MARK: - Single-flight refresh

/// The access token is fetched from about 150 places, and after half an hour
/// in the background many of them find it expiring at the same moment. The
/// server revokes a refresh token on first use, so two refreshes with the
/// same token sign the person out — unless only one ever goes out.
final class TokenRefreshTests: XCTestCase {

    private func make(
        _ network: ScriptedNetwork,
        stored: TokenPair? = AuthFixtures.pair(expiresIn: 10)
    ) async -> (AuthService, AuthTokenStore, SessionAccessTokenProvider) {
        let store = AuthTokenStore(
            keychain: InMemoryKeychainClient(),
            storage: InMemoryStorageClient(),
            leftovers: .isolated()
        )
        if let stored { await store.store(stored) }
        let service = AuthService(
            network: network,
            store: store,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        return (service, store, SessionAccessTokenProvider(store: store, service: service))
    }

    private func refreshOnly(_ server: SingleUseRefreshServer) -> ScriptedNetwork {
        ScriptedNetwork { request in
            guard request.path == "/auth/refresh" else { throw APIError.http(status: 404, message: "") }
            return try await server.refresh(request)
        }
    }

    /// The finding's own scenario: two callers, a token ten seconds from
    /// expiry, a server that answers the first refresh after 200 ms and
    /// refuses any refresh token it has seen before.
    func testTwoCallersAroundExpiryShareOneRefreshAndStaySignedIn() async throws {
        let network = refreshOnly(SingleUseRefreshServer(delay: 0.2))
        let (_, store, provider) = await make(network)

        async let a = provider.accessToken()
        async let b = provider.accessToken()
        let (first, second) = try await (a, b)

        XCTAssertEqual(network.count("/auth/refresh"), 1, "exactly one refresh went out")
        XCTAssertEqual(first, "access-1")
        XCTAssertEqual(second, first, "both callers got the same new access token")
        let stored = await store.token()
        XCTAssertNotNil(stored, "the session survived")
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
    }

    /// Coming back from the background: the feed, the unread badges, push
    /// re-registration and the telemetry flush, all at once.
    func testEveryCallerThatWakesTogetherGetsTheOneRefresh() async throws {
        let network = refreshOnly(SingleUseRefreshServer(delay: 0.2))
        let (_, store, provider) = await make(network)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 { group.addTask { try await provider.accessToken() } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        XCTAssertEqual(network.count("/auth/refresh"), 1)
        XCTAssertEqual(Set(tokens), ["access-1"])
        let stored = await store.token()
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
    }

    /// A caller that read the token just before a refresh finished holds a
    /// refresh token the server has already revoked. It is handed the stored
    /// pair instead of sending it.
    func testACallerHoldingAnAlreadyRotatedTokenIsHandedTheStoredPair() async throws {
        let network = refreshOnly(SingleUseRefreshServer(delay: 0))
        let stale = AuthFixtures.pair(expiresIn: 10)
        let (service, store, _) = await make(network, stored: stale)

        _ = try await service.refreshToken(stale.token)
        let again = try await service.refreshToken(stale.token)

        XCTAssertEqual(network.count("/auth/refresh"), 1, "the used token was never sent again")
        XCTAssertEqual(again.token.accessToken, "access-1")
        let stored = await store.token()
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
    }

    /// A refusal is about the token that was sent. A sign-in that stored a
    /// new session while the refused refresh was out keeps that session.
    func testARefusalOfAReplacedTokenKeepsTheNewSession() async throws {
        let network = ScriptedNetwork { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            throw AuthFixtures.refused
        }
        let old = AuthFixtures.pair(expiresIn: 10)
        let (service, store, _) = await make(network, stored: old)

        let refresh = Task { try await service.refreshToken(old.token) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.store(AuthFixtures.pair(access: "fresh-access", refresh: "fresh-refresh"))
        _ = try? await refresh.value

        let stored = await store.token()
        XCTAssertEqual(stored?.refreshToken, "fresh-refresh", "a refusal of the old token wiped the new session")
    }

    /// The refused token is still the stored one: that session is over.
    func testARefusalOfTheStoredTokenEndsTheSession() async {
        let network = ScriptedNetwork { _ in throw AuthFixtures.refused }
        let (service, store, _) = await make(network)
        let stored = await store.token()

        do {
            _ = try await service.refreshToken(try XCTUnwrap(stored))
            XCTFail("a refused refresh must throw")
        } catch {
            XCTAssertEqual(error as? APIError, AuthFixtures.refused)
        }
        let after = await store.token()
        XCTAssertNil(after)
    }

    /// Signed out while the refresh was out: the rotated pair it brings back
    /// does not bring the session back with it.
    func testARefreshThatLandsAfterSignOutDoesNotRestoreTheSession() async throws {
        let network = refreshOnly(SingleUseRefreshServer(delay: 0.2))
        let old = AuthFixtures.pair(expiresIn: 10)
        let (service, store, _) = await make(network, stored: old)

        let refresh = Task { try await service.refreshToken(old.token) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.clear()

        do {
            _ = try await refresh.value
            XCTFail("a refresh for an ended session must not hand back a pair")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthenticated)
        }
        let after = await store.token()
        XCTAssertNil(after, "the signed-out session came back")
    }

    /// A `403` with no code is a proxy's or a firewall's page, not the API
    /// declaring the token dead.
    func testAForbiddenPageWithNoCodeDoesNotEndTheSession() async {
        let network = ScriptedNetwork { _ in throw APIError.http(status: 403, message: "<html>Access denied</html>") }
        let (service, store, _) = await make(network)
        let stored = await store.token()

        _ = try? await service.refreshToken(try XCTUnwrap(stored))

        let after = await store.token()
        XCTAssertNotNil(after)
    }

    /// A caller cancelled mid-refresh (a screen that went away) does not
    /// cancel the refresh the others are waiting on.
    func testACancelledCallerDoesNotCancelTheSharedRefresh() async throws {
        let network = refreshOnly(SingleUseRefreshServer(delay: 0.2))
        let (_, store, provider) = await make(network)

        let leaving = Task { try await provider.accessToken() }
        let staying = Task { try await provider.accessToken() }
        try await Task.sleep(nanoseconds: 50_000_000)
        leaving.cancel()

        let token = try await staying.value
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(network.count("/auth/refresh"), 1)
        let stored = await store.token()
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
    }

    func testOnlyA401CountsAsDeadCredentials() {
        XCTAssertTrue(AuthService.isUnrecoverable(.unauthenticated))
        XCTAssertTrue(AuthService.isUnrecoverable(AuthFixtures.refused))
        XCTAssertTrue(AuthService.isUnrecoverable(.http(status: 401, message: "")))
        XCTAssertFalse(AuthService.isUnrecoverable(.http(status: 403, message: "<html>")))
        XCTAssertFalse(AuthService.isUnrecoverable(.api(code: .accountSuspended, message: "", status: 403)))
        XCTAssertFalse(AuthService.isUnrecoverable(.api(code: .accountDeactivated, message: "", status: 403)))
        XCTAssertFalse(AuthService.isUnrecoverable(.http(status: 502, message: "Bad Gateway")))
        XCTAssertFalse(AuthService.isUnrecoverable(.transport("offline")))
        XCTAssertFalse(AuthService.isUnrecoverable(.cancelled))
    }
}
