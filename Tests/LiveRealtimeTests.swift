import XCTest
@testable import Sila

/// Contract v30 against the staging backend, through the app's own socket,
/// decoders and view models: two people talking live — the message as the
/// thread shows it, the sender's other device hearing it quietly, typing,
/// the read receipt, a deletion — a notification with its badge, and a
/// third account at the wall hearing its own verification land and routing
/// to the feed on it.
///
/// **Opt-in, staging only, disposable accounts only.** Three
/// `itest-ios-rt…@example.com` accounts are registered through the staging
/// API's dev routes; nobody else's account or thread is read or written, and
/// production — which runs with dev mode off — is never called. The socket
/// goes to the same tunnel as the HTTP calls:
///
/// ```
/// ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
///   xcodebuild … test -only-testing:SilaTests/LiveRealtimeTests
/// ```
@MainActor
final class LiveRealtimeTests: XCTestCase {

    private let password = "Passw0rd!234"
    private var sockets: [LiveSocket] = []

    override func setUpWithError() throws {
        _ = try LiveTarget.api()
    }

    override func tearDown() async throws {
        for socket in sockets { socket.client.stop() }
        sockets = []
        try await super.tearDown()
    }

    // MARK: - Accounts

    private struct Person {
        let email: String
        let handle: String
        let id: UUID
        let pair: TokenPair
        let auth: AuthService
        let store: AuthTokenStore
        let messages: MessagesService
        let notifications: NotificationsService
        let profile: ProfileService
    }

