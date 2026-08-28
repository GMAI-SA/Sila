import XCTest
@testable import TrustNet

/// ``PostDetailViewModel``: parent context, reply paging, and the composer bar's
/// reflection of `viewer.can_reply`.
@MainActor
final class PostDetailViewModelTests: XCTestCase {

    private func makeViewModel(
        post: Post,
        service: ScriptedFeedService
    ) -> PostDetailViewModel {
        PostDetailViewModel(post: post, service: service, analytics: RecordingAnalyticsClient())
    }

    // MARK: Thread assembly

    func testLoadingAThreadFetchesTheParentWhenThePostIsAReply() async {
        let parent = FeedFixture.post(text: "root")
        let reply = Post(
            id: UUID(),
            author: FeedFixture.user(handle: "yuki", country: "JP"),
            text: "a reply",
            createdAt: Date(),
            replyToPostId: parent.id
        )
        let service = ScriptedFeedService()
        service.postsByID = [parent.id: parent, reply.id: reply]
        let viewModel = makeViewModel(post: reply, service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.parent?.id, parent.id)
        XCTAssertEqual(viewModel.parent?.text, "root")
    }

    func testARootPostHasNoParentContext() async {
        let post = FeedFixture.post()
        let service = ScriptedFeedService()
        service.postsByID = [post.id: post]
        let viewModel = makeViewModel(post: post, service: service)

        await viewModel.load()

        XCTAssertNil(viewModel.parent)
    }

    func testTheScreenStillWorksWhenTheRefetchFails() async {
        // The feed already handed us a copy; a failed re-read must not blank it.
        let post = FeedFixture.post(text: "from the feed")
        let viewModel = makeViewModel(post: post, service: ScriptedFeedService())

        await viewModel.load()

        XCTAssertEqual(viewModel.post.text, "from the feed")
        XCTAssertTrue(viewModel.hasLoaded)
    }

    // MARK: Replies

    func testRepliesLoadAndPageByCursor() async {
        let post = FeedFixture.post()
        let service = ScriptedFeedService()
        service.postsByID = [post.id: post]
        service.replyPages = [
            FeedFixture.page(2, cursor: "r1"),
            FeedFixture.page(1, cursor: nil)
        ]
        let viewModel = makeViewModel(post: post, service: service)

        await viewModel.load()
        XCTAssertEqual(viewModel.replies.count, 2)

        await viewModel.loadMoreReplies()
        XCTAssertEqual(viewModel.replies.count, 3)
        XCTAssertEqual(service.replyCalls, [nil, "r1"])

        await viewModel.loadMoreReplies()
        XCTAssertEqual(service.replyCalls.count, 2, "No request once the server ran out")
    }

    func testAThreadWithNoRepliesIsEmptyNotBroken() async {
        let post = FeedFixture.post()
        let service = ScriptedFeedService()
        service.postsByID = [post.id: post]
        let viewModel = makeViewModel(post: post, service: service)

        await viewModel.load()

        XCTAssertTrue(viewModel.replies.isEmpty)
        XCTAssertNil(viewModel.toast)
    }

    // MARK: Composer bar

    func testTheComposerIsLiveOnARepliableThread() async {
        let post = FeedFixture.post(viewer: PostViewerState(canReply: true))
        let viewModel = makeViewModel(post: post, service: ScriptedFeedService())

        XCTAssertTrue(viewModel.replyPermission.canReply)
        XCTAssertNil(viewModel.replyPermission.blockedMessage)
    }

    func testTheComposerShowsTheReasonInsteadOfADeadButton() async {
        let post = FeedFixture.post(
            scope: .country,
            scopeCountry: "SA",
            viewer: PostViewerState(canReply: false, replyBlockReason: .countryMismatch)
        )
        let viewModel = makeViewModel(post: post, service: ScriptedFeedService())
        let country = CountryCode.name("SA") ?? "SA"

        XCTAssertFalse(viewModel.replyPermission.canReply)
        XCTAssertEqual(
            viewModel.replyPermission.blockedMessage,
            "Only 🇸🇦 \(country)-verified accounts can reply to this thread."
        )
    }

    func testTheComposerFollowsTheServerAfterAReload() async {
        // The client never re-derives can_reply; it adopts whatever the server
        // computed for this viewer on this request.
        let post = FeedFixture.post(viewer: PostViewerState(canReply: true))
        var blocked = post
        blocked.viewer = PostViewerState(canReply: false, replyBlockReason: .unverified)

        let service = ScriptedFeedService()
        service.postsByID = [post.id: blocked]
        let viewModel = makeViewModel(post: post, service: service)

        await viewModel.load()

        XCTAssertFalse(viewModel.replyPermission.canReply)
        XCTAssertEqual(viewModel.post.viewer.replyBlockReason, .unverified)
    }

    // MARK: Optimistic engagement

    func testLikingTheFocusedPostRollsBackOnFailure() async {
        let post = FeedFixture.post(metrics: PostMetrics(likes: 7), viewer: PostViewerState(liked: false))
        let service = ScriptedFeedService()
        service.postsByID = [post.id: post]
        service.engagementError = .transport("offline")
        let viewModel = makeViewModel(post: post, service: service)
        await viewModel.load()

        await viewModel.toggleLike(viewModel.post)

        XCTAssertFalse(viewModel.post.viewer.liked)
        XCTAssertEqual(viewModel.post.metrics.likes, 7)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testLikingAReplyUpdatesThatReplyOnly() async {
        let post = FeedFixture.post()
        let replyOne = FeedFixture.post(metrics: PostMetrics(likes: 1))
        let replyTwo = FeedFixture.post(metrics: PostMetrics(likes: 5))
        let service = ScriptedFeedService()
        service.postsByID = [post.id: post]
        service.replyPages = [FeedPage(posts: [replyOne, replyTwo], nextCursor: nil, hasMore: false)]
        service.engagementResult = PostMetrics(likes: 2)
        let viewModel = makeViewModel(post: post, service: service)
        await viewModel.load()

        await viewModel.toggleLike(replyOne)

        XCTAssertEqual(viewModel.replies.first { $0.id == replyOne.id }?.metrics.likes, 2)
        XCTAssertEqual(viewModel.replies.first { $0.id == replyTwo.id }?.metrics.likes, 5)
        XCTAssertEqual(viewModel.post.metrics.likes, post.metrics.likes)
    }
}
