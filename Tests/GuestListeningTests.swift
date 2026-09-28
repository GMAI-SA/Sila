import XCTest
@testable import Sila

/// Listening to a room without an account (contract v31, owner request
/// 2026-09-28): the seat and its pass, every refusal in words, the renewal a
/// minute before the token lapses, the reconnect limit, a guest's chat and
/// reactions, and — above all — that a guest's connection never publishes
/// and never asks for the microphone.
///
/// Everything here runs against ``GuestRoomsServiceMock`` or a scripted
/// transport, and ``VoiceEngineMock``; nothing reaches a server or a media
/// stack.
final class GuestListeningTests: XCTestCase {

    private static let roomId = UUID(uuidString: "00000000-0000-4000-8000-000000000701")!
    private static let scheduledId = UUID(uuidString: "00000000-0000-4000-8000-000000000704")!

    private static let host = #"{"id": "00000000-0000-4000-8000-000000000101", "handle": "noura", "display_name": "Noura", "is_verified": true}"#

    private static func card(_ extra: String = "") -> String {
        #"{"id": "00000000-0000-4000-8000-000000000701", "title": "Morning coffee", "topic": null, "status": "live", "scope": "international", "host": \#(host), "participant_count": 9, "metrics": {"likes": 3, "shares": 0, "views": 40, "listeners": 9} \#(extra)}"#
    }

    // MARK: - The wire

    func testASeatDecodesAsTheContractWritesIt() throws {
        let seat = try JSONCoding.decoder.decode(GuestSeat.self, from: Data("""
        {"room": \(Self.card(#", "allow_guests": true, "guest_count": 4"#)), "url": "wss://sila.gmai.sa/rtc",
         "token": "eyJ.x.y", "identity": "guest-0123456789abcdef0123456789abcdef", "guest_pass": "p.1",
         "expires_in": 600, "role": "guest"}
        """.utf8))
        XCTAssertEqual(seat.url, "wss://sila.gmai.sa/rtc")
        XCTAssertEqual(seat.identity, "guest-0123456789abcdef0123456789abcdef")
        XCTAssertEqual(seat.guestPass, "p.1")
        XCTAssertEqual(seat.expiresIn, 600)
        XCTAssertEqual(seat.role, "guest")
        XCTAssertEqual(seat.room?.allowGuests, true)
        XCTAssertEqual(seat.room?.guestCount, 4)
    }

