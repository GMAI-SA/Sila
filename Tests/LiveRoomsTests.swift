import XCTest
@testable import Sila

/// Drives the deployed rooms API through the app's own decoders.
///
/// The fixture tests agree with the contract by construction; these are the
/// only ones that would notice the server disagreeing. That matters more here
/// than almost anywhere else, because the two facts this feature turns on —
/// `can_speak` and the role a join's token grants — are computed server-side
/// and are unverifiable from a fixture.
///
/// **Cleanup is mandatory, not best-effort.** These tests may create rooms, and
/// a room left live is a live conversation on a production list with nobody in
/// it. ``tearDown()`` ends every room this suite opened and leaves every room it
/// joined, and it does both even when the test that created one failed.
///
/// **What is deliberately not exercised:** removing somebody. A removal needs a
/// second real account to remove, and provoking one against a seeded demo
/// account leaves a per-room ban that no endpoint in this contract can lift.
/// The refusals are covered instead, because they create nothing.
///
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LiveRoomsTests: XCTestCase {

    private var token: String?
    /// The signed-in account's own handle.
    private var myHandle = ""
    /// Whether the account carries a verified country, which decides whether
    /// the country-scope test can run at all.
    private var myCountry: String?
    /// Rooms this suite opened. **Every one of them is ended in tearDown.**
    private var createdRoomIds: [UUID] = []
    /// Rooms this suite joined, ended by us or not.
    private var joinedRoomIds: Set<UUID> = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"], let password = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        token = try await auth.signIn(email: email, password: password).token.accessToken
        let me = try await auth.currentUser()
        myHandle = try XCTUnwrap(me.handle, "the live account has no handle")
        myCountry = me.countryCode
    }

    /// Ends every room this suite opened and leaves every room it entered.
    ///
    /// Runs whatever happened above, and swallows its own failures: a cleanup
    /// that threw would mask the assertion that actually failed, and the next
    /// call in the loop still has to run.
    override func tearDown() async throws {
        defer {
            createdRoomIds = []
            joinedRoomIds = []
        }
        guard let token, !token.isEmpty else { return }
        let service = RoomsService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
        // Leave first: a room ended out from under an open participant row is
        // a row the server has to clean up on a timeout.
        for id in joinedRoomIds {
            try? await service.leave(roomId: id)
        }
        for id in createdRoomIds {
            _ = try? await service.endRoom(id: id)
        }
        // And prove it, so a silent failure to clean up is a failed test rather
        // than a live room nobody knows about.
        for id in createdRoomIds {
            if let room = try? await service.fetchRoom(id: id) {
                XCTAssertNotEqual(
                    room.status, .live,
                    "a room this test created is still live: \(id)"
                )
            }
        }
    }

    private func service() throws -> RoomsService {
        RoomsService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    /// Opens a room and registers it for teardown **before** returning it, so a
    /// failure between here and the assertion still gets cleaned up.
    private func openRoom(
        title: String = "Sila iOS test room",
        topic: String? = nil,
        scope: ComposeScope = .international,
        scheduledFor: Date? = nil
    ) async throws -> VoiceRoom {
        let room = try await service().createRoom(
            CreateRoomRequest(title: title, topic: topic, scope: scope, scheduledFor: scheduledFor)
        )
        createdRoomIds.append(room.id)
        return room
    }

    // MARK: - Listing

    /// Every room on the list decodes, and the two permission fields the whole
    /// feature turns on are present on each one.
    func testTheLiveListDecodesAndCarriesThePermissionFields() async throws {
        let rooms = try await service().fetchRooms(status: .live, topic: nil, limit: 30)

        for room in rooms {
            XCTAssertFalse(room.title.isEmpty)
            XCTAssertFalse(room.host.handle.isEmpty)
            XCTAssertEqual(room.status, .live)
            // `can_speak` is the server's, and when it says no there has to be
            // a sentence to render — the client never invents one for a room
            // whose scope it could not otherwise explain.
            if !room.canSpeak {
                XCTAssertNotNil(
                    room.speakRefusalMessage,
                    "\(room.id) refuses speaking with nothing to show the user"
                )
            }
        }
    }

    func testTheScheduledListOnlyContainsScheduledRooms() async throws {
        let rooms = try await service().fetchRooms(status: .scheduled, topic: nil, limit: 30)
        XCTAssertTrue(rooms.allSatisfy { $0.status == .scheduled })
    }

    // MARK: - Creating, joining, ending

    /// The round trip: open a room, be its host, get a publishing token, leave,
    /// end it.
    func testOpeningARoomMakesYouItsHostWithAPublishingToken() async throws {
        let room = try await openRoom(title: "Sila iOS test room \(UUID().uuidString.prefix(8))")

        XCTAssertTrue(room.isHost, "the account that opened the room is not its host")
        XCTAssertTrue(room.canSpeak, "a host cannot speak in their own room")
        XCTAssertEqual(room.status, .live)

        let service = try service()
        let join = try await service.join(roomId: room.id)
        joinedRoomIds.insert(room.id)

        XCTAssertEqual(join.role, .host)
        XCTAssertTrue(join.canPublish)
        XCTAssertFalse(join.token.isEmpty, "the join carried no media token")
        XCTAssertTrue(
            join.url.hasPrefix("wss://"),
            "the media URL is not a websocket URL: \(join.url)"
        )

        let participants = try await service.fetchParticipants(roomId: room.id)
        let stageHandles = participants.stage.map(\.user.handle)
        XCTAssertTrue(stageHandles.contains(myHandle), "the host is not on their own stage")

        try await service.leave(roomId: room.id)
        joinedRoomIds.remove(room.id)

        let ended = try await service.endRoom(id: room.id)
        XCTAssertEqual(ended.status, .ended)
    }

    /// **A room that has ended cannot be rejoined**, and the refusal is
    /// `room_ended` rather than a generic 404 or a silent empty join.
    func testJoiningAnEndedRoomIsRefusedWithRoomEnded() async throws {
        let room = try await openRoom(title: "Sila iOS ended-room test \(UUID().uuidString.prefix(8))")
        let service = try service()
        _ = try await service.endRoom(id: room.id)

        do {
            _ = try await service.join(roomId: room.id)
            XCTFail("an ended room accepted a join")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .roomEnded)
            // And the sentence the user sees says nothing was kept, which is
            // the fact that makes an ended room final rather than merely closed.
            XCTAssertEqual(error.userMessage, RoomCopy.roomEnded)
        }
    }

    /// A scheduled room is on the list and is not live.
    func testAScheduledRoomIsCreatedScheduledRatherThanLive() async throws {
        let start = Date().addingTimeInterval(60 * 60)
        let room = try await openRoom(
            title: "Sila iOS scheduled test \(UUID().uuidString.prefix(8))",
            scheduledFor: start
        )

        XCTAssertEqual(room.status, .scheduled)
        XCTAssertNotNil(room.scheduledFor)
        XCTAssertFalse(room.status.isJoinable)
    }

    /// A topic the taxonomy does not contain is rejected outright, so a client
    /// that hard-coded a stale list would fail loudly rather than quietly file
    /// rooms under nothing.
    func testAnUnknownTopicIsRefused() async throws {
        do {
            let room = try await openRoom(
                title: "Sila iOS bad-topic test",
                topic: "definitely_not_a_topic"
            )
            // If the server accepted it, clean it up and say so.
            createdRoomIds.append(room.id)
            XCTFail("the server accepted a topic outside its taxonomy")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .unknownTopic)
        }
    }

    /// **You may only open a country room for your own verified country.** The
    /// same rule as a country thread, enforced by the same server.
    func testACountryRoomForSomebodyElsesCountryIsRefused() async throws {
        // Pick a country that is definitely not this account's.
        let foreign = (myCountry == "AQ") ? "SA" : "AQ"
        do {
            let room = try await openRoom(
                title: "Sila iOS foreign-scope test",
                scope: .country(foreign)
            )
            createdRoomIds.append(room.id)
            XCTFail("the server opened a country room for a country the account is not verified in")
        } catch let error as APIError {
            XCTAssertTrue(
                [.invalidScope, .scopeNotAllowed].contains(error.code),
                "unexpected refusal: \(String(describing: error.code))"
            )
        }
    }

    // MARK: - Host-only refusals (safe: they create nothing)

    /// Every stage call is host-only, and a non-host gets told so rather than
    /// silently succeeding.
    func testTheStageCallsAreRefusedOnSomebodyElsesRoom() async throws {
        let service = try service()
        let rooms = try await service.fetchRooms(status: .live, topic: nil, limit: 30)
        guard let foreign = rooms.first(where: { !$0.isHost }) else {
            throw XCTSkip("no room hosted by somebody else is live right now")
        }

        for call in ["promote", "demote", "remove"] {
            do {
                switch call {
                case "promote": _ = try await service.promote(roomId: foreign.id, handle: myHandle)
                case "demote": _ = try await service.demote(roomId: foreign.id, handle: myHandle)
                default: _ = try await service.remove(roomId: foreign.id, handle: myHandle)
                }
                XCTFail("\(call) succeeded on a room this account does not host")
            } catch let error as APIError {
                XCTAssertEqual(error.code, .notRoomHost, "\(call) failed for the wrong reason")
            }
        }
    }

    /// A host cannot step off their own stage, and the refusal has its own code
    /// rather than being a generic 400.
    func testAHostCannotDemoteThemselves() async throws {
        let room = try await openRoom(title: "Sila iOS demote-host test \(UUID().uuidString.prefix(8))")
        let service = try service()
        _ = try await service.join(roomId: room.id)
        joinedRoomIds.insert(room.id)

        do {
            _ = try await service.demote(roomId: room.id, handle: myHandle)
            XCTFail("a host was moved off their own stage")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .cannotDemoteHost)
            XCTAssertEqual(error.userMessage, RoomCopy.cannotDemoteHost)
        }
    }

    // MARK: - Search

    /// A room this test just opened is findable by its own title, which is what
    /// `/search/rooms` is for.
    func testSearchFindsARoomByItsTitle() async throws {
        let marker = String(UUID().uuidString.prefix(8)).lowercased()
        let room = try await openRoom(title: "Sila iOS search \(marker)")

        let service = try service()
        let results = try await service.searchRooms(query: marker, limit: 20)

        // Bound first: an autoclosure cannot hold an `await`.
        let containsRoom = results.contains { $0.id == room.id }
        XCTAssertTrue(containsRoom, "a live room was not findable by a word in its title")
    }

    /// A one-character query never leaves the device.
    func testAShortQueryIsAnsweredWithoutARequest() async throws {
        let results = try await service().searchRooms(query: "a", limit: 20)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Not found

    func testAnUnknownRoomIdIsNotFound() async throws {
        do {
            _ = try await service().fetchRoom(id: UUID())
            XCTFail("an invented room id resolved to a room")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .notFound)
        }
    }
}
