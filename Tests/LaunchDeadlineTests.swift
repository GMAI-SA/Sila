import XCTest
@testable import Sila

/// A cold launch with a stored session waits a few seconds for the server,
/// not the forty-five the client waits for a connection.
///
/// Offline, a request does not fail at once: URLSession waits for the network
/// to come back (``AppConfig/connectivityWait``), and the splash used to wait
/// with it. Now the app opens on the cached account at the launch deadline,
/// with the offline strip, and the check already asked goes on in the
/// background; its answer is acted on when it comes.
@MainActor
final class LaunchDeadlineTests: XCTestCase {

    /// A deadline no test waits long for.
    private static let shortDeadline: @Sendable () async -> Void = {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// A deadline no test would ever reach.
    private static let farDeadline: @Sendable () async -> Void = {
        try? await Task.sleep(nanoseconds: 600_000_000_000)
    }

    private func make(
        _ network: ScriptedNetwork,
        stored: TokenPair? = AuthFixtures.pair(),
        launchDeadline: @escaping @Sendable () async -> Void = LaunchDeadlineTests.shortDeadline,
        reconnectDelay: @escaping @Sendable (Int) async -> Void = { _ in try? await Task.sleep(nanoseconds: 600_000_000_000) }
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
            reconnectDelay: reconnectDelay,
            launchDeadline: launchDeadline
        )
        return (session, store, keychain)
    }

    /// A transport that holds every request until the test lets it through,
    /// as URLSession holds one while it waits for a connection.
    private func waitingNetwork(
        _ gate: OnlineSwitch,
        answer: @escaping @Sendable (APIRequest) throws -> String
    ) -> ScriptedNetwork {
        ScriptedNetwork { request in
            while !gate.isOn { try? await Task.sleep(nanoseconds: 10_000_000) }
            return try answer(request)
        }
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - Opening at the deadline

    func testAStalledLaunchOpensOnTheCachedAccountAtTheDeadline() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let network = waitingNetwork(gate) { _ in throw APIError.transport("The request timed out.") }
        let (session, _, keychain) = await make(network)

        let started = Date()
        await session.restore()

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the launch waited for the network")
        XCTAssertEqual(session.route, .feed, "opened on the account cached in the keychain")
        XCTAssertEqual(session.user?.email, "aziz@example.com")
        XCTAssertTrue(session.isOffline, "the strip says the server has not answered")
        XCTAssertNotNil(try? keychain.load(.authToken), "the session is kept")
        XCTAssertEqual(network.count("/auth/me"), 1, "the one check is still out; nothing asked twice")
    }

