import XCTest
@testable import Sila

/// ``FeedServiceProtocol`` whose every method is scriptable, so pagination and
/// rollback can be driven exactly.
final class ScriptedFeedService: FeedServiceProtocol, @unchecked Sendable {

    /// Pages to serve per tab, consumed front to back.
    var pages: [FeedTab: [FeedPage]] = [:]
    /// When set, ``fetchFeed(_:cursor:limit:)`` throws it.
    var feedError: APIError?
    /// When set, every engagement call throws it.
    var engagementError: APIError?
    /// Metrics the engagement calls return on success.
    var engagementResult = PostMetrics(likes: 99, reposts: 99, replies: 0, views: 0, bookmarks: 99)
    /// Posts ``fetchPost(_:)`` can resolve.
    var postsByID: [UUID: Post] = [:]
    /// Reply pages, consumed front to back.
    var replyPages: [FeedPage] = []

    /// Every `fetchFeed` call as `(tab, cursor)`.
    private(set) var feedCalls: [(tab: FeedTab, cursor: String?)] = []
    /// Every engagement call as `"like:true"` and so on.
    private(set) var engagementCalls: [String] = []
    /// The cursor passed to each `fetchReplies` call.
    private(set) var replyCalls: [String?] = []

    private let lock = NSLock()

    func fetchFeed(_ tab: FeedTab, cursor: String?, limit: Int) async throws -> FeedPage {
        try nextFeedPage(tab, cursor: cursor)
    }

    func fetchPost(_ id: UUID) async throws -> Post {
        guard let post = lock.withLock({ postsByID[id] }) else {
            throw APIError.api(code: .postNotFound, message: "not scripted", status: 404)
        }
        return post
    }

    func fetchReplies(for postId: UUID, cursor: String?) async throws -> FeedPage {
        lock.withLock {
            replyCalls.append(cursor)
            return replyPages.isEmpty ? FeedPage.empty : replyPages.removeFirst()
        }
    }

    func setLiked(_ liked: Bool, postId: UUID) async throws -> PostMetrics {
        try engagement("like:\(liked)")
    }

    func setReposted(_ reposted: Bool, postId: UUID) async throws -> PostMetrics {
        try engagement("repost:\(reposted)")
    }

    func setBookmarked(_ bookmarked: Bool, postId: UUID) async throws -> PostMetrics {
        try engagement("bookmark:\(bookmarked)")
    }

    func deletePost(_ id: UUID) async throws {}

    private func engagement(_ call: String) throws -> PostMetrics {
        let (error, result) = lock.withLock { () -> (APIError?, PostMetrics) in
            engagementCalls.append(call)
            return (engagementError, engagementResult)
        }
        if let error { throw error }
        return result
    }

    /// Serves the next scripted page, recording the cursor it was asked for.
    private func nextFeedPage(_ tab: FeedTab, cursor: String?) throws -> FeedPage {
        let (error, page) = lock.withLock { () -> (APIError?, FeedPage) in
            feedCalls.append((tab, cursor))
            var queue = pages[tab] ?? []
            let next = queue.isEmpty ? FeedPage.empty : queue.removeFirst()
            pages[tab] = queue
            return (feedError, next)
        }
        if let error { throw error }
        return page
    }

    /// Count of `fetchFeed` calls for one tab.
    func feedCallCount(_ tab: FeedTab) -> Int {
        lock.withLock { feedCalls.filter { $0.tab == tab }.count }
    }
}

/// Test fixtures shared by the view-model tests.
enum FeedFixture {

    static func user(
        handle: String = "aziz",
        verified: Bool = true,
        country: String? = "SA"
    ) -> UserSummary {
        UserSummary(
            id: UUID(),
            handle: handle,
            displayName: handle.capitalized,
            isVerified: verified,
            countryCode: country
        )
    }

    static func post(
        id: UUID = UUID(),
        text: String = "hello",
        scope: PostScope = .international,
        scopeCountry: String? = nil,
        scopeRegion: String? = nil,
        metrics: PostMetrics = PostMetrics(likes: 10, reposts: 2, replies: 1, views: 100, bookmarks: 3),
        viewer: PostViewerState = PostViewerState()
    ) -> Post {
        Post(
            id: id,
            author: user(),
            text: text,
            createdAt: Date(),
            scope: scope,
            scopeCountry: scopeCountry,
            scopeRegion: scopeRegion,
            metrics: metrics,
            viewer: viewer
        )
    }

    static func page(_ count: Int, cursor: String?) -> FeedPage {
        FeedPage(
            posts: (0..<count).map { _ in post() },
            nextCursor: cursor,
            hasMore: cursor != nil
        )
    }
}

/// ``HomeViewModel``: per-tab state, cursor pagination, optimistic engagement.
@MainActor
final class HomeViewModelTests: XCTestCase {

    private func makeViewModel(
        _ service: FeedServiceProtocol
    ) -> HomeViewModel {
        HomeViewModel(service: service, analytics: RecordingAnalyticsClient())
    }

    // MARK: First load

