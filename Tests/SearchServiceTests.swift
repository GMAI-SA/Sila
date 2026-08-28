import XCTest
@testable import TrustNet

/// The wire contract with contract v3 (`/search/*`, `/explore/trending`), and
/// the request construction around it.
///
/// Uses ``StubNetworkClient`` from `FeedServiceTests`, so the URL, the query
/// items and the decoded shapes are all asserted without a server.
final class SearchServiceTests: XCTestCase {

    private func makeService(_ network: StubNetworkClient) -> SearchService {
        SearchService(
            network: network,
            tokens: StaticAccessTokenProvider(token: "search-token"),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Users

    func testUserSearchSendsTheTrimmedQueryAndTheClampedLimit() async throws {
        let network = StubNetworkClient(responses: ["""
        {"users": [
          {"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "handle": "aziz",
           "display_name": "Abdulaziz", "avatar_url": null, "is_verified": true,
           "country_code": "SA", "verified_since": "2026-08-28T09:15:00Z"}
        ]}
        """])

        let users = try await makeService(network).searchUsers(query: "  aziz  ", limit: 99)

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/search/users")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.queryValue("q"), "aziz")
        XCTAssertEqual(request.queryValue("limit"), "20", "The contract caps user search at 20")
        XCTAssertEqual(request.accessToken, "search-token")
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.handle, "aziz")
        XCTAssertEqual(users.first?.countryCode, "SA")
    }

    func testAShortQueryNeverLeavesTheDevice() async throws {
        let network = StubNetworkClient(responses: ["{}"])

        let users = try await makeService(network).searchUsers(query: "a", limit: 8)

        XCTAssertTrue(users.isEmpty)
        XCTAssertTrue(
            network.requests.isEmpty,
            "The server answers a one-character query with nothing; asking costs a round trip to learn that"
        )
    }

    func testAWhitespaceOnlyQueryIsTreatedAsTooShort() async throws {
        let network = StubNetworkClient(responses: ["{}"])

        _ = try await makeService(network).searchUsers(query: "   ", limit: 8)

        XCTAssertTrue(network.requests.isEmpty)
    }

    func testAMissingUsersKeyDecodesAsEmptyRatherThanFailing() throws {
        XCTAssertTrue(try decode(UserSearchResponse.self, from: "{}").users.isEmpty)
    }

    // MARK: - Posts

    func testPostSearchSendsTheCursorOnlyWhenThereIsOne() async throws {
        let page = """
        {"posts": [], "next_cursor": "cursor-2", "has_more": true}
        """
        let network = StubNetworkClient(responses: [page, page])
        let service = makeService(network)

        _ = try await service.searchPosts(query: "riyadh", cursor: nil, limit: 20)
        XCTAssertNil(network.lastRequest?.queryValue("cursor"), "No cursor means no parameter")

        _ = try await service.searchPosts(query: "riyadh", cursor: "cursor-2", limit: 20)
        XCTAssertEqual(network.lastRequest?.queryValue("cursor"), "cursor-2")
        XCTAssertEqual(network.lastRequest?.path, "/search/posts")
    }

    func testAnEmptyCursorIsNotSentAsAParameter() async throws {
        let network = StubNetworkClient(responses: ["{\"posts\": []}"])

        _ = try await makeService(network).searchPosts(query: "riyadh", cursor: "", limit: 20)

        XCTAssertNil(network.lastRequest?.queryValue("cursor"))
    }

    func testPostSearchReturnsAFeedPageTheFeedCodeAlreadyUnderstands() async throws {
        let network = StubNetworkClient(responses: ["""
        {"posts": [{
           "id": "11111111-1111-4111-8111-111111111111",
           "author": {"id": "22222222-2222-4222-8222-222222222222", "handle": "noor",
                      "display_name": "Noor", "is_verified": true, "country_code": "AE"},
           "text": "Anyone else out walking? #Riyadh",
           "created_at": "2026-08-28T09:15:00Z",
           "scope": "country", "scope_country": "SA",
           "reply_to_post_id": null, "reply_count_direct": 0,
           "quoted_post": null,
           "metrics": {"likes": 1, "reposts": 0, "replies": 0, "views": 9, "bookmarks": 0},
           "viewer": {"liked": false, "reposted": false, "bookmarked": false,
                      "can_reply": false, "reply_block_reason": "country_mismatch"}
         }], "next_cursor": null, "has_more": false}
        """])

        let page = try await makeService(network).searchPosts(query: "riyadh", cursor: nil, limit: 20)

        XCTAssertEqual(page.posts.count, 1)
        XCTAssertEqual(page.posts.first?.scope, .country)
        XCTAssertEqual(page.posts.first?.scopeCountry, "SA")
        XCTAssertFalse(page.posts.first?.viewer.canReply ?? true)
        XCTAssertFalse(page.hasMore)
    }

    func testAShortPostQueryReturnsTheEmptyPageWithoutARequest() async throws {
        let network = StubNetworkClient(responses: ["{}"])

        let page = try await makeService(network).searchPosts(query: "r", cursor: nil, limit: 20)

        XCTAssertEqual(page, .empty)
        XCTAssertTrue(network.requests.isEmpty)
    }

    // MARK: - Trending

    func testTrendingDecodesTagsWithoutTheHash() async throws {
        let network = StubNetworkClient(responses: ["""
        {"tags": [{"tag": "riyadh", "post_count": 12}, {"tag": "trustnet", "post_count": 5}]}
        """])

        let tags = try await makeService(network).trendingTags(limit: 10)

        XCTAssertEqual(network.lastRequest?.path, "/explore/trending")
        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "10")
        XCTAssertEqual(tags.map(\.tag), ["riyadh", "trustnet"])
        XCTAssertEqual(tags.map(\.postCount), [12, 5])
        XCTAssertEqual(tags.first?.hashtag, "#riyadh", "The '#' is added for display, never expected on the wire")
        XCTAssertEqual(tags.first?.id, "riyadh")
    }

