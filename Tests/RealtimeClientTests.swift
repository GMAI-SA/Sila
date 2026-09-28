import XCTest
@testable import Sila

/// The socket's protocol (contract v30), against a socket that is a queue of
/// strings: the token as the first frame and nowhere else, the heartbeat,
/// re-authentication, and what every close makes the client do next.
@MainActor
final class RealtimeClientTests: XCTestCase {

    private let url = URL(string: "wss://sila.gmai.sa/api/v1/realtime")!
    private var clients: [RealtimeClient] = []

    override func tearDown() async throws {
        for client in clients { client.stop() }
        clients = []
        try await super.tearDown()
    }

    private func makeClient(
        sockets: ScriptedSockets,
        tokens: CountingRealtimeTokens = CountingRealtimeTokens(),
        waits: RecordedWaits = RecordedWaits(),
        suspension: SuspensionReporting? = nil,
        onSessionRefused: (@MainActor (Error) async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        silenceLimit: TimeInterval = 80,
        refreshPause: TimeInterval = 0
    ) -> RealtimeClient {
        let client = RealtimeClient(
            url: url,
            sockets: sockets,
            tokens: tokens,
            suspension: suspension,
            onSessionRefused: onSessionRefused,
            sleep: { delay in
                await waits.record(delay)
                try await Task.sleep(nanoseconds: 20_000_000)
            },
            // The middle of the jitter: every wait exactly its step.
            jitter: { 0.5 },
            refreshPause: { refreshPause },
            now: now,
            silenceLimit: silenceLimit
        )
        clients.append(client)
        return client
    }

    /// Collects every event a subscriber hears.
    private final class Heard {
        var events: [RealtimeEvent] = []
        var task: Task<Void, Never>?
        var readies: Int { events.filter { if case .ready = $0 { return true }; return false }.count }
        var messages: [RealtimeMessageNew] {
            events.compactMap { if case let .messageNew(new) = $0 { return new }; return nil }
        }
        func contains(_ predicate: (RealtimeEvent) -> Bool) -> Bool { events.contains(where: predicate) }
    }

    private func listen(to client: RealtimeClient) -> Heard {
        let heard = Heard()
        let stream = client.events()
        heard.task = Task { @MainActor in
            for await event in stream { heard.events.append(event) }
        }
        return heard
    }

    // MARK: - The door

    func testTheTokenIsTheFirstFrameAndTheURLCarriesNothing() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        let heard = listen(to: client)

        client.start(accountId: UserSummary.mockViewer.id)
        await eventually("never went live") { client.isLive }

        XCTAssertEqual(sockets.requestedURLs, [url], "one socket, at the plain URL")
        XCTAssertNil(URLComponents(url: sockets.requestedURLs[0], resolvingAgainstBaseURL: false)?.query,
                     "a token in the query string is logged by every hop")
        let first = frameObject(sockets.made[0].sent[0])
        XCTAssertEqual(first["type"] as? String, "auth")
        XCTAssertEqual(first["token"] as? String, "tok-1")
        XCTAssertEqual(client.state, .live(standing: "verified"))
        XCTAssertEqual(client.ready?.events.contains("typing"), true)
        await eventually("ready was not passed on") { heard.readies == 1 }
    }

