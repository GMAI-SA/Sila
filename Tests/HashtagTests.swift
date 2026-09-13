import XCTest
@testable import Sila

/// A hashtag is a place (contract v17): its page, its order, and the memory of that order.
final class HashtagTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Models

    func testEverySortDecodesFromItsWireValueAndUnknownFallsBackToNewest() {
        XCTAssertEqual(HashtagSort(wire: "most_viewed"), .mostViewed)
        XCTAssertEqual(HashtagSort(wire: "most_discussed"), .mostDiscussed)
        XCTAssertEqual(HashtagSort(wire: "most_reposted"), .mostReposted)
        XCTAssertEqual(HashtagSort(wire: "top"), .top)
        XCTAssertEqual(HashtagSort(wire: "loudest"), .newest)
        XCTAssertEqual(HashtagSort(wire: nil), .newest)
    }

    func testAHashtagPageDecodesItsTagOrderAndCount() throws {
        let page = try decode(HashtagPage.self, from: """
        {"posts": [], "next_cursor": null, "has_more": false, "tag": "riyadh", "sort": "top", "post_count": 7}
        """)
        XCTAssertEqual(page.tag, "riyadh")
        XCTAssertEqual(page.sort, .top)
        XCTAssertEqual(page.postCount, 7)
        XCTAssertFalse(page.hasMore)
    }

    func testPreferencesCarryTheRememberedOrder() throws {
        let prefs = try decode(FeedPreferences.self, from: """
        {"interests": [], "muted_topics": [], "filter_international_by_interests": false,
         "show_untagged_posts": true, "muted_countries": [], "languages": [], "hashtag_sort": "most_discussed"}
        """)
        XCTAssertEqual(prefs.hashtagSort, .mostDiscussed)
        XCTAssertEqual(try decode(FeedPreferences.self, from: "{}").hashtagSort, .newest, "absent means newest")

        let body = try JSONCoding.encoder.encode(PreferencesUpdate(hashtagSort: .top))
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"hashtag_sort\":\"top\""), json)
    }

    func testTheTagIsNormalisedTheWayTheServerKeysIt() {
        XCTAssertEqual(HashtagViewModel.normalised("#Riyadh"), "riyadh")
        XCTAssertEqual(HashtagViewModel.normalised("  ##الرياض "), "الرياض")
    }

    // MARK: Service

    func testTheServiceEncodesArabicTagsAndPassesTheSort() async throws {
        let network = StubNetworkClient(responses: [
            #"{"posts": [], "next_cursor": null, "has_more": false, "tag": "الرياض", "sort": "top", "post_count": 0}"#
        ])
        let service = FeedService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
        _ = try await service.fetchHashtagPosts("#الرياض", sort: .top, cursor: "abc")
        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/hashtags/%D8%A7%D9%84%D8%B1%D9%8A%D8%A7%D8%B6/posts")
        XCTAssertEqual(request.queryValue("sort"), "top")
        XCTAssertEqual(request.queryValue("cursor"), "abc")
        XCTAssertEqual(request.accessToken, "t")
    }

    func testTheServiceAsksForNoSortWhenTheViewerHasNotChosen() async throws {
        let network = StubNetworkClient(responses: [#"{"posts": [], "tag": "x", "sort": "newest"}"#])
        let service = FeedService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
        _ = try await service.fetchHashtagPosts("x", sort: nil, cursor: nil)
        XCTAssertNil(network.lastRequest?.queryValue("sort"), "the server applies the remembered order")
        XCTAssertNil(network.lastRequest?.queryValue("cursor"))
    }

    // MARK: View model

    @MainActor
    private func makeViewModel(
        feed: ScriptedFeedService,
        preferences: PreferencesServiceMock? = nil
    ) -> HashtagViewModel {
        HashtagViewModel(tag: "#Riyadh", service: feed, preferences: preferences, analytics: RecordingAnalyticsClient())
    }

    @MainActor
    func testTheFirstPageLetsTheServerPickTheOrderAndAdoptsIt() async throws {
        let feed = ScriptedFeedService()
        feed.hashtagPages = [HashtagPage(posts: [FeedServiceMock.internationalRoot], tag: "riyadh", sort: .mostViewed, postCount: 3)]
        let viewModel = makeViewModel(feed: feed)
        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.sort, .mostViewed, "the remembered order came back from the server")
        XCTAssertEqual(viewModel.postCount, 3)
        XCTAssertEqual(viewModel.hashtag, "#riyadh")
        XCTAssertEqual(feed.hashtagCalls.count, 1)
        XCTAssertNil(feed.hashtagCalls[0].sort)
        XCTAssertEqual(feed.hashtagCalls[0].tag, "riyadh")
    }

    @MainActor
    func testChoosingAnOrderReloadsWithItAndRemembersIt() async throws {
        let feed = ScriptedFeedService()
        feed.hashtagPages = [
            HashtagPage(posts: [FeedServiceMock.internationalRoot], tag: "riyadh", sort: .newest),
            HashtagPage(posts: [], tag: "riyadh", sort: .top),
        ]
        let preferences = PreferencesServiceMock()
        let viewModel = makeViewModel(feed: feed, preferences: preferences)
        await viewModel.load()
        await viewModel.select(.top)
        XCTAssertEqual(viewModel.sort, .top)
        XCTAssertEqual(feed.hashtagCalls.last?.sort, .top, "the reload asks for the chosen order explicitly")
        // The choice is remembered on the account, not just this screen.
        var updates = await preferences.receivedUpdates
        for _ in 0..<20 {
            if !updates.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            updates = await preferences.receivedUpdates
        }
        XCTAssertEqual(updates.last?.hashtagSort, "top")
    }

    @MainActor
    func testASupersededLoadDoesNotWriteOverTheNewerOne() async throws {
        let feed = ScriptedFeedService()
        feed.hashtagPages = [
            HashtagPage(posts: [FeedServiceMock.internationalRoot], tag: "riyadh", sort: .newest, postCount: 1),
            HashtagPage(posts: [], tag: "riyadh", sort: .top, postCount: 0),
            HashtagPage(posts: [FeedServiceMock.internationalRoot], tag: "riyadh", sort: .mostViewed, postCount: 1),
        ]
        let viewModel = makeViewModel(feed: feed)
        await viewModel.load()
        // Two orders chosen in quick succession: the last one asked for is the
        // one on screen, whichever request happens to answer first.
        async let first: Void = viewModel.select(.top)
        async let second: Void = viewModel.select(.mostViewed)
        _ = await (first, second)
        XCTAssertEqual(viewModel.sort, .mostViewed)
        XCTAssertEqual(feed.hashtagCalls.last?.sort, .mostViewed)
    }

    @MainActor
    func testAFailedFirstPageIsAFailureAndACancelledOneIsNot() async throws {
        let feed = ScriptedFeedService()
        feed.feedError = .transport("no network")
        let viewModel = makeViewModel(feed: feed)
        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .failed(APIError.transport("no network").userMessage))

        let cancelled = ScriptedFeedService()
        cancelled.feedError = .cancelled
        let quiet = makeViewModel(feed: cancelled)
        await quiet.load()
        XCTAssertEqual(quiet.loadState, .loading, "an abandoned load leaves no failure behind")
        XCTAssertNil(quiet.toast)
    }
}