    func testTrendingLimitIsClampedToTheContractMaximum() async throws {
        let network = StubNetworkClient(responses: ["{\"tags\": []}"])

        _ = try await makeService(network).trendingTags(limit: 500)

        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "20")
    }

    func testAStrayHashOrUppercaseTagIsNormalisedRatherThanRendered() throws {
        let response = try decode(
            TrendingResponse.self,
            from: "{\"tags\": [{\"tag\": \"#Riyadh\", \"post_count\": 3}]}"
        )

        XCTAssertEqual(response.tags.first?.tag, "riyadh")
        XCTAssertEqual(response.tags.first?.hashtag, "#riyadh", "Never '##riyadh'")
    }

    func testATagRowWithNothingUsableIsDroppedNotRenderedBlank() throws {
        let response = try decode(
            TrendingResponse.self,
            from: "{\"tags\": [{\"tag\": \"\", \"post_count\": 9}, {\"tag\": \"ok\", \"post_count\": 1}]}"
        )

        XCTAssertEqual(response.tags.map(\.tag), ["ok"])
    }

    func testANegativePostCountIsClampedToZero() throws {
        let tag = try decode(TrendingTag.self, from: "{\"tag\": \"x\", \"post_count\": -4}")

        XCTAssertEqual(tag.postCount, 0)
    }

    // MARK: - Errors

    func testTheQueryTooShortCodeMapsToAUsableSentence() {
        let error = APIError.api(code: .queryTooShort, message: "", status: 400)

        XCTAssertEqual(error.code, .queryTooShort)
        XCTAssertTrue(error.userMessage.contains("2"), "got: \(error.userMessage)")
    }

    func testAServerFailurePropagatesRatherThanSilentlyEmptying() async {
        let network = StubNetworkClient(error: .transport("offline"))

        do {
            _ = try await makeService(network).trendingTags(limit: 10)
            XCTFail("A failing request must not look like an empty trending list")
        } catch {
            XCTAssertEqual(error as? APIError, .transport("offline"))
        }
    }

    // MARK: - Mock parity

    func testTheMockHonoursTheSameMinimumQueryLength() async throws {
        let mock = SearchServiceMock(scenario: .populated)

        let short = try await mock.searchUsers(query: "a", limit: 8)
        let long = try await mock.searchUsers(query: "az", limit: 8)

        XCTAssertTrue(short.isEmpty)
        XCTAssertEqual(long.first?.handle, "aziz")
    }

    func testTheMockSearchesTheSameFixtureWorldTheFeedShows() async throws {
        let mock = SearchServiceMock(scenario: .populated)

        let page = try await mock.searchPosts(query: "riyadh", cursor: nil, limit: 20)

        XCTAssertFalse(page.posts.isEmpty)
        XCTAssertTrue(page.posts.allSatisfy { $0.text.lowercased().contains("riyadh") })
    }
}