    func testLoadingATabPopulatesOnlyThatTab() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedFixture.page(3, cursor: "c1")]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)

        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 3)
        XCTAssertEqual(viewModel.state(for: .forYou).cursor, "c1")
        XCTAssertTrue(viewModel.state(for: .forYou).hasMore)
        XCTAssertTrue(viewModel.state(for: .following).posts.isEmpty)
        XCTAssertFalse(viewModel.state(for: .following).hasLoaded)
    }

    func testAnEmptyFirstPageProducesTheNoPostsEmptyState() async {
        let service = ScriptedFeedService()
        service.pages[.following] = [.empty]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.following)

        XCTAssertEqual(viewModel.state(for: .following).emptyKind, .noPosts)
        XCTAssertFalse(viewModel.state(for: .following).hasMore)
    }

    // MARK: Per-tab independence

    func testSwitchingToAnAlreadyLoadedTabDoesNotRefetch() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedFixture.page(2, cursor: nil)]
        service.pages[.international] = [FeedFixture.page(2, cursor: nil)]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.select(.international)
        await viewModel.select(.forYou)
        await viewModel.select(.international)

        XCTAssertEqual(service.feedCallCount(.forYou), 1, "For You must load exactly once")
        XCTAssertEqual(service.feedCallCount(.international), 1)
    }

    func testSelectingTheCurrentTabIsANoOp() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedFixture.page(1, cursor: nil)]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.select(.forYou)

        XCTAssertEqual(service.feedCallCount(.forYou), 1)
    }

    func testRefreshAlwaysRefetchesAndReplacesTheCursor() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [
            FeedFixture.page(2, cursor: "c1"),
            FeedFixture.page(4, cursor: "c2")
        ]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.refresh(.forYou)

        XCTAssertEqual(service.feedCallCount(.forYou), 2)
        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 4, "Refresh replaces, never appends")
        XCTAssertEqual(viewModel.state(for: .forYou).cursor, "c2")
    }

    // MARK: Pagination

    func testLoadMoreAppendsAndAdvancesTheCursor() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [
            FeedFixture.page(3, cursor: "c1"),
            FeedFixture.page(2, cursor: "c2")
        ]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.loadMore(.forYou)

        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 5)
        XCTAssertEqual(viewModel.state(for: .forYou).cursor, "c2")
        XCTAssertEqual(service.feedCalls.last?.cursor, "c1", "The server's cursor is echoed, not a page number")
    }

    func testPaginationStopsWhenTheServerRunsOut() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [
            FeedFixture.page(3, cursor: "c1"),
            FeedPage(posts: [], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.loadMore(.forYou)
        await viewModel.loadMore(.forYou)

        XCTAssertFalse(viewModel.state(for: .forYou).hasMore)
        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 3)
        XCTAssertEqual(service.feedCallCount(.forYou), 2, "No request may go out once hasMore is false")
    }

    func testLoadMoreIsANoOpWithoutACursor() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedFixture.page(2, cursor: nil)]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.loadMore(.forYou)

        XCTAssertEqual(service.feedCallCount(.forYou), 1)
    }

    func testDuplicatePostsAcrossPagesAreNotAppendedTwice() async {
        let service = ScriptedFeedService()
        let shared = FeedFixture.post()
        service.pages[.forYou] = [
            FeedPage(posts: [shared], nextCursor: "c1", hasMore: true),
            FeedPage(posts: [shared, FeedFixture.post()], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)
        await viewModel.loadMore(.forYou)

        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 2)
        XCTAssertEqual(Set(viewModel.state(for: .forYou).posts.map(\.id)).count, 2)
    }

    func testPrefetchOnlyFiresNearTheEndOfTheList() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [
            FeedFixture.page(10, cursor: "c1"),
            FeedFixture.page(5, cursor: nil)
        ]
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        let posts = viewModel.state(for: .forYou).posts
        await viewModel.loadMoreIfNeeded(currentPost: posts[0], tab: .forYou)
        XCTAssertEqual(service.feedCallCount(.forYou), 1, "The first row must not paginate")

        await viewModel.loadMoreIfNeeded(currentPost: posts[9], tab: .forYou)
        XCTAssertEqual(service.feedCallCount(.forYou), 2, "The last row must paginate")
    }

    // MARK: The no_country 409

    func testTheCountryTabTreats409NoCountryAsAnExplainerNotAnError() async {
        let service = ScriptedFeedService()
        service.feedError = .api(code: .noCountry, message: "No verified country", status: 409)
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.myCountry)

        XCTAssertEqual(viewModel.state(for: .myCountry).emptyKind, .noCountry)
        XCTAssertNil(viewModel.toast, "no_country must not raise an error banner")
        XCTAssertTrue(viewModel.state(for: .myCountry).posts.isEmpty)
        XCTAssertTrue(viewModel.state(for: .myCountry).hasLoaded)
    }

    func testAnOrdinaryFailureOnAnEmptyTabBecomesAFailedEmptyState() async {
        let service = ScriptedFeedService()
        service.feedError = .transport("offline")
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded(.forYou)

        guard case .failed = viewModel.state(for: .forYou).emptyKind else {
            return XCTFail("Expected .failed, got \(String(describing: viewModel.state(for: .forYou).emptyKind))")
        }
    }

    func testAFailedRefreshKeepsThePostsAlreadyOnScreen() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedFixture.page(3, cursor: nil)]
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        service.feedError = .transport("offline")
        await viewModel.refresh(.forYou)

        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 3, "A failed refresh must not blank the feed")
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    // MARK: Optimistic engagement

    func testLikingUpdatesTheCardBeforeTheServerAnswers() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(metrics: PostMetrics(likes: 10), viewer: PostViewerState(liked: false))
        service.pages[.forYou] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        service.engagementResult = PostMetrics(likes: 11)
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        await viewModel.toggleLike(post)

        let updated = try? XCTUnwrap(viewModel.findPost(post.id))
        XCTAssertEqual(updated?.viewer.liked, true)
        XCTAssertEqual(updated?.metrics.likes, 11)
        XCTAssertEqual(service.engagementCalls, ["like:true"])
    }

    func testAFailedLikeRollsTheCardBackToExactlyItsPreviousState() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(
            metrics: PostMetrics(likes: 10, reposts: 2, replies: 1, views: 100, bookmarks: 3),
            viewer: PostViewerState(liked: false)
        )
        service.pages[.forYou] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        service.engagementError = .transport("offline")
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        await viewModel.toggleLike(post)

        let rolledBack = try? XCTUnwrap(viewModel.findPost(post.id))
        XCTAssertEqual(rolledBack?.viewer.liked, false)
        XCTAssertEqual(rolledBack?.metrics, post.metrics, "Rollback restores the snapshot, not an inverse toggle")
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testUnlikingDecrementsAndRollsBackOnFailure() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(metrics: PostMetrics(likes: 10), viewer: PostViewerState(liked: true))
        service.pages[.forYou] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        service.engagementError = .api(code: .postNotFound, message: "gone", status: 404)
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        await viewModel.toggleLike(post)

        let rolledBack = try? XCTUnwrap(viewModel.findPost(post.id))
        XCTAssertEqual(rolledBack?.viewer.liked, true)
        XCTAssertEqual(rolledBack?.metrics.likes, 10)
        XCTAssertEqual(service.engagementCalls, ["like:false"], "Unliking sends false, not true")
    }

    func testRepostAndBookmarkFollowTheSameOptimisticRule() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(metrics: PostMetrics(likes: 0, reposts: 4, bookmarks: 6))
        service.pages[.forYou] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        service.engagementResult = PostMetrics(likes: 0, reposts: 5, bookmarks: 7)
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        await viewModel.toggleRepost(post)
        await viewModel.toggleBookmark(post)

        let updated = try? XCTUnwrap(viewModel.findPost(post.id))
        XCTAssertEqual(updated?.viewer.reposted, true)
        XCTAssertEqual(updated?.viewer.bookmarked, true)
        XCTAssertEqual(service.engagementCalls, ["repost:true", "bookmark:true"])
    }

    func testAnEngagementAppliesToEveryTabHoldingThePost() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(metrics: PostMetrics(likes: 1))
        service.pages[.forYou] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        service.pages[.international] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        service.engagementResult = PostMetrics(likes: 2)
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)
        await viewModel.select(.international)

        await viewModel.toggleLike(post)

        XCTAssertEqual(viewModel.state(for: .forYou).posts.first?.metrics.likes, 2)
        XCTAssertEqual(viewModel.state(for: .international).posts.first?.metrics.likes, 2)
    }

    func testMergeAdoptsEngagementMadeOnTheDetailScreen() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(metrics: PostMetrics(likes: 1), viewer: PostViewerState(liked: false))
        service.pages[.forYou] = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded(.forYou)

        var edited = post
        edited.metrics = PostMetrics(likes: 2)
        edited.viewer = PostViewerState(liked: true)
        viewModel.merge(edited)

        XCTAssertEqual(viewModel.state(for: .forYou).posts.first?.metrics.likes, 2)
        XCTAssertEqual(viewModel.state(for: .forYou).posts.first?.viewer.liked, true)
    }

    // MARK: Blocked replies

    func testPressingABlockedReplyExplainsInsteadOfFailingSilently() async {
        let service = ScriptedFeedService()
        let post = FeedFixture.post(
            scope: .country,
            scopeCountry: "SA",
            viewer: PostViewerState(canReply: false, replyBlockReason: .countryMismatch)
        )
        let viewModel = makeViewModel(service)

        viewModel.replyBlocked(post)

        // The country name is localised, so the expectation is built the same
        // way rather than hard-coding an English string.
        let country = CountryCode.name("SA") ?? "SA"
        XCTAssertEqual(viewModel.toast?.kind, .warning)
        XCTAssertEqual(
            viewModel.toast?.text,
            "Only 🇸🇦 \(country)-verified accounts can reply to this thread."
        )
    }

    func testARepliablePostProducesNoBlockToast() async {
        let viewModel = makeViewModel(ScriptedFeedService())

        viewModel.replyBlocked(FeedFixture.post(viewer: PostViewerState(canReply: true)))

        XCTAssertNil(viewModel.toast)
    }
}