    func testASeatWithoutATokenIsNoSeat() {
        XCTAssertThrowsError(try JSONCoding.decoder.decode(GuestSeat.self, from: Data(#"{"url": "wss://x"}"#.utf8)))
        XCTAssertThrowsError(try JSONCoding.decoder.decode(GuestSeat.self, from: Data(#"{"token": "t"}"#.utf8)))
        // A missing lifetime is the contract's ten minutes, not zero.
        let seat = try? JSONCoding.decoder.decode(GuestSeat.self, from: Data(#"{"url": "wss://x", "token": "t"}"#.utf8))
        XCTAssertEqual(seat?.expiresIn, 600)
    }

    func testCardsAndRoomsCarryTheGuestFields() throws {
        let card = try JSONCoding.decoder.decode(RoomCard.self, from: Data(Self.card(
            #", "allow_guests": true, "guest_count": 7, "starter_question": "Best coffee?", "kind": "ama""#
        ).utf8))
        XCTAssertTrue(card.allowGuests)
        XCTAssertEqual(card.guestCount, 7)
        XCTAssertEqual(card.liveGuestCount, 7)
        XCTAssertEqual(card.starterQuestion, "Best coffee?")
        XCTAssertTrue(card.isAMA)

        // A server before v31 says neither: nobody may listen without an account.
        let old = try JSONCoding.decoder.decode(RoomCard.self, from: Data(Self.card().utf8))
        XCTAssertFalse(old.allowGuests)
        XCTAssertEqual(old.guestCount, 0)

        let room = try JSONCoding.decoder.decode(VoiceRoom.self, from: Data("""
        {"id": "00000000-0000-4000-8000-000000000702", "title": "Live", "status": "live", "host": \(Self.host),
         "allow_guests": true, "guest_count": 3}
        """.utf8))
        XCTAssertTrue(room.allowGuests)
        XCTAssertEqual(room.guestCount, 3)
        let scheduled = try JSONCoding.decoder.decode(VoiceRoom.self, from: Data("""
        {"id": "00000000-0000-4000-8000-000000000703", "title": "Later", "status": "scheduled", "host": \(Self.host),
         "allow_guests": true, "guest_count": 3}
        """.utf8))
        XCTAssertEqual(scheduled.guestCount, 0, "guests are counted only while a room is live")
    }

    func testTheListenBodyIsEmptyTheFirstTimeAndCarriesThePassAfter() throws {
        let first = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(GuestListenBody(guestPass: nil))) as? [String: Any]
        XCTAssertEqual(first?.count, 0)
        let renewal = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(GuestListenBody(guestPass: "p.1"))) as? [String: Any]
        XCTAssertEqual(renewal?["guest_pass"] as? String, "p.1")
    }

    func testTheServersRoomEventsAreReadSnakeCased() throws {
        let off = try XCTUnwrap(RoomDataMessage.decode(Data(#"{"type": "guests_changed", "allow_guests": false}"#.utf8)))
        XCTAssertEqual(off.allowGuests, false)
        let hidden = try XCTUnwrap(RoomDataMessage.decode(Data(#"{"type": "chat_hidden", "message_id": "abc"}"#.utf8)))
        XCTAssertEqual(hidden.messageId, "abc")
        let kept = try XCTUnwrap(RoomDataMessage.decode(Data("""
        {"type": "chat", "message": {"id": "00000000-0000-4000-8000-000000000f01", "text": "hi", "author": \(Self.host),
         "created_at": "2026-09-28T10:00:00Z", "hidden": false}}
        """.utf8)))
        XCTAssertEqual(kept.message?.author?.displayName, "Noura", "a kept line's author keeps their name")
        // What a phone sends still reads as it always has.
        let reaction = RoomDataMessage.reaction("👏", userId: UUID(), handle: "aziz", name: "Aziz", big: true)
        let back = try XCTUnwrap(RoomDataMessage.decode(reaction.encoded()))
        XCTAssertEqual(back.emoji, "👏")
        XCTAssertTrue(back.big)
        XCTAssertEqual(back.name, "Aziz")
    }

    func testAParticipantIsReadFromTheMetadataOnTheirToken() {
        let host = VoiceParticipant(identity: "ABC", name: "Noura", metadata: #"{"role":"host","handle":"noura","user_id":"abc"}"#)
        XCTAssertEqual(host.identity, "abc")
        XCTAssertTrue(host.isHost)
        XCTAssertTrue(host.isOnStage)
        XCTAssertEqual(host.handle, "noura")
        let listener = VoiceParticipant(identity: "d", name: nil, metadata: "not json")
        XCTAssertFalse(listener.isOnStage, "unreadable metadata is somebody in the audience")
        XCTAssertEqual(listener.displayName, L10n.t("rooms.chat.someone"))
    }

    // MARK: - The service

    func testTheListIsThePublicRouteWithNoToken() async throws {
        let network = StubNetworkClient(responses: [#"{"rooms": [\#(Self.card(#", "allow_guests": true"#)), {"id": "bad"}]}"#])
        let service = GuestRoomsService(network: network, analytics: RecordingAnalyticsClient())

        let rooms = try await service.fetchRooms(status: .live, limit: 20)
        XCTAssertEqual(rooms.count, 1, "one unreadable card costs that card, not the list")
        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/public/rooms")
        XCTAssertEqual(request.queryValue("status"), "live")
        XCTAssertNil(request.accessToken, "a guest has no token to send")

        _ = try await service.fetchRooms(status: .scheduled, limit: 50)
        XCTAssertEqual(network.lastRequest?.queryValue("status"), "scheduled")
        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "30", "the public list answers 422 past thirty")
    }

    func testListeningPostsTheRoomWithNoTokenAndThePassWhenThereIsOne() async throws {
        let answer = #"{"url": "wss://sila.gmai.sa/rtc", "token": "t", "identity": "guest-1", "guest_pass": "p.1", "expires_in": 600}"#
        let network = StubNetworkClient(responses: [answer, answer])
        let service = GuestRoomsService(network: network, analytics: RecordingAnalyticsClient())

        _ = try await service.listen(roomId: Self.roomId, guestPass: nil)
        var request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/public/rooms/00000000-0000-4000-8000-000000000701/listen")
        XCTAssertEqual(request.method, .post)
        XCTAssertNil(request.accessToken)
        XCTAssertEqual(String(decoding: request.body ?? Data(), as: UTF8.self), "{}")

        _ = try await service.listen(roomId: Self.roomId, guestPass: "p.1")
        request = try XCTUnwrap(network.lastRequest)
        let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["guest_pass"] as? String, "p.1")
        XCTAssertNil(request.accessToken)
    }

    /// `Retry-After` is a header, and only the call that asks for it gets it:
    /// every other caller still catches the plain error it always has.
    func testATooManyTriesRefusalCarriesTheServersWait() async throws {
        RetryAfterURLProtocol.stub = (429, #"{"detail": {"code": "rate_limited", "message": "Too many attempts — try again in 45 seconds"}}"#, ["Retry-After": "45"])
        let client = URLSessionNetworkClient(baseURL: URL(string: "https://sila.invalid/api/v1")!, session: RetryAfterURLProtocol.session())
        struct Nothing: Decodable {}

        do {
            _ = try await client.sendNotingRetryAfter(APIRequest(path: "/public/rooms/x/listen", method: .post), as: Nothing.self)
            XCTFail("a refusal was taken for a seat")
        } catch let refusal as RetryAfterRefusal {
            XCTAssertEqual(refusal.seconds, 45)
            XCTAssertEqual(refusal.error.code, .rateLimited)
            XCTAssertEqual(GuestRefusal(error: refusal), GuestRefusal(.rateLimited, retryAfter: 45))
            XCTAssertEqual(APIError.wrapping(refusal).code, .rateLimited, "a caller that does not care reads it as always")
        }

        do {
            _ = try await client.send(APIRequest(path: "/x"), as: Nothing.self)
            XCTFail("a refusal was taken for an answer")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .rateLimited)
        }

        XCTAssertEqual(RetryAfterRefusal.seconds(fromHeader: "12"), 12)
        XCTAssertNil(RetryAfterRefusal.seconds(fromHeader: "Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(RetryAfterRefusal.seconds(fromHeader: "0"))
    }

    // MARK: - Refusals

    func testEveryRefusalCodeIsReadAsItself() {
        func api(_ code: APIErrorCode, _ status: Int) -> APIError { .api(code: code, message: "", status: status) }
        XCTAssertEqual(GuestRefusal(error: api(.notFound, 404)).code, .notFound)
        XCTAssertEqual(GuestRefusal(error: api(.roomClosed, 403)).code, .roomClosed)
        XCTAssertEqual(GuestRefusal(error: api(.guestsNotAllowed, 403)).code, .guestsNotAllowed)
        XCTAssertEqual(GuestRefusal(error: api(.roomNotLive, 409)).code, .roomNotLive)
        XCTAssertEqual(GuestRefusal(error: api(.roomEnded, 409)).code, .roomEnded)
        XCTAssertEqual(GuestRefusal(error: api(.guestsFull, 409)).code, .guestsFull)
        XCTAssertEqual(GuestRefusal(error: api(.rateLimited, 429)), GuestRefusal(.rateLimited))
        XCTAssertEqual(GuestRefusal(error: api(.unknown, 404)).code, .notFound)
        XCTAssertEqual(GuestRefusal(error: api(.unknown, 429)).code, .rateLimited)
        // Anything else is the line failing: trying again is what helps.
        XCTAssertEqual(GuestRefusal(error: APIError.transport("offline")).code, .connectFailed)
        XCTAssertEqual(GuestRefusal(error: api(.unknown, 502)).code, .connectFailed)
        XCTAssertEqual(GuestRefusal(error: APIError.decoding("x")).code, .connectFailed)
    }

    /// What each refusal offers: joining where a member could do what a guest
    /// cannot, trying again where asking again may work — the web's table.
    func testEachRefusalOffersWhatCanBeDoneAboutIt() {
        let offersJoin: [GuestRefusal.Code: Bool] = [
            .notFound: false, .roomClosed: true, .guestsNotAllowed: true, .roomNotLive: true,
            .roomEnded: true, .guestsFull: true, .rateLimited: false, .connectFailed: false,
        ]
        let canRetry: [GuestRefusal.Code: Bool] = [
            .notFound: false, .roomClosed: false, .guestsNotAllowed: false, .roomNotLive: true,
            .roomEnded: false, .guestsFull: true, .rateLimited: true, .connectFailed: true,
        ]
        for code in GuestRefusal.Code.allCases {
            let refusal = GuestRefusal(code)
            XCTAssertEqual(refusal.offersJoin, offersJoin[code], "\(code)")
            XCTAssertEqual(refusal.canRetry, canRetry[code], "\(code)")
        }
    }

    /// Every refusal has its own words, in English and in Arabic — none of
    /// them "something went wrong", none of them a key.
    func testEveryRefusalHasItsOwnWordsInBothLanguages() {
        for language in ["en", "ar"] {
            L10n.withLanguage(language) {
                var titles = Set<String>()
                for code in GuestRefusal.Code.allCases {
                    let refusal = GuestRefusal(code)
                    XCTAssertFalse(refusal.title.hasPrefix("guest.room"), "\(code) shows its key in \(language)")
                    XCTAssertFalse(refusal.detail.hasPrefix("guest.room"), "\(code) shows its key in \(language)")
                    XCTAssertNotEqual(refusal.title, L10n.t("common.somethingWentWrong"))
                    titles.insert(refusal.title)
                    if language == "ar" {
                        XCTAssertTrue(refusal.title.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }, "\(code) is not Arabic")
                    }
                }
                XCTAssertEqual(titles.count, GuestRefusal.Code.allCases.count, "two refusals say the same thing in \(language)")
            }
        }
        L10n.withLanguage("en") {
            XCTAssertEqual(GuestRefusal(.roomClosed).title, "This room is for members only")
            XCTAssertEqual(GuestRefusal(.guestsFull).title, "This room has no guest seats left")
            XCTAssertEqual(GuestRefusal(.connectFailed).title, "Couldn't connect to the room")
        }
        L10n.withLanguage("ar") {
            XCTAssertEqual(GuestRefusal(.roomClosed).title, "هذه الغرفة للأعضاء فقط")
            XCTAssertEqual(GuestRefusal(.guestsNotAllowed).title, "لا يمكن للزوار الاستماع إلى هذه الغرفة")
        }
    }

    func testTheWaitIsSaidInWordsWithArabicPlurals() {
        L10n.withLanguage("en") {
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 1), "Try again in 1 second")
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 45), "Try again in 45 seconds")
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 150), "Try again in 3 minutes")
        }
        L10n.withLanguage("ar") {
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 2), "أعد المحاولة بعد ثانيتين")
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 5), "أعد المحاولة بعد 5 ثوانٍ")
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 45), "أعد المحاولة بعد 45 ثانية")
            XCTAssertEqual(GuestRefusal.tryAgainIn(seconds: 120), "أعد المحاولة بعد دقيقتين")
        }
    }

    func testTheGuestsCountIsAPluralInBothLanguages() {
        L10n.withLanguage("en") {
            XCTAssertEqual(RoomCopy.guestsListening(1), "1 guest listening")
            XCTAssertEqual(RoomCopy.guestsListening(12), "12 guests listening")
            XCTAssertEqual(RoomCopy.guestsLine(allowGuests: true, guestCount: 3, isLive: true), "Guests can listen · 3 guests listening")
            XCTAssertEqual(RoomCopy.guestsLine(allowGuests: true, guestCount: 0, isLive: true), "Guests can listen")
            // Turned off with guests still leaving: the count alone.
            XCTAssertEqual(RoomCopy.guestsLine(allowGuests: false, guestCount: 2, isLive: true), "2 guests listening")
            XCTAssertNil(RoomCopy.guestsLine(allowGuests: false, guestCount: 0, isLive: true))
            XCTAssertEqual(RoomCopy.guestsLine(allowGuests: true, guestCount: 5, isLive: false), "Guests can listen")
        }
        L10n.withLanguage("ar") {
            XCTAssertEqual(RoomCopy.guestsListening(1), "زائر واحد يستمع")
            XCTAssertEqual(RoomCopy.guestsListening(2), "زائران يستمعان")
            XCTAssertEqual(RoomCopy.guestsListening(12), "12 من الزوار يستمعون")
            XCTAssertEqual(RoomCopy.guestsLine(allowGuests: true, guestCount: 3, isLive: true), "يمكن للزوار الاستماع · 3 من الزوار يستمعون")
        }
    }

    func testTheInvitationToTakePartIsWorded() {
        L10n.withLanguage("en") {
            XCTAssertEqual(JoinPrompt.takePart.title, "Join Sila to take part")
            XCTAssertTrue(JoinPrompt.takePart.detail.contains("Guests can listen"))
        }
        L10n.withLanguage("ar") {
            XCTAssertEqual(JoinPrompt.takePart.title, "انضم إلى صلة لتشارك")
        }
    }

    // MARK: - Timing

    func testASeatIsRenewedAMinuteBeforeItsTokenLapses() {
        XCTAssertEqual(GuestListening.renewDelay(expiresIn: 600), 540)
        XCTAssertEqual(GuestListening.renewDelay(expiresIn: 70), 30, "never sooner than thirty seconds")
        XCTAssertEqual(GuestListening.renewDelay(expiresIn: 0), 540, "no lifetime reads as the contract's ten minutes")
    }

    func testAtMostTwoReconnectionsAMinute() {
        let now = Date()
        XCTAssertTrue(GuestListening.mayReconnect(now: now, previous: []))
        XCTAssertTrue(GuestListening.mayReconnect(now: now, previous: [now.addingTimeInterval(-10)]))
        XCTAssertFalse(GuestListening.mayReconnect(now: now, previous: [now.addingTimeInterval(-10), now.addingTimeInterval(-50)]))
        XCTAssertTrue(GuestListening.mayReconnect(now: now, previous: [now.addingTimeInterval(-61), now.addingTimeInterval(-70)]))
    }

    // MARK: - Chat, as a guest reads it

    func testAGuestReadsKeptLinesAndLinesToTheRoomButNeverOnesToTheHost() {
        var kept = RoomDataMessage(type: "chat", userId: "")
        kept.message = RoomMessage(id: UUID(uuidString: "00000000-0000-4000-8000-000000000f01")!, text: " hi ",
                                   author: UserSummary(id: UUID(), handle: "noura", displayName: "Noura", isVerified: true))
        XCTAssertEqual(GuestChatLine.from(kept), GuestChatLine(id: "00000000-0000-4000-8000-000000000f01", name: "Noura", text: "hi"))

        var hidden = kept
        hidden.message = RoomMessage(text: "gone", hidden: true)
        XCTAssertNil(GuestChatLine.from(hidden), "a hidden line is the stage's and its author's")

        let toRoom = RoomDataMessage.chat("hello", userId: UUID(), handle: "yuki", name: nil, toHost: false)
        XCTAssertEqual(GuestChatLine.from(toRoom, localId: { "l1" }), GuestChatLine(id: "l1", name: "@yuki", text: "hello"))
        let toHost = RoomDataMessage.chat("psst", userId: UUID(), handle: "yuki", name: "Yuki", toHost: true)
        XCTAssertNil(GuestChatLine.from(toHost))
        XCTAssertNil(GuestChatLine.from(.reaction("👏", userId: UUID(), handle: nil, name: nil)))
    }
}

// MARK: - The room, end to end against the mocks

@MainActor
final class GuestRoomViewModelTests: XCTestCase {

    private static let live = UUID(uuidString: "00000000-0000-4000-8000-000000000701")!
    private static let scheduled = UUID(uuidString: "00000000-0000-4000-8000-000000000704")!

    private var engines: [VoiceEngineMock] = []
    private var clock = ManualClock()
    private var analytics = RecordingAnalyticsClient()

    override func setUp() async throws {
        engines = []
        clock = ManualClock()
        analytics = RecordingAnalyticsClient()
    }

    private func makeViewModel(
        _ service: GuestRoomsServiceMock,
        roomId: UUID = live,
        card: RoomCard? = nil,
        passes: GuestPassBook? = nil,
        connectError: VoiceEngineError? = nil,
        people: [VoiceParticipant] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> GuestRoomViewModel {
        GuestRoomViewModel(
            roomId: roomId,
            card: card,
            service: service,
            passes: passes ?? GuestPassBook(),
            makeEngine: { [unowned self] in
                let engine = VoiceEngineMock(isPermissionGranted: true)
                engine.connectError = connectError
                engine.participantsOnConnect = people
                self.engines.append(engine)
                return engine
            },
            analytics: analytics,
            sleep: clock.sleep,
            now: now
        )
    }

    private static let stage = [
        VoiceParticipant(identity: "a", name: "Noura", role: "host", handle: "noura"),
        VoiceParticipant(identity: "b", name: "Yuki", role: "speaker", handle: "yuki"),
        VoiceParticipant(identity: "c", name: "Maria", role: "listener", handle: "maria"),
    ]

    // MARK: Listening

    /// **One tap listens.** A seat, then the media server at once, listen
    /// only: the engine is never asked to publish and the microphone is never
    /// touched — the mock's permission is even granted, so a stray request
    /// would have gone through and shown up.
    func testOpeningARoomListensAtOnceAndNeverAsksForTheMicrophone() async throws {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service, people: Self.stage)

        await viewModel.open()

        XCTAssertEqual(viewModel.phase, .listening)
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.recordedCalls, ["connect:listener"], "a guest's connection did something besides listen")
        XCTAssertFalse(engine.connectedCanPublish)
        XCTAssertEqual(engine.connectedURL, "wss://sila.gmai.sa/rtc")
        XCTAssertTrue(engine.publishedMessages.isEmpty, "a guest sent something into the room")
        XCTAssertFalse(engine.recordedCalls.contains { $0.hasPrefix("mic:") })
        // The card came with the answer, the people with the media server.
        XCTAssertEqual(viewModel.card?.guestCount, 12)
        XCTAssertEqual(viewModel.stage.map(\.name), ["Noura", "Yuki"])
        XCTAssertEqual(viewModel.audience.map(\.name), ["Maria"])
        L10n.withLanguage("en") {
            XCTAssertEqual(viewModel.attendanceLine, "2 speaking · 1 listening · 12 guests listening")
        }
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["listen:00000000-0000-4000-8000-000000000701:none"])
        XCTAssertEqual(analytics.events.suffix(2), [.guestRoomOpened, .guestRoomListening])
    }