    /// The deadline only ever shortens a launch: an answer inside it routes
    /// at once, with no strip.
    func testAnAnswerInsideTheDeadlineRoutesAtOnce() async {
        let network = ScriptedNetwork { request in
            request.path == "/auth/me" ? AuthFixtures.userJSON(status: "pending_review") : #"{"status": "pending_review"}"#
        }
        let (session, _, _) = await make(network, launchDeadline: Self.farDeadline)

        let started = Date()
        await session.restore()

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "an answered launch waited for the deadline")
        XCTAssertFalse(session.isOffline)
        XCTAssertEqual(session.route, .verificationWall(.pendingReview), "routed on the server's answer, not the cache")
    }

    /// A refusal inside the deadline still signs out at once.
    func testARefusalInsideTheDeadlineSignsOut() async {
        let network = ScriptedNetwork { _ in throw AuthFixtures.refused }
        let (session, _, keychain) = await make(network, launchDeadline: Self.farDeadline)

        await session.restore()

        XCTAssertEqual(session.route, .unauthenticated)
        XCTAssertNil(try? keychain.load(.authToken))
    }

    // MARK: - The check goes on

    func testTheCheckStillOutCatchesUpWhenItIsAnswered() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let network = waitingNetwork(gate) { request in
            guard request.path == "/auth/me" else { throw APIError.http(status: 404, message: "") }
            return AuthFixtures.userJSON(status: "verified")
        }
        let (session, _, _) = await make(network)
        await session.restore()
        XCTAssertTrue(session.isOffline)

        gate.isOn = true
        let caughtUp = await eventually { !session.isOffline }

        XCTAssertTrue(caughtUp, "the launch's own check was never acted on")
        XCTAssertEqual(session.route, .feed)
        XCTAssertEqual(network.count("/auth/me"), 1, "caught up on the first answer, not a retry")
    }

    /// The server changed its mind while the phone was offline: the check's
    /// answer re-routes, exactly as a reconnect's does.
    func testTheCheckStillOutRoutesOnWhatTheServerSays() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let network = waitingNetwork(gate) { request in
            request.path == "/auth/me" ? AuthFixtures.userJSON(status: "pending_review") : #"{"status": "pending_review"}"#
        }
        let (session, _, _) = await make(network)
        await session.restore()
        XCTAssertEqual(session.route, .feed, "the cache said verified")

        gate.isOn = true
        let rerouted = await eventually { session.route == .verificationWall(.pendingReview) }

        XCTAssertTrue(rerouted, "still showing the cached route after the server answered")
        XCTAssertFalse(session.isOffline)
    }

    func testARefusalThatArrivesAfterTheDeadlineSignsOut() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let network = waitingNetwork(gate) { _ in throw AuthFixtures.refused }
        let (session, _, keychain) = await make(network)
        await session.restore()
        XCTAssertEqual(session.route, .feed)

        gate.isOn = true
        let signedOut = await eventually { session.route == .unauthenticated }

        XCTAssertTrue(signedOut)
        XCTAssertNil(try? keychain.load(.authToken))
        XCTAssertFalse(session.isOffline)
    }

    /// The check gives up offline too, after the client's own wait; the
    /// usual retries take over from there.
    func testACheckThatCannotReachTheServerEitherIsFollowedByTheRetries() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let calls = RequestTally()
        let network = ScriptedNetwork { request in
            if calls.next() == 1 {
                while !gate.isOn { try? await Task.sleep(nanoseconds: 10_000_000) }
                throw APIError.transport("The request timed out.")
            }
            guard request.path == "/auth/me" else { throw APIError.http(status: 404, message: "") }
            return AuthFixtures.userJSON(status: "verified")
        }
        let (session, _, _) = await make(network, reconnectDelay: { _ in try? await Task.sleep(nanoseconds: 20_000_000) })
        await session.restore()
        XCTAssertTrue(session.isOffline)

        gate.isOn = true
        let caughtUp = await eventually { !session.isOffline }

        XCTAssertTrue(caughtUp, "no retry followed the check that timed out")
        XCTAssertEqual(network.count("/auth/me"), 2)
    }

    /// Signed in afresh while the launch's check was out: its late refusal
    /// is about the old session, and must not end the new one.
    func testALateAnswerForASessionThatWasReplacedIsIgnored() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let network = waitingNetwork(gate) { _ in throw AuthFixtures.refused }
        let (session, _, _) = await make(network)
        await session.restore()

        await session.adopt(AuthFixtures.pair(access: "access-new", refresh: "refresh-new"))
        gate.isOn = true
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(session.route, .feed, "the new session was signed out by the old one's answer")
        XCTAssertNotNil(session.user)
    }

    func testComingBackToTheForegroundDoesNotWaitForTheCheckStillOut() async {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let calls = RequestTally()
        let network = ScriptedNetwork { request in
            if calls.next() == 1 {
                // The launch's check: still waiting for a connection.
                while !gate.isOn { try? await Task.sleep(nanoseconds: 10_000_000) }
                throw APIError.transport("The request timed out.")
            }
            guard request.path == "/auth/me" else { throw APIError.http(status: 404, message: "") }
            return AuthFixtures.userJSON(status: "verified")
        }
        let (session, _, _) = await make(network)
        await session.restore()
        XCTAssertTrue(session.isOffline)

        session.retryIfOffline()
        let caughtUp = await eventually { !session.isOffline }

        XCTAssertTrue(caughtUp, "the foreground waited for the launch's check")
        XCTAssertEqual(session.route, .feed)
    }

    // MARK: - Nothing to open on

    /// With a token but no cached account there is nothing to open on, and
    /// the launch waits for the server as it always did.
    func testWithNoCachedAccountTheLaunchWaitsForTheServer() async throws {
        let gate = OnlineSwitch()
        defer { gate.isOn = true }
        let network = waitingNetwork(gate) { _ in AuthFixtures.userJSON(status: "verified") }
        // A token and no account, on an install that is not new.
        let keychain = InMemoryKeychainClient()
        try keychain.save(AuthFixtures.pair().token, for: .authToken)
        let storage = InMemoryStorageClient()
        storage.setFlag(true, for: .installed)
        let store = AuthTokenStore(keychain: keychain, storage: storage, leftovers: .isolated())
        let session = AuthSession(
            service: AuthService(network: network, store: store, biometrics: StubBiometricAuthenticator(), analytics: RecordingAnalyticsClient()),
            store: store,
            analytics: RecordingAnalyticsClient(),
            launchDeadline: Self.shortDeadline
        )

        let launch = Task { await session.restore() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.route, .splash, "opened on nothing at the deadline")

        gate.isOn = true
        await launch.value
        XCTAssertEqual(session.route, .feed)
        XCTAssertFalse(session.isOffline)
    }

    // MARK: - A late answer after sign-out

    /// `/auth/me` still out at sign-out — a launch's check can wait most of a
    /// minute — must not write the account back into the emptied keychain.
    func testAnAccountThatArrivesAfterSignOutIsNotWrittenBack() async throws {
        let (_, store, keychain) = await make(ScriptedNetwork { _ in "" })
        await store.clear()

        await store.updateUser(AuthFixtures.pair().user)

        let user = await store.user()
        XCTAssertNil(user)
        XCTAssertNil(try keychain.load(.cachedUser))
    }
}

/// Counts calls from any thread.
private final class RequestTally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// The number of this call, from 1.
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
