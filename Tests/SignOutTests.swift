import XCTest
@testable import Sila

/// Signing out ends the session on the server as well as on the phone, even
/// when the access token can no longer say which session that is (contract
/// v26 §1): the refresh token goes in the body.
///
/// And it does not wait for a connection. Offline, a request waits up to
/// forty-five seconds for one (``AppConfig/connectivityWait``) before it
/// fails, and sign-out used to wait with it — twice, when the phone also had a
/// push registration to withdraw. Each call now gets a few seconds
/// (``AppConfig/signOutDeadline``) and is then abandoned; the phone signs out
/// regardless.
final class SignOutTests: XCTestCase {

    /// A deadline no test waits long for.
    private static let shortDeadline: @Sendable () async -> Void = {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func make(
        _ network: NetworkClient,
        stored: TokenPair = AuthFixtures.pair(),
        signOutDeadline: (@Sendable () async -> Void)? = nil
    ) async -> (AuthService, AuthTokenStore, InMemoryKeychainClient) {
        let keychain = InMemoryKeychainClient()
        let store = AuthTokenStore(keychain: keychain, storage: InMemoryStorageClient(), leftovers: .isolated())
        await store.store(stored)
        let service: AuthService
        if let signOutDeadline {
            service = AuthService(
                network: network,
                store: store,
                biometrics: StubBiometricAuthenticator(),
                analytics: RecordingAnalyticsClient(),
                signOutDeadline: signOutDeadline
            )
        } else {
            service = AuthService(
                network: network,
                store: store,
                biometrics: StubBiometricAuthenticator(),
                analytics: RecordingAnalyticsClient()
            )
        }
        return (service, store, keychain)
    }

    /// A transport that never answers, as URLSession does not while it waits
    /// for a connection that is not coming — until the request is abandoned,
    /// which it notes.
    private func unansweredNetwork(_ abandoned: Flag) -> ScriptedNetwork {
        ScriptedNetwork { _ in
            do {
                try await Task.sleep(nanoseconds: 600_000_000_000)
            } catch {
                abandoned.raise()
            }
            throw APIError.cancelled
        }
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

    // MARK: - Offline, it does not wait

    /// Offline, `/auth/logout` never answers. At the deadline it is abandoned
    /// and the phone is signed out.
    func testAnUnansweredLogoutIsAbandonedAtTheDeadlineAndThePhoneSignsOut() async throws {
        let abandoned = Flag()
        let network = unansweredNetwork(abandoned)
        let (service, store, keychain) = await make(network, signOutDeadline: Self.shortDeadline)

        let started = Date()
        try await service.signOut()

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "sign-out waited for the network")
        XCTAssertEqual(network.count("/auth/logout"), 1, "the server was still asked")
        let token = await store.token()
        XCTAssertNil(token, "the session outlived an unanswered logout")
        XCTAssertNil(try keychain.load(.authToken))
        let wasAbandoned = await eventually { abandoned.isRaised }
        XCTAssertTrue(wasAbandoned, "the request was left waiting for a connection")
    }

    /// With nothing injected, the wait is ``AppConfig/signOutDeadline`` — a
    /// few seconds, nowhere near the forty-five an offline request waits.
    func testByDefaultSignOutWaitsAFewSecondsNotForty() async throws {
        XCTAssertLessThanOrEqual(AppConfig.signOutDeadline, 5)
        XCTAssertLessThan(AppConfig.signOutDeadline, AppConfig.connectivityWait)
        let network = unansweredNetwork(Flag())
        let (service, store, _) = await make(network)

        let started = Date()
        try await service.signOut()
        let waited = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(
            waited, AppConfig.signOutDeadline - 0.5, "gave up before the server had its seconds"
        )
        XCTAssertLessThan(waited, AppConfig.signOutDeadline + 3, "waited \(waited) s")
        let token = await store.token()
        XCTAssertNil(token)
    }

    /// The deadline only ever shortens a sign-out: an answer inside it is
    /// waited for, and the request is not abandoned.
    func testALogoutAnsweredInTimeIsWaitedFor() async throws {
        let answered = Flag()
        let network = ScriptedNetwork { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            answered.raise()
            return ""
        }
        let (service, store, _) = await make(
            network, signOutDeadline: { try? await Task.sleep(nanoseconds: 600_000_000_000) }
        )

        try await service.signOut()

        XCTAssertTrue(answered.isRaised, "the phone signed out before the server answered")
        let token = await store.token()
        XCTAssertNil(token)
    }

    /// The real transport, as the app configures it: abandoning the logout
    /// cancels the URLSession task, so nothing is left waiting for a
    /// connection after the phone has signed out.
    func testTheAbandonedLogoutIsCancelledInTheTransport() async throws {
        SilentURLProtocol.reset()
        let configuration = URLSessionNetworkClient.makeConfiguration()
        configuration.protocolClasses = [SilentURLProtocol.self]
        let client = URLSessionNetworkClient(
            baseURL: URL(string: "https://sila.invalid/api/v1")!,
            session: URLSession(configuration: configuration)
        )
        // The deadline passes once the request is on the wire, so what is
        // abandoned is a request URLSession holds, not one it never began.
        let (service, store, _) = await make(client, signOutDeadline: {
            let giveUp = Date().addingTimeInterval(2)
            while !SilentURLProtocol.started, Date() < giveUp {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        })

        let started = Date()
        try await service.signOut()

        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "sign-out waited for the network")
        let token = await store.token()
        XCTAssertNil(token)
        let wentOut = await eventually { SilentURLProtocol.started }
        XCTAssertTrue(wentOut, "the logout never went out")
        let wasCancelled = await eventually { SilentURLProtocol.stopped }
        XCTAssertTrue(wasCancelled, "the logout was left waiting in URLSession")
    }

    /// The whole sign-out, offline, with a push registration to withdraw: two
    /// calls, each abandoned at its deadline, and the welcome screen.
    @MainActor
    func testAnOfflineSignOutWithAPushRegistrationEndsInSeconds() async throws {
        let network = unansweredNetwork(Flag())
        let (service, store, keychain) = await make(network, signOutDeadline: Self.shortDeadline)
        let session = AuthSession(service: service, store: store, analytics: RecordingAnalyticsClient())
        await session.adopt(AuthFixtures.pair())
        XCTAssertEqual(session.route, .feed)

        let push = UnansweredPushService()
        let storage = InMemoryStorageClient()
        storage.set("ab01", for: PushRegistrar.tokenKey)
        let registrar = PushRegistrar(
            service: push, storage: storage, analytics: RecordingAnalyticsClient(),
            isSignedIn: { true }, center: nil, signOutDeadline: Self.shortDeadline
        )
        session.willSignOut = { await registrar.willSignOut() }

        let started = Date()
        await session.signOut()

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "sign-out waited for the network")
        XCTAssertEqual(session.route, .unauthenticated)
        XCTAssertNil(session.user)
        XCTAssertNil(try keychain.load(.authToken))
        XCTAssertEqual(push.asked, ["ab01"], "the push registration was still withdrawn first")
        XCTAssertEqual(network.count("/auth/logout"), 1, "the server was still told")
        let withdrawalAbandoned = await eventually { push.abandoned }
        XCTAssertTrue(withdrawalAbandoned, "the withdrawal was left waiting for a connection")
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@MainActor
final class PushWithdrawalDeadlineTests: XCTestCase {

    /// Offline, withdrawing the push registration never answers either; it is
    /// abandoned at the deadline rather than holding sign-out for forty-five
    /// seconds.
    func testAnUnansweredWithdrawalIsAbandonedAtTheDeadline() async {
        let push = UnansweredPushService()
        let storage = InMemoryStorageClient()
        storage.set("ab01", for: PushRegistrar.tokenKey)
        let registrar = PushRegistrar(
            service: push, storage: storage, analytics: RecordingAnalyticsClient(),
            isSignedIn: { true }, center: nil,
            signOutDeadline: { try? await Task.sleep(nanoseconds: 50_000_000) }
        )

        let started = Date()
        await registrar.willSignOut()

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "sign-out waited for the network")
        XCTAssertEqual(push.asked, ["ab01"])
        let deadline = Date().addingTimeInterval(3)
        while !push.abandoned, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(push.abandoned, "the withdrawal was left waiting for a connection")
    }

    /// A phone that never registered for pushes has nothing to withdraw and
    /// does not wait at all.
    func testNoRegistrationMeansNoWait() async {
        let push = UnansweredPushService()
        let registrar = PushRegistrar(
            service: push, storage: InMemoryStorageClient(), analytics: RecordingAnalyticsClient(),
            isSignedIn: { true }, center: nil,
            signOutDeadline: { try? await Task.sleep(nanoseconds: 600_000_000_000) }
        )

        await registrar.willSignOut()

        XCTAssertTrue(push.asked.isEmpty)
    }
}

/// A thread-safe latch a test can raise from any task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isRaised: Bool { lock.withLock { value } }
    func raise() { lock.withLock { value = true } }
}

/// A push service whose withdrawal never answers, as offline, until it is
/// abandoned.
private final class UnansweredPushService: PushServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    private var wasAbandoned = false
    var asked: [String] { lock.withLock { tokens } }
    var abandoned: Bool { lock.withLock { wasAbandoned } }

    func register(token: String, environment: String) async throws {}

    func unregister(token: String) async throws {
        lock.withLock { tokens.append(token) }
        do {
            try await Task.sleep(nanoseconds: 600_000_000_000)
        } catch {
            lock.withLock { wasAbandoned = true }
        }
        throw APIError.cancelled
    }

    func markOpened(pushId: String) async throws {}
}

/// A server that takes every request and never answers, and notes when
/// URLSession gives up on one.
private final class SilentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var didStart = false
    private static var didStop = false
    static var started: Bool { lock.withLock { didStart } }
    static var stopped: Bool { lock.withLock { didStop } }

    static func reset() {
        lock.withLock {
            didStart = false
            didStop = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.didStart = true }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.didStop = true }
    }
}