    func testAGuestsEngineCannotReachThePrompt() async {
        let granted = await NoMicrophonePermission().requestPermission()
        XCTAssertFalse(granted)
    }

    func testOpeningTwiceAsksOnce() async {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service)
        await viewModel.open()
        await viewModel.open()
        let calls = await service.recordedCalls
        XCTAssertEqual(calls.count, 1, "a sheet closing over the room asked for a second seat")
    }

    // MARK: Renewing

    /// A minute before the token's ten minutes are up, with the pass: the
    /// same seat, not a second one.
    func testTheSeatIsRenewedWithItsPassAMinuteBeforeTheTokenLapses() async throws {
        let service = GuestRoomsServiceMock()
        let passes = GuestPassBook()
        let viewModel = makeViewModel(service, passes: passes)
        await viewModel.open()
        let first = try XCTUnwrap(passes.pass(for: Self.live))

        await waitUntil { self.clock.requested.count == 1 }
        XCTAssertEqual(clock.requested, [540])
        clock.fireAll()
        await waitUntil { self.clock.requested.count == 2 }

        let sent = await service.passesSent
        XCTAssertEqual(sent, [nil, first], "the renewal did not carry the pass")
        XCTAssertEqual(passes.pass(for: Self.live), first, "the same seat came back under a new pass")
        XCTAssertEqual(viewModel.phase, .listening)
        XCTAssertEqual(engines.count, 1, "a renewal reconnected a connection that was up")
        XCTAssertEqual(clock.requested.last, 540, "the next renewal was not scheduled")
    }

    func testARenewalTheServerRefusesEndsTheListening() async throws {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service)
        await viewModel.open()
        await service.refuseLater(.roomEnded)

        await waitUntil { self.clock.requested.count == 1 }
        clock.fireAll()
        await waitUntil { viewModel.refusal != nil }

        XCTAssertEqual(viewModel.refusal?.code, .roomEnded)
        await waitUntil { self.engines.first?.disconnectCount == 1 }
        XCTAssertTrue(viewModel.participants.isEmpty)
    }

    func testARenewalLostOnTheNetworkIsTriedAgainAndTheRoomPlaysOn() async throws {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service)
        await viewModel.open()
        await service.setScenario(.offline)

        await waitUntil { self.clock.requested.count == 1 }
        clock.fireAll()
        await waitUntil { self.clock.requested.count == 2 }

        XCTAssertEqual(clock.requested.last, GuestListening.renewRetryDelay)
        XCTAssertEqual(viewModel.phase, .listening, "a blinking line ended a connection that was up")
    }

    // MARK: Losing the connection

    /// A dropped connection asks again with the pass: the answer is a fresh
    /// token (reconnect) or a refusal saying why. Twice a minute, then the
    /// guest is asked to try again themselves.
    func testADroppedConnectionIsAskedForAgainAtMostTwiceAMinute() async throws {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service)
        await viewModel.open()

        engines[0].simulateFailure("gone")
        await waitUntil { self.engines.count == 2 && viewModel.phase == .listening }
        let sent = await service.passesSent
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotNil(sent[1], "the reconnect took a second seat instead of renewing")

        engines[1].simulateFailure("gone")
        await waitUntil { self.engines.count == 3 && viewModel.phase == .listening }

        engines[2].simulateFailure("gone")
        await waitUntil { viewModel.refusal != nil }
        XCTAssertEqual(viewModel.refusal?.code, .connectFailed)
        XCTAssertEqual(engines.count, 3, "a third reconnect in a minute was attempted")

        // "Try again" is the guest's own, and starts afresh.
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .listening)
    }

    func testTheServerTakingGuestsOutIsSaidInWords() async throws {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service)
        await viewModel.open()
        await service.refuseLater(.guestsNotAllowed)

        engines[0].simulateFailure("removed")
        await waitUntil { viewModel.refusal != nil }
        XCTAssertEqual(viewModel.refusal?.code, .guestsNotAllowed)
    }

    func testTheHostTurningGuestsOffEndsTheListeningAtOnce() async throws {
        let viewModel = makeViewModel(GuestRoomsServiceMock())
        await viewModel.open()
        var message = RoomDataMessage(type: "guests_changed", userId: "")
        message.allowGuests = false
        engines[0].simulate(.message(message))
        XCTAssertEqual(viewModel.refusal?.code, .guestsNotAllowed)
    }

    func testAMediaServerThatCannotBeReachedIsAConnectionRefusal() async {
        let viewModel = makeViewModel(GuestRoomsServiceMock(), connectError: .transport("no route"))
        await viewModel.open()
        XCTAssertEqual(viewModel.refusal?.code, .connectFailed)
        XCTAssertTrue(viewModel.refusal?.canRetry == true)
    }

    // MARK: Refusals

    func testEveryRefusalTheServerAnswersReachesTheScreen() async {
        let scenarios: [(GuestRoomsServiceMock.MockScenario, GuestRefusal.Code)] = [
            (.notFound, .notFound), (.roomClosed, .roomClosed), (.guestsNotAllowed, .guestsNotAllowed),
            (.roomEnded, .roomEnded), (.guestsFull, .guestsFull), (.rateLimited, .rateLimited),
            (.offline, .connectFailed),
        ]
        for (scenario, code) in scenarios {
            engines = []
            let viewModel = makeViewModel(GuestRoomsServiceMock(scenario: scenario))
            await viewModel.open()
            XCTAssertEqual(viewModel.refusal?.code, code, "\(scenario)")
            XCTAssertTrue(engines.isEmpty, "\(scenario) dialled the media server without a seat")
        }
    }

    /// `Retry-After` counts down on the button.
    func testATooManyTriesRefusalCountsDownTheServersWait() async throws {
        let start = Date()
        let viewModel = makeViewModel(GuestRoomsServiceMock(scenario: .rateLimited), now: { start })
        await viewModel.open()
        XCTAssertEqual(viewModel.refusal, GuestRefusal(.rateLimited, retryAfter: 45))
        XCTAssertEqual(viewModel.secondsUntilRetry(at: start.addingTimeInterval(10)), 35)
        XCTAssertEqual(viewModel.secondsUntilRetry(at: start.addingTimeInterval(60)), 0)
    }

    /// A shared link to a room that has not started: said, with when it
    /// starts — read from the scheduled list, since the link carried no card.
    func testARoomThatHasNotStartedSaysWhenItDoes() async {
        let viewModel = makeViewModel(GuestRoomsServiceMock(), roomId: Self.scheduled)
        await viewModel.open()
        XCTAssertEqual(viewModel.refusal?.code, .roomNotLive)
        await waitUntil { viewModel.startsLine != nil }
        XCTAssertNotNil(viewModel.card?.scheduledFor)
    }

    // MARK: What the room says

    func testAGuestReadsTheChatAndSeesTheReactions() async throws {
        let viewModel = makeViewModel(GuestRoomsServiceMock())
        await viewModel.open()
        let engine = try XCTUnwrap(engines.first)

        var kept = RoomDataMessage(type: "chat", userId: "")
        let lineId = UUID()
        kept.message = RoomMessage(id: lineId, text: "Welcome", author: UserSummary(id: UUID(), handle: "noura", displayName: "Noura", isVerified: true))
        engine.simulate(.message(kept))
        engine.simulate(.message(kept))
        XCTAssertEqual(viewModel.chat.map(\.text), ["Welcome"], "a line twice is a line once")
        XCTAssertEqual(viewModel.unreadChat, 1)

        viewModel.isChatOpen = true
        XCTAssertEqual(viewModel.unreadChat, 0)

        var hide = RoomDataMessage(type: "chat_hidden", userId: "")
        hide.messageId = lineId.uuidString
        engine.simulate(.message(hide))
        XCTAssertTrue(viewModel.chat.isEmpty, "a line the stage hid stayed on a guest's screen")

        engine.simulate(.message(.reaction("🔥", userId: UUID(), handle: "yuki", name: "Yuki", big: true)))
        XCTAssertEqual(viewModel.reactions.map(\.emoji), ["🔥"])
        XCTAssertTrue(viewModel.reactions.first?.big == true)
        XCTAssertTrue(engine.publishedMessages.isEmpty)
    }

    func testLeavingClosesTheConnectionAndStopsRenewing() async throws {
        let service = GuestRoomsServiceMock()
        let viewModel = makeViewModel(service)
        await viewModel.open()
        await waitUntil { self.clock.requested.count == 1 }
        await viewModel.close()

        XCTAssertEqual(engines.first?.disconnectCount, 1)
        clock.fireAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls.count, 1, "a room that was left was renewed")
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting")
    }
}