    /// Registers, confirms the code the dev route shows, and — unless it is
    /// to wait at the wall — makes the account verified in Saudi Arabia.
    private func person(_ tag: String, verified: Bool = true) async throws -> Person {
        let email = "itest-ios-rt\(tag)\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let store = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient())
        let auth = AuthService(
            network: LiveTarget.network(),
            store: store,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await auth.register(email: email, password: password)
        let peek = try await LiveTarget.dev("otp/peek", query: [URLQueryItem(name: "email", value: email)])
        let code = try XCTUnwrap(peek["code"] as? String, "no code recorded for \(email)")
        let pair = try await auth.verifyOTP(email: email, code: code, purpose: .register)
        if verified {
            _ = try await LiveTarget.dev("user/set", body: [
                "email": email, "verification_status": "verified", "country_code": "SA",
            ])
        }
        let me = try await auth.currentUser()
        let tokens = StaticAccessTokenProvider(token: pair.token.accessToken)
        return Person(
            email: email,
            handle: try XCTUnwrap(me.handle),
            id: me.id,
            pair: pair,
            auth: auth,
            store: store,
            messages: MessagesService(network: LiveTarget.network(), tokens: tokens, analytics: RecordingAnalyticsClient()),
            notifications: NotificationsService(network: LiveTarget.network(), tokens: tokens, analytics: RecordingAnalyticsClient()),
            profile: ProfileService(network: LiveTarget.network(), tokens: tokens, analytics: RecordingAnalyticsClient())
        )
    }

    /// The app's own client, on the real transport, to staging's socket.
    private func connect(_ person: Person) async throws -> LiveSocket {
        let url = AppConfig.realtimeURL(for: try LiveTarget.api())
        XCTAssertEqual(url.scheme, "ws", "staging through the tunnel")
        let client = RealtimeClient(
            url: url,
            sockets: URLSessionRealtimeSocketFactory(),
            tokens: FixedRealtimeTokens(token: person.pair.token.accessToken)
        )
        let socket = LiveSocket(client: client)
        sockets.append(socket)
        client.start(accountId: person.id)
        let ready = try await socket.next("ready", within: 15) { event in
            if case let .ready(ready) = event { return ready }
            return nil
        }
        XCTAssertEqual(ready.userId, person.id)
        return socket
    }

    // MARK: - Two people, live

    func testTwoPeopleTalkLive() async throws {
        let a = try await person("a")
        let b = try await person("b")
        // Following each other, so the thread is accepted from the first message.
        _ = try await a.profile.setFollowing(true, handle: b.handle)
        _ = try await b.profile.setFollowing(true, handle: a.handle)

        let toA = try await connect(a)
        let toB = try await connect(b)
        XCTAssertEqual(toB.client.ready?.standing, "verified")
        XCTAssertEqual(toB.client.ready?.events.sorted(),
                       ["account.status", "message.deleted", "message.new", "message.read", "notification.new", "typing"])

        // A message, as the thread shows it.
        let conversationId = try await a.messages.send(to: b.handle, text: "hello, live from iOS")
        let arrived = try await toB.next("message.new", within: 10) { event in
            if case let .messageNew(new) = event, new.conversationId == conversationId { return new }
            return nil
        }
        XCTAssertEqual(arrived.message.text, "hello, live from iOS")
        XCTAssertEqual(arrived.message.sender.handle, a.handle)
        XCTAssertEqual(arrived.conversation, .init(id: conversationId, accepted: true, isRequest: false))
        XCTAssertTrue(arrived.alert, "a friend's message is one a push would go for")
        let thread = try await b.messages.fetchMessages(conversationId: conversationId)
        XCTAssertEqual(thread.last, arrived.message, "exactly what the thread returns")

        // The sender's other device hears it too, without a banner.
        let own = try await toA.next("message.new", within: 10) { event in
            if case let .messageNew(new) = event, new.message.id == arrived.message.id { return new }
            return nil
        }
        XCTAssertFalse(own.alert)

        // B's open thread takes the next one without a reload.
        let board = TypingBoard()
        let inbox = try await b.messages.fetchConversations()
        let chat = ChatViewModel(
            conversation: try XCTUnwrap(inbox.first { $0.id == conversationId }),
            viewerId: b.id,
            service: b.messages,
            realtime: toB.client,
            typing: board
        )
        await chat.load()
        await chat.screenAppeared()
        let listening = Task { await chat.listen() }
        defer { listening.cancel() }
        let routing = Task { @MainActor in
            for await event in toB.client.events() {
                switch event {
                case let .typing(typing): board.apply(typing)
                case let .messageNew(new): board.messageArrived(conversationId: new.conversationId, from: new.message.sender.id)
                default: break
                }
            }
        }
        defer { routing.cancel() }

        // Typing, from A's socket to B's thread.
        XCTAssertTrue(toA.client.sendTyping(conversationId: conversationId, active: true))
        let typing = try await toB.next("typing", within: 10) { event in
            if case let .typing(typing) = event, typing.conversationId == conversationId { return typing }
            return nil
        }
        XCTAssertEqual(typing.userId, a.id)
        XCTAssertTrue(typing.active)
        XCTAssertEqual(typing.expiresIn, 6)
        try await waitUntil("B's thread never said typing…") { chat.isOtherTyping }
        let asked = try await b.messages.fetchTyping(conversationId: conversationId)
        XCTAssertTrue(asked.typing, "GET …/typing agrees while it lasts")

        // Her message ends the typing and lands in the open thread.
        try await a.messages.send(to: b.handle, text: "second, live")
        try await waitUntil("the open thread never took the message") {
            chat.messages.last?.text == "second, live"
        }
        try await waitUntil("typing outlived the message") { !chat.isOtherTyping }

        // The open thread read it: A hears the receipt.
        let receipt = try await toA.next("message.read", within: 10) { event in
            if case let .messageRead(read) = event, read.conversationId == conversationId, read.readerId == b.id { return read }
            return nil
        }
        XCTAssertNotNil(receipt)

        // A deletes the second message: B's thread shows it gone.
        let second = try XCTUnwrap(chat.messages.last)
        try await a.messages.deleteMessage(id: second.id)
        try await waitUntil("the deletion never reached B's thread") {
            chat.messages.first { $0.id == second.id }?.deleted == true
        }
    }

    // MARK: - The badge and the wall

    func testTheWallHearsItsVerificationAndTheBadgeHearsTheFollow() async throws {
        let b = try await person("n")
        let waiting = try await person("w", verified: false)

        let toWall = try await connect(waiting)
        XCTAssertEqual(toWall.client.ready?.standing, "none")
        XCTAssertEqual(toWall.client.ready?.events, ["account.status"], "the wall hears one thing")

        // The session at the wall, as the app holds it.
        let session = AuthSession(service: waiting.auth, store: waiting.store, analytics: RecordingAnalyticsClient())
        await session.adopt(waiting.pair)
        guard case .verificationWall = session.route else { return XCTFail("not at the wall: \(session.route)") }

        _ = try await LiveTarget.dev("user/set", body: [
            "email": waiting.email, "verification_status": "verified", "country_code": "SA",
        ])
        let me = try await toWall.next("account.status (verified)", within: 15) { event in
            if case let .accountStatus(me) = event, me.verificationStatus == .verified { return me }
            return nil
        }
        XCTAssertEqual(me.id, waiting.id)
        XCTAssertEqual(me.standing, .verified)
        await session.adoptAccount(me)
        XCTAssertEqual(session.route, .feed, "the wall moved the moment the decision landed")

        // Verified now: it follows B, and B's badge is the server's count.
        let toB = try await connect(b)
        _ = try await waiting.profile.setFollowing(true, handle: b.handle)
        let note = try await toB.next("notification.new", within: 10) { event in
            if case let .notificationNew(note) = event, note.kind == "follow" { return note }
            return nil
        }
        let count = try await b.notifications.fetchUnreadCount()
        XCTAssertEqual(note.unreadCount, count)
        let badge = NotificationsViewModel(
            service: b.notifications,
            feed: FeedServiceMock(scenario: .empty),
            analytics: RecordingAnalyticsClient()
        )
        await badge.apply(.notificationNew(note))
        XCTAssertEqual(badge.unreadCount, count)
    }

    // MARK: - The door, on the real transport

    /// A bad token is refused with the HTTP API's code, and the adapter reads
    /// the server's own close code — 4401, which no standard enum names.
    func testABadTokenIsRefusedWithTheHTTPCodeAndClose4401() async throws {
        let socket = URLSessionRealtimeSocket(url: AppConfig.realtimeURL(for: try LiveTarget.api()))
        defer { socket.close(code: 1000) }
        socket.open()
        try await socket.send(RealtimeOutgoing.auth(token: "not-a-token"))
        var code: String?
        do {
            while true {
                let text = try await socket.receive()
                if case let .error(errorCode, _, _)? = RealtimeFrame.parse(text) { code = errorCode }
            }
        } catch let closed as RealtimeSocketClosed {
            XCTAssertEqual(code, "unauthorized")
            XCTAssertEqual(closed.code, 4401)
            XCTAssertEqual(RealtimeCloseDecision.decide(errorCode: code, closeCode: closed.code), .renewToken)
        }
    }

    // MARK: - Helpers

    private func waitUntil(_ message: String, within seconds: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(condition(), message)
        if !condition() { throw LiveTargetError(message) }
    }
}

/// One socket and everything it heard, so a test can wait for an event that
/// may already have arrived.
@MainActor
private final class LiveSocket {
    let client: RealtimeClient
    private(set) var heard: [RealtimeEvent] = []
    private var task: Task<Void, Never>?

    init(client: RealtimeClient) {
        self.client = client
        let stream = client.events()
        task = Task { @MainActor [weak self] in
            for await event in stream { self?.heard.append(event) }
        }
    }

    deinit { task?.cancel() }

    /// The first event `match` accepts, waiting up to `within` seconds.
    func next<T>(_ what: String, within seconds: TimeInterval, _ match: (RealtimeEvent) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = heard.lazy.compactMap(match).first { return found }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let found = heard.lazy.compactMap(match).first { return found }
        throw LiveTargetError("no \(what) within \(Int(seconds)) s; heard \(heard.count) events, state \(client.state)")
    }
}

/// A token the test already holds.
private struct FixedRealtimeTokens: RealtimeTokenProviding {
    let token: String
    func accessToken() async throws -> String { token }
    func renewedAccessToken(replacing stale: String) async throws -> String { token }
}