    func testAPingIsAnsweredWithAPong() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].deliver(json: ["type": "ping"])
        await eventually("no pong") { sockets.made[0].sent.contains(RealtimeOutgoing.pong) }
    }

    func testEventsReachEverySubscriberAndWhatIsUnknownIsIgnored() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        let one = listen(to: client)
        let two = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }

        let socket = sockets.made[0]
        socket.deliver(json: ["type": "presence.online", "user_id": UUID().uuidString])   // a later contract's
        socket.deliver("not json at all")
        socket.deliver(json: ["no": "type"])
        socket.deliver(json: RealtimeFixtures.messageNew(text: "hello, live"))

        await eventually("the message did not reach both") { one.messages.count == 1 && two.messages.count == 1 }
        XCTAssertEqual(one.messages.first?.message.text, "hello, live")
        XCTAssertTrue(socket.isOpen, "an unknown frame never closes the socket")
        XCTAssertEqual(sockets.made.count, 1)
    }

    // MARK: - The token, judged again

    func testReauthRequiredIsAnsweredWithAFreshTokenOnTheSameSocket() async {
        let sockets = ScriptedSockets()
        let tokens = CountingRealtimeTokens()
        let client = makeClient(sockets: sockets, tokens: tokens)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].deliver(json: ["type": "reauth_required", "token_expires_at": "2026-09-28T15:15:33+00:00"])
        await eventually("no fresh token was sent") {
            sockets.made[0].sent.map(frameObject).contains { $0["type"] as? String == "auth" && $0["token"] as? String == "tok-2" }
        }
        let renewed = await tokens.renewals
        XCTAssertEqual(renewed, ["tok-1"], "the renewal names the token being replaced")
        XCTAssertEqual(sockets.made.count, 1, "re-authentication keeps the socket")
        XCTAssertTrue(client.isLive)
    }

    func testAnExpiredTokenIsRenewedAndTheSocketReopensAtOnce() async {
        let sockets = ScriptedSockets()
        let tokens = CountingRealtimeTokens()
        let waits = RecordedWaits()
        let client = makeClient(sockets: sockets, tokens: tokens, waits: waits)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].serverClose(code: 4401, errorCode: "token_expired")
        await eventually("no second socket") { sockets.made.count == 2 && client.isLive }

        let second = frameObject(sockets.made[1].sent[0])
        XCTAssertEqual(second["token"] as? String, "tok-2", "the second socket carries the renewed token")
        let renewed = await tokens.renewals
        XCTAssertEqual(renewed, ["tok-1"])
        let delays = await waits.delays
        XCTAssertTrue(delays.allSatisfy { $0 == 0 }, "a renewal reconnects at once: \(delays)")
    }

    func testARefusedSessionSignsOutAndStops() async {
        let sockets = ScriptedSockets()
        let tokens = CountingRealtimeTokens(failing: APIError.api(code: .unauthorized, message: "Sign in again", status: 401))
        var refused: Error?
        let client = makeClient(sockets: sockets, tokens: tokens, onSessionRefused: { refused = $0 })
        client.start(accountId: nil)

        await eventually("the session was not ended") { client.state == .stopped(.signedOut) }
        XCTAssertNotNil(refused)
        XCTAssertTrue(sockets.made.isEmpty, "no socket without a token")
    }

    func testNoTokenOnThePhoneStopsWithoutEndingTheSession() async {
        let sockets = ScriptedSockets()
        let tokens = CountingRealtimeTokens(failing: APIError.unauthenticated)
        var refused = false
        let client = makeClient(sockets: sockets, tokens: tokens, onSessionRefused: { _ in refused = true })
        client.start(accountId: nil)

        await eventually { client.state == .stopped(.signedOut) }
        XCTAssertFalse(refused, "nothing stored is somebody signing out, not the server refusing them")
        XCTAssertTrue(sockets.made.isEmpty)
    }

    func testNoConnectionForTheTokenIsRetriedNotASignOut() async {
        let sockets = ScriptedSockets()
        let tokens = CountingRealtimeTokens(failing: APIError.transport("offline"))
        let waits = RecordedWaits()
        var refused = false
        let client = makeClient(sockets: sockets, tokens: tokens, waits: waits, onSessionRefused: { _ in refused = true })
        client.start(accountId: nil)

        await eventually { await waits.delays.count >= 2 }
        XCTAssertFalse(refused, "an offline phone is not signed out")
        await tokens.fail(with: nil)
        await eventually("it never connected once the network came back") { client.isLive }
    }

    // MARK: - Closes

    func testASuspensionStopsTheSocketAndIsReportedLikeAn403() async throws {
        let sockets = ScriptedSockets()
        let suspension = SuspensionCounter()
        let client = makeClient(sockets: sockets, suspension: suspension)
        let heard = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].serverClose(code: 4403, errorCode: "account_suspended")
        await eventually("did not stop") { client.state == .stopped(.suspended) }
        XCTAssertEqual(suspension.reported, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sockets.made.count, 1, "a suspended account is not reconnected")
        XCTAssertTrue(heard.contains { if case .disconnected = $0 { return true }; return false })
    }

    func testADeletionPendingStopsWithoutReconnecting() async throws {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].serverClose(code: 4403, errorCode: "account_deactivated")
        await eventually { client.state == .stopped(.deactivated) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sockets.made.count, 1)
    }

    func testRealTimeUnavailableFallsBackAndWaitsHalfAMinute() async {
        let sockets = ScriptedSockets()
        let waits = RecordedWaits()
        let client = makeClient(sockets: sockets, waits: waits)
        let heard = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].serverClose(code: 1013, errorCode: "realtime_unavailable")
        await eventually("the screens were not told to refresh") {
            heard.contains { if case .unavailable = $0 { return true }; return false }
        }
        await eventually { await waits.delays.first != nil }
        let first = await waits.delays.first
        XCTAssertEqual(first, 30, "1013 waits half a minute, not a second")
    }

    func testTheRefreshAfterA1013WaitsItsPauseNotTheMomentTheSocketCloses() async throws {
        // A replica that loses Redis drops every socket at once; every phone
        // refreshing every screen in the same second is a burst the API
        // feels (2026-09-28 review).
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets, refreshPause: 0.6)
        let heard = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].serverClose(code: 1013, errorCode: "realtime_unavailable")
        await eventually("the socket never said it was down") {
            heard.contains { if case .disconnected = $0 { return true }; return false }
        }
        XCTAssertFalse(heard.contains { if case .unavailable = $0 { return true }; return false },
                       "not the moment the socket closed")
        await eventually("the screens were not told to refresh after the pause") {
            heard.contains { if case .unavailable = $0 { return true }; return false }
        }
    }

    func testARefreshStillPendingIsDroppedWhenTheSocketIsStopped() async throws {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets, refreshPause: 0.3)
        let heard = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }
        sockets.made[0].serverClose(code: 1013, errorCode: "realtime_unavailable")
        await eventually { heard.contains { if case .disconnected = $0 { return true }; return false } }
        client.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(heard.contains { if case .unavailable = $0 { return true }; return false })
    }

    func testTooManyConnectionsWaitsAMinute() async {
        let sockets = ScriptedSockets()
        let waits = RecordedWaits()
        let client = makeClient(sockets: sockets, waits: waits)
        client.start(accountId: nil)
        await eventually { client.isLive }

        sockets.made[0].serverClose(code: 4429, errorCode: "too_many_connections")
        await eventually { await waits.delays.first != nil }
        let first = await waits.delays.first
        XCTAssertEqual(first, 60)
    }

    func testDroppedSocketsBackOffOneTwoFiveTenThirtyThenAMinute() async {
        let sockets = ScriptedSockets()
        // Every socket drops before `ready`: the network is not there.
        sockets.respond = { _, socket, _ in socket.serverClose(code: 1006) }
        let waits = RecordedWaits()
        let client = makeClient(sockets: sockets, waits: waits)
        client.start(accountId: nil)

        await eventually(timeout: 5) { await waits.delays.count >= 7 }
        client.stop()
        let delays = await waits.delays
        XCTAssertEqual(Array(delays.prefix(7)), [1, 2, 5, 10, 30, 60, 60])
    }

    func testTheBackoffStartsAgainAfterASocketStayedUpAMinute() async {
        let clock = TestClock()
        let sockets = ScriptedSockets()
        sockets.respond = { index, socket, frame in
            // The first socket drops at once; the second stays up.
            if index == 0 { socket.serverClose(code: 1006) } else { ScriptedSockets.answer(socket, frame) }
        }
        let waits = RecordedWaits()
        let client = makeClient(sockets: sockets, waits: waits, now: { clock.now })
        client.start(accountId: nil)
        await eventually { client.isLive }

        clock.advance(61)
        sockets.made[1].serverClose(code: 1012)   // a deploy
        await eventually { await waits.delays.count >= 2 }
        let delays = await waits.delays
        XCTAssertEqual(Array(delays.prefix(2)), [1, 1], "a minute up resets the backoff to one second")
    }

    func testStopClosesNormallyAndNothingReconnects() async throws {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        let heard = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }

        client.stop()
        XCTAssertEqual(sockets.made[0].closeCode, 1000, "a normal close gives the socket's place back at once")
        XCTAssertEqual(client.state, .off)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sockets.made.count, 1)
        await eventually { heard.contains { if case .disconnected = $0 { return true }; return false } }

        // Back in the foreground: a fresh socket, and a fresh `ready`.
        client.start(accountId: nil)
        await eventually { client.isLive && sockets.made.count == 2 }
        await eventually { heard.readies == 2 }
    }

    func testAnotherAccountReplacesTheSocket() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        client.start(accountId: UUID())
        await eventually { client.isLive }

        client.start(accountId: UUID())
        await eventually { sockets.made.count == 2 && client.isLive }
        XCTAssertEqual(sockets.made[0].closeCode, 1000)

        // The same account again changes nothing.
        client.start(accountId: nil)
        await eventually { sockets.made.count == 3 && client.isLive }
        client.start(accountId: nil)
        XCTAssertEqual(sockets.made.count, 3)
    }

    func testASilentSocketIsReplaced() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets, silenceLimit: 0.3)
        client.start(accountId: nil)
        await eventually { client.isLive }

        // Nothing more from the server — not even a ping.
        await eventually(timeout: 5, "a dead socket was kept") { sockets.made.count >= 2 }
        XCTAssertNotNil(sockets.made[0].closeCode)
    }

    // MARK: - Typing

    func testTypingGoesOutOnlyWhileLiveAndInOrder() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        let thread = UUID()
        XCTAssertFalse(client.sendTyping(conversationId: thread, active: true), "nothing to send it on")

        client.start(accountId: nil)
        await eventually { client.isLive }
        XCTAssertTrue(client.sendTyping(conversationId: thread, active: true))
        XCTAssertTrue(client.sendTyping(conversationId: thread, active: false))

        await eventually { sockets.made[0].sent.count == 3 }
        let frames = sockets.made[0].sent.dropFirst().map(frameObject)
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["typing", "typing"])
        XCTAssertEqual(frames[0]["conversation_id"] as? String, thread.uuidString.lowercased())
        XCTAssertNil(frames[0]["active"], "typing is the default; only stopping says active")
        XCTAssertEqual(frames[1]["active"] as? Bool, false)
    }

    func testATypingRefusalIsPassedOnAndTheSocketStays() async {
        let sockets = ScriptedSockets()
        let client = makeClient(sockets: sockets)
        let heard = listen(to: client)
        client.start(accountId: nil)
        await eventually { client.isLive }

        let thread = UUID()
        sockets.made[0].deliver(json: [
            "type": "error", "code": "not_found", "ref": "typing", "conversation_id": thread.uuidString.lowercased(),
        ])
        await eventually {
            heard.contains { if case let .typingRefused(code, id) = $0 { return code == "not_found" && id == thread }; return false }
        }
        XCTAssertTrue(sockets.made[0].isOpen)
        XCTAssertTrue(client.isLive)
    }
}