// MARK: - The guest's Rooms tab

@MainActor
final class GuestRoomsViewModelTests: XCTestCase {

    func testTheTabListsLiveRoomsThenScheduledOnes() async {
        let viewModel = GuestRoomsViewModel(service: GuestRoomsServiceMock(), analytics: RecordingAnalyticsClient())
        await viewModel.load()
        XCTAssertEqual(viewModel.visibleLive.count, 3)
        XCTAssertEqual(viewModel.visibleLater.count, 2)
        XCTAssertEqual(viewModel.emptyKind, .none)
        XCTAssertTrue(viewModel.visibleLive.allSatisfy(\.allowGuests))
    }

    func testNothingOpenToGuestsIsSaidAsSuch() async {
        let viewModel = GuestRoomsViewModel(service: GuestRoomsServiceMock(scenario: .empty), analytics: RecordingAnalyticsClient())
        await viewModel.load()
        XCTAssertEqual(viewModel.emptyKind, .noRooms)
    }

    func testAListThatCannotLoadSaysWhyInWords() async {
        let viewModel = GuestRoomsViewModel(service: GuestRoomsServiceMock(scenario: .offline), analytics: RecordingAnalyticsClient())
        await viewModel.load()
        guard case let .failed(message) = viewModel.emptyKind else { return XCTFail("no failure shown") }
        XCTAssertFalse(message.isEmpty)
    }

