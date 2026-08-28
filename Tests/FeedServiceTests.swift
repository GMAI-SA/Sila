import XCTest
@testable import Sila

/// ``NetworkClient`` that records what was asked for and replays a script.
///
/// Lets the service's URL, verb, query and token construction be asserted
/// without a server, which is where cursor bugs actually live.
final class StubNetworkClient: NetworkClient, @unchecked Sendable {

    /// Requests seen so far, in order.
    private(set) var requests: [APIRequest] = []
    /// JSON bodies to return, consumed front to back. The last one repeats.
    var responses: [String] = []
    /// When set, every call throws this instead of decoding.
    var error: APIError?

    private let lock = NSLock()

    init(responses: [String] = [], error: APIError? = nil) {
        self.responses = responses
        self.error = error
    }

    func send<Response: Decodable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        let json = try record(request)
        do {
            return try JSONCoding.decoder.decode(Response.self, from: Data(json.utf8))
        } catch {
            throw APIError.decoding("Could not decode \(Response.self): \(error)")
        }
    }

    func send(_ request: APIRequest) async throws {
        _ = try record(request)
    }

    func sendData(_ request: APIRequest) async throws -> Data {
        Data(try record(request).utf8)
    }

    /// The most recent request, for one-shot assertions.
    var lastRequest: APIRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }

    private func record(_ request: APIRequest) throws -> String {
        lock.lock()
        requests.append(request)
        let response = responses.isEmpty ? "{}" : responses.removeFirst()
        let failure = error
        lock.unlock()
        if let failure { throw failure }
        return response
    }
}

extension APIRequest {
    /// The value of a query item, for assertions.
    func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }
}

/// ``FeedService`` against a scripted transport: paths, cursors, verbs, tokens.
final class FeedServiceTests: XCTestCase {

    private func makeService(
        _ network: StubNetworkClient,
        token: String? = "access-123"
    ) -> FeedService {
        FeedService(
            network: network,
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let emptyPage = """
    { "posts": [], "next_cursor": null, "has_more": false }
    """

    private static let pageWithCursor = """
    { "posts": [], "next_cursor": "cursor-2", "has_more": true }
    """

    // MARK: Paths

    func testEachTabHitsItsDocumentedPath() async throws {
        let expected: [FeedTab: String] = [
            .forYou: "/feed/for-you",
            .following: "/feed/following",
            .myCountry: "/feed/country",
            .international: "/feed/international"
        ]

        for (tab, path) in expected {
            let network = StubNetworkClient(responses: [Self.emptyPage])
            _ = try await makeService(network).fetchFeed(tab, cursor: nil, limit: 20)
            XCTAssertEqual(network.lastRequest?.path, path, "\(tab) hit the wrong path")
            XCTAssertEqual(network.lastRequest?.method, .get)
        }
    }

    func testEveryFeedCallCarriesTheBearerToken() async throws {
        let network = StubNetworkClient(responses: [Self.emptyPage])
        _ = try await makeService(network, token: "abc").fetchFeed(.forYou, cursor: nil, limit: 20)

        XCTAssertEqual(network.lastRequest?.accessToken, "abc")
    }

    func testASignedOutCallerNeverReachesTheNetwork() async {
        let network = StubNetworkClient(responses: [Self.emptyPage])
        let service = makeService(network, token: nil)

        do {
            _ = try await service.fetchFeed(.forYou, cursor: nil, limit: 20)
            XCTFail("Expected the missing token to throw")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthenticated)
            XCTAssertTrue(network.requests.isEmpty, "No request should go out without credentials")
        }
    }

    // MARK: Cursors

    func testTheFirstPageSendsNoCursorParameter() async throws {
        let network = StubNetworkClient(responses: [Self.pageWithCursor])
        _ = try await makeService(network).fetchFeed(.forYou, cursor: nil, limit: 20)

        XCTAssertNil(network.lastRequest?.queryValue("cursor"))
        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "20")
    }

    func testTheNextPageEchoesTheServersOpaqueCursorVerbatim() async throws {
        let network = StubNetworkClient(responses: [Self.pageWithCursor, Self.emptyPage])
        let service = makeService(network)

        let first = try await service.fetchFeed(.forYou, cursor: nil, limit: 20)
        _ = try await service.fetchFeed(.forYou, cursor: first.nextCursor, limit: 20)

        XCTAssertEqual(first.nextCursor, "cursor-2")
        XCTAssertEqual(network.lastRequest?.queryValue("cursor"), "cursor-2")
    }

    func testAnEmptyCursorIsOmittedRatherThanSentAsBlank() async throws {
        let network = StubNetworkClient(responses: [Self.emptyPage])
        _ = try await makeService(network).fetchFeed(.forYou, cursor: "", limit: 20)

        XCTAssertNil(network.lastRequest?.queryValue("cursor"))
    }

    func testTheLimitIsClampedToTheContractsBounds() async throws {
        let network = StubNetworkClient(responses: [Self.emptyPage, Self.emptyPage])
        let service = makeService(network)

        _ = try await service.fetchFeed(.forYou, cursor: nil, limit: 500)
        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "50")