/// Frames exactly as the server writes them.
enum RealtimeFixtures {

    static let thread = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    static let noura = UUID(uuidString: "5f0c0000-0000-4000-8000-00000000a001")!

    static func message(
        id: UUID = UUID(),
        text: String?,
        from sender: UUID = noura,
        handle: String = "noura",
        read: Bool = false,
        at date: String = "2026-09-28T14:45:33.426810+00:00"
    ) -> [String: Any] {
        [
            "id": id.uuidString.lowercased(),
            "conversation_id": thread.uuidString.lowercased(),
            "sender": [
                "id": sender.uuidString.lowercased(), "handle": handle, "display_name": "Noura",
                "avatar_url": NSNull(), "is_verified": true, "country_code": "SA",
            ] as [String: Any],
            "text": text ?? NSNull(),
            "deleted": text == nil,
            "read": read,
            "created_at": date,
        ]
    }

    static func messageNew(
        id: UUID = UUID(),
        text: String?,
        from sender: UUID = noura,
        handle: String = "noura",
        isRequest: Bool = false,
        alert: Bool = true,
        at date: String = "2026-09-28T14:45:33.426810+00:00"
    ) -> [String: Any] {
        [
            "type": "message.new",
            "at": "2026-09-28T14:45:33.430000+00:00",
            "conversation_id": thread.uuidString.lowercased(),
            "message": message(id: id, text: text, from: sender, handle: handle, at: date),
            "conversation": ["id": thread.uuidString.lowercased(), "accepted": !isRequest, "is_request": isRequest],
            "alert": alert,
        ]
    }

    static func json(_ frame: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]), as: UTF8.self)
    }

    static func event(_ frame: [String: Any]) -> RealtimeEvent? {
        guard case let .event(event) = RealtimeFrame.parse(json(frame)) else { return nil }
        return event
    }
}