    func testSearchingNarrowsBothSectionsLocally() async {
        let viewModel = GuestRoomsViewModel(service: GuestRoomsServiceMock(), analytics: RecordingAnalyticsClient())
        await viewModel.load()
        viewModel.query = "s"
        XCTAssertEqual(viewModel.emptyKind, .queryTooShort)
        viewModel.query = "science"
        XCTAssertEqual(viewModel.visibleLive.count, 0)
        XCTAssertEqual(viewModel.visibleLater.map(\.title), ["Weekly science reading group"])
        viewModel.query = "nothing like this"
        XCTAssertEqual(viewModel.emptyKind, .noMatches("nothing like this"))
    }
}

// MARK: - Doubles

/// A renewal clock driven by hand: records every wait asked for, and lets
/// them pass only when the test says so.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var _requested: [TimeInterval] = []

    var requested: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            await withCheckedContinuation { continuation in
                lock.lock()
                _requested.append(seconds)
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Lets every wait asked for so far pass.
    func fireAll() {
        lock.lock()
        let due = waiting
        waiting = []
        lock.unlock()
        for continuation in due { continuation.resume() }
    }
}

/// One canned answer with headers, for the transport's own handling of them.
final class RetryAfterURLProtocol: URLProtocol, @unchecked Sendable {

    static var stub: (status: Int, body: String, headers: [String: String]) = (200, "{}", [:])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryAfterURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body, headers) = Self.stub
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://sila.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(headers) { $1 }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
