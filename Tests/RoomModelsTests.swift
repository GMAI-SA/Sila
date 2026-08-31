import XCTest
@testable import Sila

/// The rooms domain: `RoomOut` decoding, the role that gates the microphone,
/// and the copy rules this feature would be dishonest without.
final class RoomModelsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }

    private static let host = """
    {"id": "22222222-0000-4000-8000-000000000002", "handle": "yuki",
     "display_name": "Yuki Tanaka", "is_verified": true, "country_code": "JP"}
    """

    private static func room(_ extra: String = "") -> String {
        """
        {"id": "11111111-0000-4000-8000-000000000001",
         "title": "What verification actually changes",
         "topic": "technology",
         "scope": "international",
         "scope_country": null,
         "scope_region": null,
         "status": "live",
         "host": \(host),
         "speaker_count": 3,
         "listener_count": 41,
         "scheduled_for": null,
         "started_at": "2026-08-31T09:00:00Z",
         "created_at": "2026-08-31T08:58:00Z",
         "can_speak": true,
         "speak_refusal": null,
         "is_host": false,
         "is_removed": false\(extra)}
        """
    }

    // MARK: - RoomOut

    func testARoomOutDecodesEveryFieldTheContractNames() throws {
        let room = try decode(VoiceRoom.self, Self.room())

        XCTAssertEqual(room.id, UUID(uuidString: "11111111-0000-4000-8000-000000000001"))
        XCTAssertEqual(room.title, "What verification actually changes")
        XCTAssertEqual(room.topic, "technology")
        XCTAssertEqual(room.scope, .international)
        XCTAssertNil(room.scopeCountry)
        XCTAssertNil(room.scopeRegion)
        XCTAssertEqual(room.status, .live)
        XCTAssertEqual(room.host.handle, "yuki")
        XCTAssertEqual(room.speakerCount, 3)
        XCTAssertEqual(room.listenerCount, 41)
        XCTAssertNil(room.scheduledFor)
        XCTAssertNotNil(room.startedAt)
        XCTAssertTrue(room.canSpeak)
        XCTAssertNil(room.speakRefusal)
        XCTAssertFalse(room.isHost)
        XCTAssertFalse(room.isRemoved)
    }

    func testACountryRoomKeepsItsScopeTriple() throws {
        let json = """
        {"id": "11111111-0000-4000-8000-000000000009", "title": "Riyadh morning",
         "topic": "culture", "scope": "country", "scope_country": "sa",
         "status": "live", "host": \(Self.host), "speaker_count": 5,
         "listener_count": 112, "created_at": "2026-08-31T08:00:00Z",
         "can_speak": false,
         "speak_refusal": "Only 🇸🇦 Saudi Arabia-verified accounts can speak in this room. You can still listen.",
         "is_host": false, "is_removed": false}
        """
        let room = try decode(VoiceRoom.self, json)

        XCTAssertEqual(room.scope, .country)
        // Normalised the way every other country code in the app is, so a
        // lower-cased server value still finds a flag.
        XCTAssertEqual(room.scopeCountry, "SA")
        XCTAssertFalse(room.canSpeak)
        XCTAssertEqual(
            room.speakRefusal,
            "Only 🇸🇦 Saudi Arabia-verified accounts can speak in this room. You can still listen."
        )
    }

    /// The refusal is the server's sentence and the client shows it as sent.
    /// A client that paraphrased would be re-deriving a rule it does not own.
    func testTheSpeakRefusalIsRenderedVerbatim() throws {
        let sentence = "Only accounts verified in Antarctica can speak here. You can still listen."
        let json = """
        {"id": "11111111-0000-4000-8000-00000000000a", "title": "Ice", "scope": "country",
         "scope_country": "AQ", "status": "live", "host": \(Self.host),
         "created_at": "2026-08-31T08:00:00Z", "can_speak": false,
         "speak_refusal": "\(sentence)", "is_host": false, "is_removed": false}
        """
        let room = try decode(VoiceRoom.self, json)
        XCTAssertEqual(room.speakRefusalMessage, sentence)
    }

    /// A scope this build has never heard of must still produce a usable room
    /// and the server's refusal — not a crash and not a guess.
    func testAnUnknownScopeFallsBackToInternationalWithoutLosingTheRefusal() throws {
        let json = """
        {"id": "11111111-0000-4000-8000-00000000000b", "title": "Future scope",
         "scope": "continent", "status": "live", "host": \(Self.host),
         "created_at": "2026-08-31T08:00:00Z", "can_speak": false,
         "speak_refusal": "Only accounts verified in Africa can speak here.",
         "is_host": false, "is_removed": false}
        """
        let room = try decode(VoiceRoom.self, json)
        XCTAssertEqual(room.scope, .international)
        XCTAssertEqual(room.speakRefusalMessage, "Only accounts verified in Africa can speak here.")
    }

    /// `can_speak` fails **closed**. A missing field must not hand somebody a
    /// microphone the media server will mute.
    func testAMissingCanSpeakIsReadAsNo() throws {
        let json = """
        {"id": "11111111-0000-4000-8000-00000000000c", "title": "No flag",
         "scope": "international", "status": "live", "host": \(Self.host),
         "created_at": "2026-08-31T08:00:00Z", "is_host": false, "is_removed": false}
        """
        let room = try decode(VoiceRoom.self, json)
        XCTAssertFalse(room.canSpeak)
        XCTAssertFalse(room.isSpeakable)
        XCTAssertEqual(room.speakRefusalMessage, RoomCopy.speakRefusalFallback)
    }

    func testAnUnknownStatusIsNeverTreatedAsLive() throws {
        let json = """
        {"id": "11111111-0000-4000-8000-00000000000d", "title": "Odd", "scope": "international",
         "status": "paused", "host": \(Self.host), "created_at": "2026-08-31T08:00:00Z",
         "can_speak": true, "is_host": false, "is_removed": false}
        """
        let room = try decode(VoiceRoom.self, json)
        XCTAssertEqual(room.status, .unknown)
        XCTAssertFalse(room.status.isJoinable)
        XCTAssertFalse(room.isSpeakable, "a room this build cannot describe offered a microphone")
    }

    /// One unreadable row must cost that row, not the whole page.
    func testOneMalformedRoomDoesNotEmptyTheList() throws {
        let json = """
        {"rooms": [
            \(Self.room()),
            {"id": "bad", "title": "", "status": "live"},
            {"id": "11111111-0000-4000-8000-000000000002", "title": "Second",
             "scope": "international", "status": "live", "host": \(Self.host),
             "created_at": "2026-08-31T08:00:00Z", "can_speak": true,
             "is_host": false, "is_removed": false}
        ]}
        """
        let list = try decode(VoiceRoomList.self, json)
        XCTAssertEqual(list.rooms.count, 2, "a bad row took the good ones with it")
        XCTAssertEqual(list.rooms.map(\.title), ["What verification actually changes", "Second"])
    }

    // MARK: - Role, and the token it came with

    /// **The whole enforcement model, in one assertion.** A listener's token
    /// carries `canPublish: false`, so the mic affordance must be gated on the
    /// role and nothing else.
    func testOnlyHostsAndSpeakersMayPublish() {
        XCTAssertTrue(RoomRole.host.canPublish)
        XCTAssertTrue(RoomRole.speaker.canPublish)
        XCTAssertFalse(RoomRole.listener.canPublish)
    }

    /// An unrecognised role fails closed. Reading a future `"moderator"` as a
    /// speaker would light a microphone on a token that may not permit one.
    func testAnUnknownRoleDecodesAsListener() throws {
        let role = try decode(RoomRole.self, "\"moderator\"")
        XCTAssertEqual(role, .listener)
        XCTAssertFalse(role.canPublish)
    }

    func testAJoinCarriesTheUrlTheTokenAndTheRole() throws {
        let json = """
        {"room": \(Self.room()), "url": "wss://sila.gmai.sa/rtc",
         "token": "eyJhbGciOi.payload.sig", "role": "listener"}
        """
        let join = try decode(RoomJoin.self, json)
        XCTAssertEqual(join.url, "wss://sila.gmai.sa/rtc")
        XCTAssertEqual(join.token, "eyJhbGciOi.payload.sig")
        XCTAssertEqual(join.role, .listener)
        XCTAssertFalse(join.canPublish)
    }

    /// A join with no token is not a join. Decoding one tolerantly would put a
    /// room screen on the display with silence behind it.
    func testAJoinWithoutATokenIsRefused() {
        let json = """
        {"room": \(Self.room()), "url": "wss://sila.gmai.sa/rtc", "role": "speaker"}
        """
        XCTAssertThrowsError(try decode(RoomJoin.self, json))
    }

    // MARK: - Participants

    func testParticipantsSplitIntoStageAndAudienceWithTheHostFirst() throws {
        let json = """
        {"participants": [
            {"role": "listener", "user": {"id": "33333333-0000-4000-8000-000000000003",
              "handle": "zed", "display_name": "Zed", "is_verified": true}},
            {"role": "speaker", "user": {"id": "44444444-0000-4000-8000-000000000004",
              "handle": "amy", "display_name": "Amy", "is_verified": true}},
            {"role": "host", "user": \(Self.host), "joined_at": "2026-08-31T09:00:00Z"}
        ]}
        """
        let list = try decode(RoomParticipantList.self, json)
        XCTAssertEqual(list.stage.map(\.user.handle), ["yuki", "amy"])
        XCTAssertEqual(list.audience.map(\.user.handle), ["zed"])
    }

    // MARK: - Presentation

    /// A room's scope chip says *speak*, because that is what it governs. The
    /// post version of the same chip says *reply*, and both come from one
    /// implementation.
    func testTheScopeChipSaysSpeakForARoomAndReplyForAPost() throws {
        let room = try decode(VoiceRoom.self, Self.room())
        XCTAssertEqual(room.scopePresentation.label, "International")
        XCTAssertTrue(
            room.scopePresentation.accessibilityLabel.contains("speak"),
            "a room's scope chip described replying"
        )

        let post = ScopePresentation.make(scope: .international, country: nil, region: nil)
        XCTAssertTrue(post.accessibilityLabel.contains("reply"))
    }

    // MARK: - The four copy rules

    /// **Removal is not a block, and the copy denies it in so many words.**
    ///
    /// The denial is explicit rather than implied. Somebody who has just been
    /// taken out of a conversation will assume the worst about what else has
    /// happened to their account, and "it isn't a block" is the only sentence
    /// that answers that.
    func testRemovalCopySaysItIsPerRoomAndExplicitlyNotABlock() {
        let sentence = RoomCopy.removedFromRoom.lowercased()
        XCTAssertTrue(sentence.contains("this room"), "removal copy did not scope itself to one room")
        XCTAssertTrue(
            sentence.contains("isn't a block"),
            "removal copy did not say, in words, that it is not a block"
        )
        XCTAssertTrue(
            sentence.contains("other room"),
            "removal copy did not say other rooms are still open"
        )
        XCTAssertTrue(
            sentence.contains("nothing about your account has changed"),
            "removal copy did not say the account is untouched"
        )
    }

    /// The removal message is a *different sentence* from the block one, which
    /// is the point: they describe different things, and a client that reused
    /// one for the other would be telling somebody they had been punished far
    /// more broadly than they had.
    func testRemovedFromRoomAndBlockedProduceDifferentMessages() {
        let removed = APIError.api(code: .removedFromRoom, message: "", status: 403).userMessage
        let blocked = APIError.api(code: .blocked, message: "", status: 403).userMessage
        XCTAssertNotEqual(removed, blocked)
        XCTAssertEqual(removed, RoomCopy.removedFromRoom)
        // The block message says a block exists between two accounts. The
        // removal message must not claim anything of the sort.
        XCTAssertTrue(blocked.lowercased().contains("there's a block between"))
        XCTAssertFalse(removed.lowercased().contains("block between"))
        XCTAssertFalse(removed.lowercased().contains("you've been blocked"))
    }

    /// **Rooms are never recorded, and the copy says so unconditionally** — no
    /// "unless", no "may", nothing that leaves room for a recording to exist.
    func testTheNotRecordedPromiseIsUnconditional() {
        let promise = RoomCopy.neverRecorded.lowercased()
        XCTAssertTrue(promise.contains("never recorded"))
        XCTAssertFalse(promise.contains("unless"))
        XCTAssertFalse(promise.contains("may be"))
    }

    /// A listener is told that no microphone is involved, rather than being
    /// apologised to for not having one.
    func testTheListeningCopySaysNoMicrophoneIsInUse() {
        XCTAssertTrue(RoomCopy.listeningSubtitle.lowercased().contains("microphone is not in use"))
        XCTAssertTrue(RoomCopy.listeningSubtitle.lowercased().contains("hasn't asked"))
    }

    /// Scope refusals are about speaking. A refusal that mentioned listening as
    /// blocked would be describing a product Sila is not.
    func testTheScopeRefusalSaysListeningIsStillAllowed() {
        let message = APIError.api(code: .scopeNotAllowed, message: "", status: 403).userMessage
        XCTAssertTrue(message.lowercased().contains("can listen"))
        XCTAssertTrue(message.lowercased().contains("can't speak"))
    }

    func testAttendanceReadsAsASentenceAtEveryCount() {
        XCTAssertEqual(RoomCopy.attendance(speakers: 1, listeners: 1), "1 speaking · 1 listening")
        XCTAssertEqual(RoomCopy.attendance(speakers: 0, listeners: 0), "0 speaking · 0 listening")
        XCTAssertEqual(RoomCopy.attendance(speakers: 3, listeners: 41), "3 speaking · 41 listening")
    }
}
