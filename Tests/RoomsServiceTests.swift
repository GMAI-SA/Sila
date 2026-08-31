import XCTest
@testable import Sila

/// ``RoomsService`` against a scripted transport: paths, verbs, query and the
/// body of the three host-only calls.
final class RoomsServiceTests: XCTestCase {

    private func makeService(
        _ network: StubNetworkClient,
        token: String? = "access-123"
    ) -> RoomsService {
        RoomsService(
            network: network,
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let roomId = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!

    private static let room = """
    {"id": "11111111-0000-4000-8000-000000000001", "title": "A room",
     "topic": "technology", "scope": "international", "status": "live",
     "host": {"id": "22222222-0000-4000-8000-000000000002", "handle": "yuki",
              "display_name": "Yuki", "is_verified": true},
     "speaker_count": 2, "listener_count": 7, "created_at": "2026-08-31T08:00:00Z",
     "can_speak": true, "is_host": false, "is_removed": false}
    """

    private static var list: String { #"{"rooms": ["# + room + "]}" }
    private static var join: String {
        #"{"room": "# + room + #", "url": "wss://sila.gmai.sa/rtc", "token": "tok", "role": "speaker"}"#
    }

    // MARK: - Paths and verbs

    func testEveryEndpointUsesTheDocumentedPathAndVerb() async throws {
        let network = StubNetworkClient(responses: [
            Self.room, Self.list, Self.room, Self.join, "{}",
            Self.room, Self.room, Self.room, Self.room,
            #"{"participants": []}"#, Self.list
        ])
        let service = makeService(network)

        _ = try await service.createRoom(CreateRoomRequest(title: "A room", scope: .international))
        _ = try await service.fetchRooms(status: .live, topic: nil, limit: 30)
        _ = try await service.fetchRoom(id: Self.roomId)
        _ = try await service.join(roomId: Self.roomId)
        try await service.leave(roomId: Self.roomId)
        _ = try await service.endRoom(id: Self.roomId)
        _ = try await service.promote(roomId: Self.roomId, handle: "amy")
        _ = try await service.demote(roomId: Self.roomId, handle: "amy")
        _ = try await service.remove(roomId: Self.roomId, handle: "amy")
        _ = try await service.fetchParticipants(roomId: Self.roomId)
        _ = try await service.searchRooms(query: "verification", limit: 20)

        let id = Self.roomId.uuidString.lowercased()
        XCTAssertEqual(network.requests.map { "\($0.method.rawValue) \($0.path)" }, [
            "POST /rooms",
            "GET /rooms",
            "GET /rooms/\(id)",
            "POST /rooms/\(id)/join",
            "POST /rooms/\(id)/leave",
            "POST /rooms/\(id)/end",
            "POST /rooms/\(id)/speakers",
            "DELETE /rooms/\(id)/speakers/amy",
            "POST /rooms/\(id)/remove",
            "GET /rooms/\(id)/participants",
            "GET /search/rooms"
        ])
        XCTAssertTrue(network.requests.allSatisfy { $0.accessToken == "access-123" })
    }

    // MARK: - Query

    func testTheStatusFilterIsSentOnlyWhenItNarrowsSomething() async throws {
        let network = StubNetworkClient(responses: [Self.list])
        let service = makeService(network)

        _ = try await service.fetchRooms(status: nil, topic: nil, limit: 30)
        _ = try await service.fetchRooms(status: .live, topic: nil, limit: 30)
        // A status this build cannot name has no wire value, so it must not be
        // spelled out as a word the server would answer 422 to.
        _ = try await service.fetchRooms(status: .unknown, topic: nil, limit: 30)

        XCTAssertNil(network.requests[0].queryValue("status"))
        XCTAssertEqual(network.requests[1].queryValue("status"), "live")
        XCTAssertNil(network.requests[2].queryValue("status"))
    }

    func testTheTopicFilterIsSentOnlyWhenItIsSomething() async throws {
        let network = StubNetworkClient(responses: [Self.list])
        let service = makeService(network)

        _ = try await service.fetchRooms(status: nil, topic: "", limit: 30)
        _ = try await service.fetchRooms(status: nil, topic: "science", limit: 30)

        XCTAssertNil(network.requests[0].queryValue("topic"))
        XCTAssertEqual(network.requests[1].queryValue("topic"), "science")
    }

    func testTheLimitIsClampedToWhatTheServerAccepts() async throws {
        let network = StubNetworkClient(responses: [Self.list])
        let service = makeService(network)

        _ = try await service.fetchRooms(status: nil, topic: nil, limit: 999)
        _ = try await service.fetchRooms(status: nil, topic: nil, limit: 0)

        XCTAssertEqual(network.requests[0].queryValue("limit"), "50")
        XCTAssertEqual(network.requests[1].queryValue("limit"), "1")
    }

    /// A one-character query is answered with nothing by the server. Spending a
    /// round trip to be told that makes every second keystroke a wasted request.
    func testAShortSearchNeverReachesTheNetwork() async throws {
        let network = StubNetworkClient(responses: [Self.list])
        let service = makeService(network)

        let results = try await service.searchRooms(query: "a", limit: 20)

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(network.requests.isEmpty, "a one-character query hit the server")
    }

    func testSearchTrimsTheQueryBeforeSending() async throws {
        let network = StubNetworkClient(responses: [Self.list])
        let service = makeService(network)

        _ = try await service.searchRooms(query: "  verification  ", limit: 20)

        XCTAssertEqual(network.requests.first?.queryValue("q"), "verification")
    }

    // MARK: - Bodies

    /// The three stage calls all identify somebody by handle, and the handle is
    /// normalised the way the server matches it — no `@`, lower case.
    func testTheStageCallsNormaliseTheHandle() async throws {
        let network = StubNetworkClient(responses: [Self.room, Self.room, Self.room])
        let service = makeService(network)

        _ = try await service.promote(roomId: Self.roomId, handle: "@Amy")
        _ = try await service.demote(roomId: Self.roomId, handle: "@Amy")
        _ = try await service.remove(roomId: Self.roomId, handle: "@Amy")

        let promote = try XCTUnwrap(network.requests[0].body)
        XCTAssertEqual(String(data: promote, encoding: .utf8), #"{"handle":"amy"}"#)
        XCTAssertEqual(network.requests[1].path, "/rooms/\(Self.roomId.uuidString.lowercased())/speakers/amy")
        let remove = try XCTUnwrap(network.requests[2].body)
        XCTAssertEqual(String(data: remove, encoding: .utf8), #"{"handle":"amy"}"#)
    }

    /// `scheduled_for` and the scope's optional halves are **omitted** when
    /// they carry nothing, rather than sent as `null`. The contract reads an
    /// absent `scheduled_for` as "start now".
    func testCreateOmitsTheFieldsThatCarryNothing() async throws {
        let network = StubNetworkClient(responses: [Self.room])
        let service = makeService(network)

        _ = try await service.createRoom(
            CreateRoomRequest(title: "  Open now  ", topic: nil, scope: .international)
        )

        let body = try XCTUnwrap(network.requests.first?.body)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains(#""title":"Open now""#), "the title was not trimmed")
        XCTAssertTrue(json.contains(#""scope":"international""#))
        XCTAssertFalse(json.contains("scheduled_for"))
        XCTAssertFalse(json.contains("scope_country"))
        XCTAssertFalse(json.contains("scope_region"))
        XCTAssertFalse(json.contains("null"))
    }

    func testCreateSendsTheScopeTripleForACountryRoom() async throws {
        let network = StubNetworkClient(responses: [Self.room])
        let service = makeService(network)

        _ = try await service.createRoom(
            CreateRoomRequest(title: "Riyadh", topic: "culture", scope: .country("sa"))
        )

        let json = try XCTUnwrap(String(data: XCTUnwrap(network.requests.first?.body), encoding: .utf8))
        XCTAssertTrue(json.contains(#""scope":"country""#))
        XCTAssertTrue(json.contains(#""scope_country":"SA""#))
        XCTAssertTrue(json.contains(#""topic":"culture""#))
    }

    func testCreateSendsTheRegionForARegionalRoom() async throws {
        let network = StubNetworkClient(responses: [Self.room])
        let service = makeService(network)

        _ = try await service.createRoom(
            CreateRoomRequest(title: "Gulf founders", scope: .region(.gcc), maxSpeakers: 12)
        )

        let json = try XCTUnwrap(String(data: XCTUnwrap(network.requests.first?.body), encoding: .utf8))
        XCTAssertTrue(json.contains(#""scope":"region""#))
        XCTAssertTrue(json.contains(#""scope_region":"GCC""#))
        XCTAssertTrue(json.contains(#""max_speakers":12"#))
    }

    // MARK: - Errors

    /// The join refusals arrive as codes, and each keeps its own identity all
    /// the way through the service.
    func testJoinRefusalsSurviveAsTheirOwnCodes() async throws {
        for code in [APIErrorCode.removedFromRoom, .roomEnded, .notFound] {
            let network = StubNetworkClient(
                error: .api(code: code, message: "refused", status: 403)
            )
            do {
                _ = try await makeService(network).join(roomId: Self.roomId)
                XCTFail("the service swallowed \(code.rawValue)")
            } catch let error as APIError {
                XCTAssertEqual(error.code, code)
            }
        }
    }

    /// No token, no request. Rooms are an authenticated surface all the way
    /// down — there is no anonymous listening.
    func testEveryCallNeedsASession() async throws {
        let network = StubNetworkClient(responses: [Self.list])
        let service = makeService(network, token: nil)

        do {
            _ = try await service.fetchRooms(status: .live, topic: nil, limit: 30)
            XCTFail("a signed-out caller reached the network")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthenticated)
        }
        XCTAssertTrue(network.requests.isEmpty)
    }
}
