import XCTest
@testable import Sila

/// Contract v31 against the staging API, through the app's own services,
/// decoders and room screen model: a guest's list, a seat and its renewal,
/// the grant on the token, every door a guest can meet, and a host turning
/// guests off.
///
/// Staging's LiveKit key is one no media server knows, so no token joins
/// anything: what is checked is the token call and every state around it,
/// not audio. The screen model is driven with the real engine, and ends up
/// either listening or saying it could not connect — never anything else.
///
/// **Disposable accounts only, on staging only.** The host is a fresh
/// `itest-ios-guests…@example.com`, made verified by the dev hook; the rooms
/// it opens are ended in `tearDown` whatever happened. It never runs the
/// shared test-user purge.
///
/// ```
/// ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
///   xcodebuild … test -only-testing:SilaTests/LiveGuestListeningTests
/// ```
final class LiveGuestListeningTests: XCTestCase {

    private let password = "Passw0rd!234"
    private var hostTokens: StaticAccessTokenProvider?
    /// Every room opened here. **Each is ended in tearDown.**
    private var opened: [UUID] = []

    override func setUpWithError() throws {
        _ = try LiveTarget.api()
    }

    override func tearDown() async throws {
        if let hostTokens {
            let rooms = RoomsService(network: LiveTarget.network(), tokens: hostTokens, analytics: RecordingAnalyticsClient())
            // Ending a scheduled room cancels it.
            for id in opened { _ = try? await rooms.endRoom(id: id) }
        }
        opened = []
        try await super.tearDown()
    }

    // MARK: - The host

