import XCTest
@testable import Sila

/// Cold launch with a stored session, when the server cannot confirm it.
///
/// Opening the app in airplane mode, in a lift, or while a deploy answers
/// `502` used to delete a perfectly good session from the keychain and show
/// the welcome screen. Only the server saying the credentials are dead may
/// sign somebody out; everything else keeps the session, opens on the cached
/// account, and keeps trying.
@MainActor
final class OfflineRestoreTests: XCTestCase {

    private func make(
        _ network: ScriptedNetwork,
        stored: TokenPair? = AuthFixtures.pair(),
        // Short enough to finish inside a test, long enough not to spin.
        reconnectDelay: @escaping @Sendable (Int) async -> Void = { _ in try? await Task.sleep(nanoseconds: 20_000_000) }
    ) async -> (AuthSession, AuthTokenStore, InMemoryKeychainClient) {
        let keychain = InMemoryKeychainClient()
        let store = AuthTokenStore(keychain: keychain, storage: InMemoryStorageClient(), leftovers: .isolated())
        if let stored { await store.store(stored) }
        let service = AuthService(
            network: network,
            store: store,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        let session = AuthSession(
            service: service,
            store: store,
            analytics: RecordingAnalyticsClient(),
            reconnectDelay: reconnectDelay
        )
        return (session, store, keychain)
    }

    /// Polls until `condition` holds or the time runs out.
    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - Kept

    func testRestoreWhileOfflineKeepsTheSession() async {
        let network = ScriptedNetwork { _ in throw APIError.transport("The Internet connection appears to be offline.") }
        let (session, _, keychain) = await make(network)

        await session.restore()

        XCTAssertNotNil(try? keychain.load(.authToken), "an offline launch deleted the session")
        XCTAssertNotEqual(session.route, .unauthenticated)
        XCTAssertEqual(session.route, .feed, "routed on the account cached in the keychain")
        XCTAssertEqual(session.user?.email, "aziz@example.com")
        XCTAssertTrue(session.isOffline, "the app says it is offline")
    }

    func testRestoreDuringADeployThatAnswers502KeepsTheSession() async {
        let network = ScriptedNetwork { _ in throw APIError.http(status: 502, message: "<html>502 Bad Gateway</html>") }
        let (session, _, keychain) = await make(network)

        await session.restore()

        XCTAssertNotNil(try? keychain.load(.authToken))
        XCTAssertEqual(session.route, .feed)
        XCTAssertTrue(session.isOffline)
    }

    func testRestoreBehindACaptivePortalKeepsTheSession() async {
        // A hotel Wi-Fi's login page, answered 200 where JSON should be.
        let network = ScriptedNetwork { _ in "<html>Sign in to the Wi-Fi</html>" }
        let (session, _, keychain) = await make(network)

        await session.restore()

        XCTAssertNotNil(try? keychain.load(.authToken))
        XCTAssertEqual(session.route, .feed)
        XCTAssertTrue(session.isOffline)
    }

    /// An expiring token needs a refresh first; that failing offline is no
    /// more a refusal than `/auth/me` failing.
    func testRestoreWithAnExpiringTokenWhileOfflineKeepsTheSession() async {
        let network = ScriptedNetwork { _ in throw APIError.transport("offline") }
        let (session, _, keychain) = await make(network, stored: AuthFixtures.pair(expiresIn: 10))

        await session.restore()

        XCTAssertEqual(network.count("/auth/refresh"), 1)
        XCTAssertNotNil(try? keychain.load(.authToken))
        XCTAssertEqual(session.route, .feed)
    }

    /// The offline route comes from the cache alone: no call that would only
    /// wait for a connection that is not there.
    func testAnOfflineLaunchRoutesTheWallFromTheCacheWithoutAnotherCall() async {
        let network = ScriptedNetwork { _ in throw APIError.transport("offline") }
        let (session, _, _) = await make(network, stored: AuthFixtures.pair(status: .pendingReview))

        await session.restore()

        XCTAssertEqual(session.route, .verificationWall(.pendingReview))
        XCTAssertEqual(network.count("/verification/status"), 0)
    }

    /// A suspended account: the server answered, and not about the token.
    /// The session stays; the suspension screen takes it from there.
    func testASuspensionAtLaunchKeepsTheSessionWithoutCallingItOffline() async {
        let network = ScriptedNetwork { _ in
            throw APIError.api(code: .accountSuspended, message: "This account has been suspended.", status: 403)
        }
        let (session, _, keychain) = await make(network)

        await session.restore()

        XCTAssertNotNil(try? keychain.load(.authToken))
        XCTAssertNotEqual(session.route, .unauthenticated)
        XCTAssertFalse(session.isOffline, "the server answered; it is not offline")
    }

    // MARK: - Refused

    func testRestoreAfterA401SignsOut() async {
        let network = ScriptedNetwork { _ in throw AuthFixtures.refused }
        let (session, _, keychain) = await make(network)

        await session.restore()

        XCTAssertEqual(session.route, .unauthenticated)
        XCTAssertNil(session.user)
        XCTAssertNil(try? keychain.load(.authToken), "a refused session must not leave a token behind")
        XCTAssertFalse(session.isOffline)
    }

    func testARefusedRefreshAtLaunchSignsOut() async {
        let network = ScriptedNetwork { _ in throw AuthFixtures.refused }
        let (session, _, keychain) = await make(network, stored: AuthFixtures.pair(expiresIn: 10))

        await session.restore()

        XCTAssertEqual(session.route, .unauthenticated)
        XCTAssertNil(try? keychain.load(.authToken))
    }

    // MARK: - Catching up

    func testAnOfflineLaunchCatchesUpWhenTheServerAnswers() async {
        let online = OnlineSwitch()
        let network = ScriptedNetwork { request in
            guard online.isOn else { throw APIError.transport("offline") }
            guard request.path == "/auth/me" else { throw APIError.http(status: 404, message: "") }
            return AuthFixtures.userJSON(status: "verified")
        }
        let (session, _, _) = await make(network)

        await session.restore()
        XCTAssertTrue(session.isOffline)

        online.isOn = true
        let caughtUp = await eventually { !session.isOffline }

        XCTAssertTrue(caughtUp, "the session never reached the server again")
        XCTAssertEqual(session.route, .feed)
        XCTAssertGreaterThanOrEqual(network.count("/auth/me"), 2)
    }

    func testAnOfflineLaunchThatIsRefusedOnceOnlineSignsOut() async {
        let online = OnlineSwitch()
        let network = ScriptedNetwork { _ in
            guard online.isOn else { throw APIError.transport("offline") }
            throw AuthFixtures.refused
        }
        let (session, _, keychain) = await make(network)

        await session.restore()
        XCTAssertEqual(session.route, .feed)

        online.isOn = true
        let signedOut = await eventually { session.route == .unauthenticated }

        XCTAssertTrue(signedOut)
        XCTAssertNil(try? keychain.load(.authToken))
        XCTAssertFalse(session.isOffline)
    }

    /// Back in the foreground after the network returned: the session tries
    /// at once, not at the end of a wait that can be a minute long.
    func testComingBackToTheForegroundTriesAtOnce() async {
        let online = OnlineSwitch()
        let network = ScriptedNetwork { request in
            guard online.isOn else { throw APIError.transport("offline") }
            guard request.path == "/auth/me" else { throw APIError.http(status: 404, message: "") }
            return AuthFixtures.userJSON(status: "verified")
        }
        // A wait no test would sit through.
        let (session, _, _) = await make(network, reconnectDelay: { _ in try? await Task.sleep(nanoseconds: 600_000_000_000) })

        await session.restore()
        XCTAssertTrue(session.isOffline)

        online.isOn = true
        session.retryIfOffline()
        let caughtUp = await eventually { !session.isOffline }

        XCTAssertTrue(caughtUp, "the foreground did not try the server again")
        XCTAssertEqual(session.route, .feed)
    }

    func testRetryingWhileOnlineDoesNothing() async {
        let network = ScriptedNetwork { request in
            request.path == "/auth/me" ? AuthFixtures.userJSON(status: "verified") : "{}"
        }
        let (session, _, _) = await make(network)
        await session.restore()
        let calls = network.count("/auth/me")

        session.retryIfOffline()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(session.isOffline)
        XCTAssertEqual(network.count("/auth/me"), calls)
    }

    func testSigningOutStopsTheTrying() async throws {
        let network = ScriptedNetwork { _ in throw APIError.transport("offline") }
        let (session, _, _) = await make(network)
        await session.restore()

        await session.signOut()
        let triesAtSignOut = network.count("/auth/me")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(session.isOffline)
        XCTAssertEqual(session.route, .unauthenticated)
        XCTAssertEqual(network.count("/auth/me"), triesAtSignOut, "still calling /auth/me after sign-out")
    }

    // MARK: - The classification

    func testOnlyARefusalOfTheCredentialsEndsASession() {
        XCTAssertEqual(SessionCheckFailure(APIError.unauthenticated), .refused)
        XCTAssertEqual(SessionCheckFailure(AuthFixtures.refused), .refused)

        XCTAssertEqual(SessionCheckFailure(APIError.transport("offline")), .unreachable)
        XCTAssertEqual(SessionCheckFailure(APIError.cancelled), .unreachable)
        XCTAssertEqual(SessionCheckFailure(CancellationError()), .unreachable)
        XCTAssertEqual(SessionCheckFailure(APIError.decoding("html")), .unreachable)
        XCTAssertEqual(SessionCheckFailure(APIError.http(status: 502, message: "")), .unreachable)
        XCTAssertEqual(SessionCheckFailure(APIError.http(status: 503, message: "")), .unreachable)
        XCTAssertEqual(SessionCheckFailure(APIError.api(code: .rateLimited, message: "", status: 429)), .unreachable)
        // Something in front of the API answered — a proxy's or a
        // firewall's page — not the API, and not about this session.
        XCTAssertEqual(SessionCheckFailure(APIError.http(status: 403, message: "<html>Access denied</html>")), .unreachable)
        XCTAssertEqual(SessionCheckFailure(APIError.http(status: 404, message: "<html>Not Found</html>")), .unreachable)

        XCTAssertEqual(SessionCheckFailure(APIError.api(code: .accountSuspended, message: "", status: 403)), .declined)
        XCTAssertEqual(SessionCheckFailure(APIError.api(code: .accountDeactivated, message: "", status: 403)), .declined)
    }
}

/// A flag a test flips while a session is trying to reach the server.
final class OnlineSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