        _ = try await service.fetchFeed(.forYou, cursor: nil, limit: 0)
        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "1")
    }

    func testTheConvenienceOverloadUsesTheContractsDefaultPageSize() async throws {
        let network = StubNetworkClient(responses: [Self.emptyPage])
        _ = try await makeService(network).fetchFeed(.following)

        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "20")
    }

    // MARK: The no_country path

    func testTheCountryFeedSurfacesThe409AsAStructuredError() async {
        let network = StubNetworkClient(
            error: .api(code: .noCountry, message: "No verified country", status: 409)
        )
        let service = makeService(network)

        do {
            _ = try await service.fetchFeed(.myCountry, cursor: nil, limit: 20)
            XCTFail("Expected no_country")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, .noCountry)
        }
    }

    // MARK: Engagement

    func testLikeUsesPostAndUnlikeUsesDelete() async throws {
        let metrics = """
        { "likes": 5, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0 }
        """
        let network = StubNetworkClient(responses: [metrics, metrics])
        let service = makeService(network)
        let id = UUID()

        let liked = try await service.setLiked(true, postId: id)
        XCTAssertEqual(network.lastRequest?.method, .post)
        XCTAssertEqual(network.lastRequest?.path, "/posts/\(id.uuidString.lowercased())/like")
        XCTAssertEqual(liked.likes, 5)

        _ = try await service.setLiked(false, postId: id)
        XCTAssertEqual(network.lastRequest?.method, .delete)
    }

    func testRepostAndBookmarkHitTheirOwnPaths() async throws {
        let metrics = "{ \"likes\": 0, \"reposts\": 1, \"replies\": 0, \"views\": 0, \"bookmarks\": 1 }"
        let network = StubNetworkClient(responses: [metrics, metrics])
        let service = makeService(network)
        let id = UUID()

        _ = try await service.setReposted(true, postId: id)
        XCTAssertEqual(network.lastRequest?.path, "/posts/\(id.uuidString.lowercased())/repost")

        _ = try await service.setBookmarked(true, postId: id)
        XCTAssertEqual(network.lastRequest?.path, "/posts/\(id.uuidString.lowercased())/bookmark")
    }

    func testRepliesUseTheRepliesPathAndPageByCursor() async throws {
        let network = StubNetworkClient(responses: [Self.emptyPage, Self.emptyPage])
        let service = makeService(network)
        let id = UUID()

        _ = try await service.fetchReplies(for: id, cursor: nil)
        XCTAssertEqual(network.lastRequest?.path, "/posts/\(id.uuidString.lowercased())/replies")
        XCTAssertNil(network.lastRequest?.queryValue("cursor"))

        _ = try await service.fetchReplies(for: id, cursor: "c9")
        XCTAssertEqual(network.lastRequest?.queryValue("cursor"), "c9")
    }

    func testDeletingAPostUsesDeleteAndExpectsNoBody() async throws {
        let network = StubNetworkClient()
        let id = UUID()

        try await makeService(network).deletePost(id)

        XCTAssertEqual(network.lastRequest?.method, .delete)
        XCTAssertEqual(network.lastRequest?.path, "/posts/\(id.uuidString.lowercased())")
    }

    // MARK: Mock parity

    func testTheMockHonoursEveryScenario() async throws {
        let populatedPage = try await FeedServiceMock(scenario: .populated)
            .fetchFeed(.forYou, cursor: nil, limit: 20)
        XCTAssertFalse(populatedPage.posts.isEmpty)

        let emptyPage = try await FeedServiceMock(scenario: .empty)
            .fetchFeed(.forYou, cursor: nil, limit: 20)
        XCTAssertTrue(emptyPage.posts.isEmpty)

        let offline = FeedServiceMock(scenario: .offline)
        do {
            _ = try await offline.fetchFeed(.forYou, cursor: nil, limit: 20)
            XCTFail("Expected a transport failure")
        } catch {
            guard case .transport = (error as? APIError) else {
                return XCTFail("Expected .transport, got \(error)")
            }
        }
    }

    func testTheUnverifiedScenarioBlocksOnlyTheCountryFeed() async throws {
        let service = FeedServiceMock(scenario: .unverifiedNoCountry)

        let forYou = try await service.fetchFeed(.forYou, cursor: nil, limit: 20)
        let international = try await service.fetchFeed(.international, cursor: nil, limit: 20)
        XCTAssertFalse(forYou.posts.isEmpty)
        XCTAssertFalse(international.posts.isEmpty)

        do {
            _ = try await service.fetchFeed(.myCountry, cursor: nil, limit: 20)
            XCTFail("Expected no_country")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, .noCountry)
        }
    }

    func testTheExhaustedScenarioReturnsAFullPageThenNothing() async throws {
        let service = FeedServiceMock(scenario: .paginationExhausted)

        let first = try await service.fetchFeed(.forYou, cursor: nil, limit: 20)
        XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.nextCursor)

        let second = try await service.fetchFeed(.forYou, cursor: cursor, limit: 20)
        XCTAssertTrue(second.posts.isEmpty)
        XCTAssertFalse(second.hasMore)
        XCTAssertNil(second.nextCursor)
    }
}