    private func verifiedHost() async throws -> StaticAccessTokenProvider {
        let email = "itest-ios-guests\(UUID().uuidString.prefix(10).lowercased())@example.com"
        let auth = AuthService(
            network: LiveTarget.network(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await step("register") { try await auth.register(email: email, password: password) }
        let peek = try await LiveTarget.dev("otp/peek", query: [URLQueryItem(name: "email", value: email)])
        let code = try XCTUnwrap(peek["code"] as? String, "no code recorded for \(email)")
        let pair = try await step("verify the code") { try await auth.verifyOTP(email: email, code: code, purpose: .register, password: password) }
        _ = try await LiveTarget.dev("user/set", body: [
            "email": email, "verification_status": "verified", "country_code": "SA", "verified_days_ago": 30,
        ])
        let tokens = StaticAccessTokenProvider(token: pair.token.accessToken)
        hostTokens = tokens
        return tokens
    }

    private func open(_ rooms: RoomsService, _ request: CreateRoomRequest) async throws -> VoiceRoom {
        let room = try await step("open \(request.title)") { try await rooms.createRoom(request) }
        opened.append(room.id)
        return room
    }

    // MARK: - The journey

    func testAGuestListensMeetsEveryDoorInWordsAndIsTakenOutWhenTheHostSaysSo() async throws {
        let rooms = RoomsService(network: LiveTarget.network(), tokens: try await verifiedHost(), analytics: RecordingAnalyticsClient())
        let stamp = String(Int(Date().timeIntervalSince1970), radix: 36)

        let live = try await open(rooms, CreateRoomRequest(title: "ios-guests \(stamp) open", scope: .international))
        let closed = try await open(rooms, CreateRoomRequest(title: "ios-guests \(stamp) closed", scope: .international, isInviteOnly: true))
        let later = try await open(rooms, CreateRoomRequest(
            title: "ios-guests \(stamp) later", scope: .international, scheduledFor: Date().addingTimeInterval(2 * 3600)
        ))
        XCTAssertEqual(live.status, .live)
        XCTAssertTrue(live.allowGuests, "a new open room does not let guests listen by default")
        XCTAssertFalse(closed.allowGuests, "an invite-only room answered that guests may listen")

        // ── The guest: two public routes, and no token on either ──────────
        let transport = RecordingNetworkClient(LiveTarget.network())
        let guests = GuestRoomsService(network: transport, analytics: RecordingAnalyticsClient())

        let listed = try await step("list live rooms") { try await guests.fetchRooms(status: .live, limit: 50) }
        let card = try XCTUnwrap(listed.first { $0.id == live.id }, "the open room is not on a guest's list")
        XCTAssertTrue(card.allowGuests)
        XCTAssertFalse(listed.contains { $0.id == closed.id }, "a closed room was listed for guests")
        let upcoming = try await step("list scheduled rooms") { try await guests.fetchRooms(status: .scheduled, limit: 50) }
        XCTAssertTrue(upcoming.contains { $0.id == later.id }, "the scheduled room is not listed as coming up")

        let seat = try await step("listen") { try await guests.listen(roomId: live.id, guestPass: nil) }
        XCTAssertEqual(seat.role, "guest")
        XCTAssertNotNil(seat.identity.range(of: "^guest-[0-9a-f]{32}$", options: .regularExpression), seat.identity)
        XCTAssertFalse(seat.guestPass.isEmpty)
        XCTAssertEqual(seat.expiresIn, 600)
        XCTAssertEqual(seat.room?.allowGuests, true)
        XCTAssertTrue(seat.url.hasPrefix("ws"), seat.url)
        let grant = try XCTUnwrap(Self.videoGrant(seat.token)["video"] as? [String: Any], "the token carries no grant")
        XCTAssertEqual(grant["canSubscribe"] as? Bool, true)
        XCTAssertEqual(grant["canPublish"] as? Bool, false, "a guest's token may publish audio")
        XCTAssertEqual(grant["canPublishData"] as? Bool, false, "a guest's token may send data")
        XCTAssertEqual(grant["hidden"] as? Bool, true, "a guest would show on the roster")

        let renewed = try await step("renew") { try await guests.listen(roomId: live.id, guestPass: seat.guestPass) }
        XCTAssertEqual(renewed.identity, seat.identity, "a renewal took a second seat")
        XCTAssertTrue(transport.requests.allSatisfy { $0.accessToken == nil }, "a guest's request carried a token")

        // ── The screen, with the real media engine ─────────────────────────
        let listening = await GuestRoomViewModel(
            roomId: live.id, card: card, service: guests, passes: GuestPassBook(),
            makeEngine: { LiveKitVoiceEngine(permission: NoMicrophonePermission(), listenOnly: true) },
            analytics: RecordingAnalyticsClient()
        )
        await listening.open()
        let phase = await listening.phase
        switch phase {
        case .listening:
            break
        case let .refused(refusal):
            // Staging's token joins no media server: the screen says so and
            // offers to try again.
            XCTAssertEqual(refusal.code, .connectFailed, "the seat was refused as \(refusal.code)")
            XCTAssertTrue(refusal.canRetry)
        case .connecting:
            XCTFail("the room never settled")
        }
        await listening.close()

        // ── Every door a guest meets, in words ──────────────────────────────
        let closedRoom = await GuestRoomViewModel(
            roomId: closed.id, service: guests, passes: GuestPassBook(),
            makeEngine: { VoiceEngineMock() }, analytics: RecordingAnalyticsClient()
        )
        await closedRoom.open()
        let closedRefusal = await closedRoom.refusal
        XCTAssertEqual(closedRefusal?.code, .roomClosed)
        XCTAssertEqual(closedRefusal?.offersJoin, true)
        L10n.withLanguage("en") { XCTAssertEqual(closedRefusal?.title, "This room is for members only") }
        L10n.withLanguage("ar") { XCTAssertEqual(closedRefusal?.title, "هذه الغرفة للأعضاء فقط") }

        let laterRoom = await GuestRoomViewModel(
            roomId: later.id, service: guests, passes: GuestPassBook(),
            makeEngine: { VoiceEngineMock() }, analytics: RecordingAnalyticsClient()
        )
        await laterRoom.open()
        let laterRefusal = await laterRoom.refusal
        XCTAssertEqual(laterRefusal?.code, .roomNotLive)
        var starts = await laterRoom.startsLine
        for _ in 0..<100 where starts == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            starts = await laterRoom.startsLine
        }
        XCTAssertNotNil(starts, "a room that has not started does not say when it does")

        // ── The host turns guests off ───────────────────────────────────────
        let off = try await step("turn guests off") { try await rooms.setAllowGuests(false, roomId: live.id) }
        XCTAssertFalse(off.allowGuests)
        do {
            _ = try await guests.listen(roomId: live.id, guestPass: seat.guestPass)
            XCTFail("a guest was given a seat in a room whose host turned guests off")
        } catch {
            XCTAssertEqual(GuestRefusal(error: error).code, .guestsNotAllowed)
        }
        let after = try await step("list again") { try await guests.fetchRooms(status: .live, limit: 50) }
        XCTAssertFalse(after.contains { $0.id == live.id }, "the room stayed on a guest's list")

        // A closed room cannot be opened to guests: refused (`room_closed`),
        // or — its stored switch already on, as every new room's is — a
        // no-op whose answer still says guests may not listen.
        do {
            let answer = try await rooms.setAllowGuests(true, roomId: closed.id)
            XCTAssertFalse(answer.allowGuests, "a closed room was opened to guests")
        } catch {
            XCTAssertEqual(APIError.wrapping(error).code, .roomClosed)
        }

        // And back on: the same pass is welcome again.
        let on = try await step("turn guests on") { try await rooms.setAllowGuests(true, roomId: live.id) }
        XCTAssertTrue(on.allowGuests)
        let back = try await step("listen again") { try await guests.listen(roomId: live.id, guestPass: seat.guestPass) }
        XCTAssertEqual(back.role, "guest")
    }

    // MARK: - Helpers

    /// A call, named when it fails: a bare 422 says nothing about which one.
    private func step<T>(_ name: String, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            XCTFail("\(name): \(error)")
            throw error
        }
    }

    /// The claims of a LiveKit token, read without verifying it.
    private static func videoGrant(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw LiveTargetError("not a JWT") }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// The app's transport, with every request it was handed kept for a look.
final class RecordingNetworkClient: NetworkClient, @unchecked Sendable {
    private let inner: NetworkClient
    private let lock = NSLock()
    private var recorded: [APIRequest] = []

    init(_ inner: NetworkClient) { self.inner = inner }

    var requests: [APIRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func note(_ request: APIRequest) {
        lock.lock(); recorded.append(request); lock.unlock()
    }

    func send<Response: Decodable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        note(request)
        return try await inner.send(request, as: type)
    }

    func send(_ request: APIRequest) async throws {
        note(request)
        try await inner.send(request)
    }

    func sendData(_ request: APIRequest) async throws -> Data {
        note(request)
        return try await inner.sendData(request)
    }

    func sendNotingRetryAfter<Response: Decodable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        note(request)
        return try await inner.sendNotingRetryAfter(request, as: type)
    }
}
