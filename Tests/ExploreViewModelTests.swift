import XCTest
@testable import TrustNet

@MainActor
final class ExploreViewModelTests: XCTestCase {

    private func makeViewModel(
        search: SearchServiceProtocol,
        feed: FeedServiceProtocol = FeedServiceMock(scenario: .populated)
    ) -> ExploreViewModel {
        ExploreViewModel(
            search: search,
            feed: feed,
            analytics: RecordingAnalyticsClient(),
            debounce: 0.02
        )
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Trending

    func testTrendingLoadsOnceAndIsShownWhileTheFieldIsEmpty() async {
        let search = ScriptedSearchService()
        let viewModel = makeViewModel(search: search)

        await viewModel.loadTrending()
        await viewModel.loadTrending()

        XCTAssertEqual(search.trendingCalls, 1, "A second appearance must not re-fetch what is on screen")
        XCTAssertEqual(viewModel.trending.map(\.tag), ["riyadh"])
        XCTAssertTrue(viewModel.isShowingTrending)
    }

    func testAFailedTrendingLoadSaysSoInsteadOfShowingAnEmptyList() async {
        let search = ScriptedSearchService()
        search.error = .transport("offline")
        let viewModel = makeViewModel(search: search)

        await viewModel.loadTrending()

        XCTAssertTrue(viewModel.trending.isEmpty)
        XCTAssertNotNil(viewModel.trendingError, "'Nothing trending' and 'we could not ask' are different facts")
    }

    func testTappingATrendingTagSearchesForItImmediately() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [FeedServiceMock.countryThread])]
        let viewModel = makeViewModel(search: search)

        viewModel.select(TrendingTag(tag: "riyadh", postCount: 12))
        try await settle()

        XCTAssertEqual(viewModel.query, "#riyadh", "The '#' targets the hashtag, not every use of the word")
        XCTAssertEqual(search.postQueries, ["#riyadh"])
        XCTAssertFalse(viewModel.isShowingTrending)
        XCTAssertEqual(viewModel.posts.count, 1)
    }

    // MARK: - Query handling

    func testASingleCharacterQuerySaysToKeepTypingAndSendsNothing() async throws {
        let search = ScriptedSearchService()
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("r")
        try await settle()

        XCTAssertEqual(viewModel.emptyKind, .queryTooShort)
        XCTAssertTrue(search.postQueries.isEmpty, "The contract's floor is enforced before the request")
        XCTAssertTrue(search.userQueries.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testRapidTypingProducesOneSearch() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [])]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("ri")
        viewModel.updateQuery("riy")
        viewModel.updateQuery("riya")
        try await settle()

        XCTAssertEqual(search.postQueries, ["riya"], "Debounce must collapse the burst")
        XCTAssertEqual(search.userQueries, ["riya"])
    }

    func testBothListsComeBackFromOneSearchSoSwitchingTabsIssuesNoRequest() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [FeedServiceMock.internationalRoot])]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("verification", immediately: true)
        try await settle()

        XCTAssertEqual(viewModel.posts.count, 1)
        XCTAssertEqual(viewModel.people.count, 2)

        viewModel.select(.people)
        XCTAssertEqual(search.postQueries.count, 1, "Switching tabs re-uses what the search already returned")
        XCTAssertTrue(viewModel.hasResults)
    }

    func testAQueryThatMatchesNothingSaysSoPerTab() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [])]
        search.users = []
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("zzzz", immediately: true)
        try await settle()

        XCTAssertEqual(viewModel.emptyKind, .noResults)
        XCTAssertFalse(viewModel.hasResults)
    }

    func testAFailedSearchReportsTheFailureRatherThanNoResults() async throws {
        let search = ScriptedSearchService()
        search.error = .transport("offline")
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("riyadh", immediately: true)
        try await settle()

        guard case let .failed(message) = viewModel.emptyKind else {
            return XCTFail("expected a failure state, got \(viewModel.emptyKind)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testClearingTheFieldReturnsToTrending() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [FeedServiceMock.internationalRoot])]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("verification", immediately: true)
        try await settle()
        XCTAssertFalse(viewModel.posts.isEmpty)

        viewModel.clear()

        XCTAssertTrue(viewModel.isShowingTrending)
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertEqual(viewModel.emptyKind, .idle)
    }

    // MARK: - Pagination

    func testPostResultsPageWithTheServersCursor() async throws {
        let search = ScriptedSearchService()
        search.postPages = [
            FeedPage(posts: [FeedServiceMock.internationalRoot], nextCursor: "cursor-2", hasMore: true),
            FeedPage(posts: [FeedServiceMock.quotePost], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("trustnet", immediately: true)
        try await settle()
        XCTAssertEqual(viewModel.posts.count, 1)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.posts.count, 2)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.posts.count, 2, "A page with no cursor ends the run rather than looping")
    }

    func testDuplicatePostsAcrossPagesAreNotRenderedTwice() async throws {
        let search = ScriptedSearchService()
        search.postPages = [
            FeedPage(posts: [FeedServiceMock.internationalRoot], nextCursor: "cursor-2", hasMore: true),
            FeedPage(posts: [FeedServiceMock.internationalRoot], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("trustnet", immediately: true)
        try await settle()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.count, 1)
    }

    // MARK: - Engagement

    func testLikingASearchResultIsOptimisticAndKeepsTheServersCount() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [FeedServiceMock.internationalRoot])]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("verification", immediately: true)
        try await settle()

        let before = try XCTUnwrap(viewModel.posts.first)
        XCTAssertFalse(before.viewer.liked)

        await viewModel.toggleLike(before)

        let after = try XCTUnwrap(viewModel.posts.first)
        XCTAssertTrue(after.viewer.liked)
        XCTAssertEqual(after.metrics.likes, before.metrics.likes + 1)
    }

    func testAFailedLikeRollsBackToWhatWasOnScreen() async throws {
        final class FailingFeed: FeedServiceProtocol, @unchecked Sendable {
            func fetchFeed(_ tab: FeedTab, cursor: String?, limit: Int) async throws -> FeedPage { .empty }
            func fetchPost(_ id: UUID) async throws -> Post { throw APIError.transport("no") }
            func fetchReplies(for postId: UUID, cursor: String?) async throws -> FeedPage { .empty }
            func setLiked(_ liked: Bool, postId: UUID) async throws -> PostMetrics { throw APIError.transport("no") }
            func setReposted(_ reposted: Bool, postId: UUID) async throws -> PostMetrics { throw APIError.transport("no") }
            func setBookmarked(_ bookmarked: Bool, postId: UUID) async throws -> PostMetrics { throw APIError.transport("no") }
            func deletePost(_ id: UUID) async throws {}
        }

        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [FeedServiceMock.internationalRoot])]
        let viewModel = makeViewModel(search: search, feed: FailingFeed())

        viewModel.updateQuery("verification", immediately: true)
        try await settle()

        let before = try XCTUnwrap(viewModel.posts.first)
        await viewModel.toggleLike(before)

        let after = try XCTUnwrap(viewModel.posts.first)
        XCTAssertFalse(after.viewer.liked, "The optimistic like must be undone")
        XCTAssertEqual(after.metrics.likes, before.metrics.likes)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    // MARK: - Freshly written posts

    func testANewPostAppearsInResultsItActuallyMatches() async throws {
        let search = ScriptedSearchService()
        search.postPages = [FeedPage(posts: [])]
        let viewModel = makeViewModel(search: search)

        viewModel.updateQuery("majlis", immediately: true)
        try await settle()
        XCTAssertTrue(viewModel.posts.isEmpty)

        let matching = Post(
            id: UUID(), author: FeedServiceMock.aziz,
            text: "The majlis, digitised.", createdAt: Date()
        )
        let unrelated = Post(
            id: UUID(), author: FeedServiceMock.aziz,
            text: "Something else entirely.", createdAt: Date()
        )
        viewModel.insert([matching, unrelated])

        XCTAssertEqual(viewModel.posts.map(\.id), [matching.id], "Only what matches the query is inserted")
        XCTAssertEqual(viewModel.emptyKind, .idle)
    }

    func testNewPostsAreIgnoredWhileTrendingIsOnScreen() {
        let viewModel = makeViewModel(search: ScriptedSearchService())

        viewModel.insert([FeedServiceMock.internationalRoot])

        XCTAssertTrue(viewModel.posts.isEmpty, "There is no result list to insert into yet")
    }
}
