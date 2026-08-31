import XCTest
@testable import Sila

/// ``NotificationsService`` against a scripted transport: paths, verbs,
/// cursors, and the difference between "mark these" and "mark everything".
final class NotificationsServiceTests: XCTestCase {

    private func makeService(
        _ network: StubNetworkClient,
        token: String? = "access-123"
    ) -> NotificationsService {
        NotificationsService(
            network: network,
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let page = """
    {"notifications": [
        {"id": "11111111-0000-4000-8000-000000000001", "kind": "like",
         "actor": {"id": "22222222-0000-4000-8000-000000000002", "handle": "noura",
                   "display_name": "Noura", "is_verified": true, "country_code": "SA"},
         "post_id": "33333333-0000-4000-8000-000000000003",
         "post_excerpt": "Hello", "read": false, "created_at": "2026-08-30T12:00:00Z"}],
     "next_cursor": "opaque-1", "unread_count": 2}
    """

    private static let readResult = #"{"marked_read": 2, "unread": 0}"#

    // MARK: - Paths and verbs

    func testEveryEndpointUsesTheDocumentedPathAndVerb() async throws {
        let network = StubNetworkClient(responses: [
            Self.page,
            #"{"unread": 2}"#,
            Self.readResult,
            Self.readResult
        ])
        let service = makeService(network)

        _ = try await service.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        _ = try await service.fetchUnreadCount()
        _ = try await service.markRead(ids: [UUID()])
        _ = try await service.markAllRead()

        XCTAssertEqual(network.requests.map { "\($0.method.rawValue) \($0.path)" }, [
            "GET /notifications",
            "GET /notifications/unread-count",
            "POST /notifications/read",
            "POST /notifications/read"
        ])
        XCTAssertTrue(network.requests.allSatisfy { $0.accessToken == "access-123" })
    }

    // MARK: - Query

    /// The server answers 422 outside 1…50 rather than clamping, and an
    /// unreadable FastAPI validation body is not an error worth showing.
    func testTheLimitIsClampedToWhatTheServerAccepts() async throws {
        let network = StubNetworkClient(responses: [Self.page])
        let service = makeService(network)

        _ = try await service.fetchNotifications(cursor: nil, limit: 999, unreadOnly: false)
        _ = try await service.fetchNotifications(cursor: nil, limit: 0, unreadOnly: false)

        XCTAssertEqual(network.requests.first?.queryValue("limit"), "50")
        XCTAssertEqual(network.requests.last?.queryValue("limit"), "1")
    }

    func testTheCursorIsSentOnlyWhenTheServerGaveUsOne() async throws {
        let network = StubNetworkClient(responses: [Self.page])
        let service = makeService(network)

        _ = try await service.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        _ = try await service.fetchNotifications(cursor: "", limit: 20, unreadOnly: false)
        _ = try await service.fetchNotifications(cursor: "opaque-1", limit: 20, unreadOnly: false)

        XCTAssertNil(network.requests[0].queryValue("cursor"))
        XCTAssertNil(network.requests[1].queryValue("cursor"), "an empty cursor became a parameter")
        XCTAssertEqual(network.requests[2].queryValue("cursor"), "opaque-1")
    }

    func testUnreadOnlyIsSentOnlyWhenItNarrowsSomething() async throws {
        let network = StubNetworkClient(responses: [Self.page])
        let service = makeService(network)

        _ = try await service.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        _ = try await service.fetchNotifications(cursor: nil, limit: 20, unreadOnly: true)

        XCTAssertNil(network.requests[0].queryValue("unread_only"))
        XCTAssertEqual(network.requests[1].queryValue("unread_only"), "true")
    }

    // MARK: - Marking read

    /// "Mark everything" is an empty JSON object, not a missing body. The
    /// contract distinguishes them.
    func testMarkAllReadSendsAnEmptyObject() async throws {
        let network = StubNetworkClient(responses: [Self.readResult])

        _ = try await makeService(network).markAllRead()

        let body = try XCTUnwrap(network.lastRequest?.body)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{}")
    }

    func testMarkReadSendsTheIdsItWasGiven() async throws {
        let network = StubNetworkClient(responses: [Self.readResult])
        let first = try XCTUnwrap(UUID(uuidString: "11111111-0000-4000-8000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "44444444-0000-4000-8000-000000000004"))

        _ = try await makeService(network).markRead(ids: [first, second])

        let body = String(decoding: try XCTUnwrap(network.lastRequest?.body), as: UTF8.self)
        XCTAssertTrue(body.contains("11111111-0000-4000-8000-000000000001"), body)
        XCTAssertTrue(body.contains("44444444-0000-4000-8000-000000000004"), body)
        XCTAssertFalse(body.contains("1111111A"), "ids went out upper-cased")
        XCTAssertTrue(body.contains("\"ids\""), body)
    }

    /// An empty array must never reach `/notifications/read`. Whether the
    /// server would read `{"ids": []}` as "none" or fall through to "all" is
    /// not a question to answer on somebody's real unread state.
    func testAnEmptyIdListNeverBecomesAMarkEverythingCall() async throws {
        let network = StubNetworkClient(responses: [#"{"unread": 5}"#])

        let result = try await makeService(network).markRead(ids: [])

        XCTAssertEqual(result.markedRead, 0)
        XCTAssertEqual(result.unread, 5)
        XCTAssertEqual(network.requests.map(\.path), ["/notifications/unread-count"])
    }

    // MARK: - Decoding

    func testThePageIsDecodedWithTheServersUnreadCount() async throws {
        let network = StubNetworkClient(responses: [Self.page])

        let page = try await makeService(network).fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)

        XCTAssertEqual(page.notifications.count, 1)
        XCTAssertEqual(page.notifications.first?.kind, .like)
        XCTAssertEqual(page.unreadCount, 2)
        XCTAssertEqual(page.nextCursor, "opaque-1")
    }

    func testASignedOutCallerNeverReachesTheNetwork() async {
        let network = StubNetworkClient(responses: [Self.page])

        do {
            _ = try await makeService(network, token: nil)
                .fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
            XCTFail("a signed-out caller reached /notifications")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthenticated)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(network.requests.isEmpty)
    }

    // MARK: - The mock keeps the same contract

    /// The mock is what the previews and the `-mockNotifications` build run on,
    /// so its unread count has to behave the way the server's does: recomputed
    /// from what is stored, never a number the caller supplied.
    func testTheMockRecomputesUnreadAfterAWrite() async throws {
        let mock = NotificationsServiceMock(scenario: .populated)

        let before = try await mock.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        XCTAssertEqual(before.unreadCount, 3)

        let result = try await mock.markAllRead()
        XCTAssertEqual(result.markedRead, 3)
        XCTAssertEqual(result.unread, 0)

        let after = try await mock.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        XCTAssertEqual(after.unreadCount, 0)
        XCTAssertTrue(after.notifications.allSatisfy(\.read))
    }

    func testTheMockPagesWithACursor() async throws {
        let mock = NotificationsServiceMock(scenario: .paged)

        let first = try await mock.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        XCTAssertEqual(first.notifications.count, 20)
        let cursor = try XCTUnwrap(first.nextCursor)

        let second = try await mock.fetchNotifications(cursor: cursor, limit: 20, unreadOnly: false)
        XCTAssertEqual(second.notifications.count, 5)
        XCTAssertNil(second.nextCursor)
        XCTAssertTrue(
            Set(first.notifications.map(\.id)).isDisjoint(with: Set(second.notifications.map(\.id))),
            "the second page repeated the first"
        )
    }

    func testTheMockCarriesTheDeletedPostCase() async throws {
        let mock = NotificationsServiceMock(scenario: .populated)

        let page = try await mock.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)

        XCTAssertTrue(
            page.notifications.contains { $0.postWasDeleted },
            "the mocked world has no deleted-post row, so nobody can see that state"
        )
    }
}
