import XCTest
@testable import Sila

/// ``ProfileServiceProtocol`` whose every answer the test chooses.
///
/// The interesting behaviour on this screen is in the disagreements — a server
/// that returns a different count than the client predicted, a handle that stops
/// existing between two calls — so the double has to be able to answer anything.
final class ScriptedProfileService: ProfileServiceProtocol, @unchecked Sendable {

    var profile = Profile(
        user: FeedServiceMock.yuki,
        bio: "Tokyo.",
        postCount: 2,
        followerCount: 12,
        followingCount: 4,
        isFollowing: false,
        isMe: false
    )
    /// Pages answered in order; the last one repeats.
    var pages: [FeedPage] = [FeedPage(posts: [], nextCursor: nil, hasMore: false)]
    /// What the next follow/unfollow answers.
    var followResult = FollowResult(following: true, followerCount: 13)

    /// When set, `fetchProfile` fails.
    var profileError: APIError?
    /// When set, `fetchPosts` fails.
    var postsError: APIError?
    /// When set, `setFollowing` fails.
    var followError: APIError?
    /// When `true`, `setFollowing` suspends once before answering, so a second
    /// tap has a chance to arrive while the first is genuinely in flight.
    var yieldsBeforeAnsweringFollow = false

    private(set) var profileFetches = 0
    private(set) var cursors: [String?] = []
    private(set) var followCalls: [(following: Bool, handle: String)] = []

    func fetchProfile(handle: String) async throws -> Profile {
        profileFetches += 1
        if let profileError { throw profileError }
        return profile
    }

    func fetchPosts(handle: String, cursor: String?, limit: Int) async throws -> FeedPage {
        cursors.append(cursor)
        if let postsError { throw postsError }
        return pages.count > 1 ? pages.removeFirst() : (pages.first ?? .empty)
    }

    func setFollowing(_ following: Bool, handle: String) async throws -> FollowResult {
        followCalls.append((following, handle))
        if yieldsBeforeAnsweringFollow { await Task.yield() }
        if let followError { throw followError }
        return followResult
    }
}

@MainActor
final class ProfileViewModelTests: XCTestCase {

    private func makeViewModel(
        _ service: ScriptedProfileService,
        handle: String = "yuki",
        viewerHandle: String? = "aziz",
        feed: FeedServiceProtocol = FeedServiceMock(scenario: .populated)
    ) -> ProfileViewModel {
        ProfileViewModel(
            handle: handle,
            viewerHandle: viewerHandle,
            service: service,
            feed: feed,
            analytics: RecordingAnalyticsClient()
        )
    }

    private static func post(_ suffix: Int, author: UserSummary = FeedServiceMock.yuki) -> Post {
        Post(
            id: UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", suffix))") ?? UUID(),
            author: author,
            text: "Post \(suffix)",
            createdAt: Date()
        )
    }

    // MARK: - Loading

    func testALoadedProfileShowsItsHeaderAndItsPosts() async {
        let service = ScriptedProfileService()
        service.pages = [FeedPage(posts: [Self.post(1), Self.post(2)], nextCursor: nil, hasMore: false)]
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.profile?.handle, "yuki")
        XCTAssertEqual(viewModel.posts.count, 2)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertNil(viewModel.postsError)
    }

    func testTheHandleIsNormalisedBeforeAnythingUsesIt() {
        let viewModel = makeViewModel(ScriptedProfileService(), handle: " @YUKI ")

        XCTAssertEqual(viewModel.handle, "yuki")
    }

    func testLoadingTwiceDoesNotRefetch() async {
        let service = ScriptedProfileService()
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(service.profileFetches, 1)
    }

    // MARK: - The dead end

    /// **404 is not an error the user can act on.** The screen has to say the
    /// account is not available and offer nothing to press — a Retry here can
    /// only fail again, forever.
    func testAnUnknownHandleBecomesTheUnavailableStateAndNotAFailure() async {
        let service = ScriptedProfileService()
        service.profileError = .api(code: .userNotFound, message: "No account", status: 404)
        service.postsError = service.profileError
        let viewModel = makeViewModel(service, handle: "ghost")

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .unavailable)
        XCTAssertTrue(viewModel.isUnavailable)
        XCTAssertNil(viewModel.profile)
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.showsFollowButton, "there is nobody to follow")
        if case .failed = viewModel.loadState {
            XCTFail("a missing account was reported as a retryable failure")
        }
    }

    /// A deactivated account is the same 404, and must land in the same place.
    func testADeactivatedAccountIsIndistinguishableFromAnUnknownOne() async {
        let service = ScriptedProfileService()
        service.profileError = .api(
            code: .userNotFound,
            message: "No account with that handle",
            status: 404
        )
        service.postsError = service.profileError

        let viewModel = makeViewModel(service, handle: "wasreal")
        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .unavailable)
    }

    /// A transport failure is the opposite case: retrying is exactly the right
    /// thing to offer, so it must **not** collapse into the dead end.
    func testATransportFailureStaysRetryable() async {
        let service = ScriptedProfileService()
        service.profileError = .transport("The Internet connection appears to be offline.")
        service.postsError = service.profileError
        let viewModel = makeViewModel(service)

        await viewModel.load()

        guard case let .failed(message) = viewModel.loadState else {
            return XCTFail("expected a retryable failure, got \(viewModel.loadState)")
        }
        XCTAssertTrue(message.contains("Network problem"))
        XCTAssertFalse(viewModel.isUnavailable)
    }

    func testARetryAfterAFailureLoadsTheProfile() async {
        let service = ScriptedProfileService()
        service.profileError = .transport("offline")
        service.postsError = service.profileError
        let viewModel = makeViewModel(service)
        await viewModel.load()

        service.profileError = nil
        service.postsError = nil
        await viewModel.reload()

        XCTAssertEqual(viewModel.loadState, .loaded)
    }

    /// A header that arrived and a timeline that did not is still a profile.
    func testAFailedTimelineDoesNotTakeTheHeaderDownWithIt() async {
        let service = ScriptedProfileService()
        service.postsError = .transport("offline")
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertNotNil(viewModel.profile)
        XCTAssertNotNil(viewModel.postsError)
        XCTAssertTrue(viewModel.posts.isEmpty)
    }

    /// The account went away between the two requests. The dead end wins over
    /// the header that arrived a moment earlier.
    func testAnAccountThatVanishesMidLoadEndsUpUnavailable() async {
        let service = ScriptedProfileService()
        service.postsError = .api(code: .userNotFound, message: "No account", status: 404)
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .unavailable)
        XCTAssertNil(viewModel.profile)
    }

    // MARK: - Your own profile

    /// **The follow button is absent, not disabled.** `POST /users/me/follow`
    /// answers `400 self_follow`, so a greyed-out control would be an
    /// affordance for something that cannot happen.
    func testYourOwnProfileHasNoFollowButtonAtAll() async {
        let service = ScriptedProfileService()
        service.profile = Profile(
            user: FeedServiceMock.aziz,
            bio: "Building Sila.",
            postCount: 3,
            followerCount: 1_284,
            followingCount: 96,
            isFollowing: false,
            isMe: true
        )
        let viewModel = makeViewModel(service, handle: "aziz", viewerHandle: "aziz")

        await viewModel.load()

        XCTAssertFalse(viewModel.showsFollowButton)
        XCTAssertTrue(viewModel.isOwnProfile, "the account routes belong on this page")
    }

    /// Tapping the follow control on your own page cannot happen through the UI,
    /// and does nothing if it somehow does.
    func testTogglingFollowOnYourOwnProfileNeverReachesTheServer() async {
        let service = ScriptedProfileService()
        service.profile = Profile(user: FeedServiceMock.aziz, isMe: true)
        let viewModel = makeViewModel(service, handle: "aziz", viewerHandle: "aziz")
        await viewModel.load()

        await viewModel.toggleFollow()

        XCTAssertTrue(service.followCalls.isEmpty)
    }

    /// The Profile tab must stay a route into account settings even when the
    /// network is down — deletion and the data export live behind it.
    func testYourOwnTabKnowsItIsYoursBeforeTheServerSaysSo() async {
        let service = ScriptedProfileService()
        service.profileError = .transport("offline")
        service.postsError = service.profileError
        let viewModel = makeViewModel(service, handle: "aziz", viewerHandle: "aziz")

        await viewModel.load()

        XCTAssertTrue(viewModel.isOwnProfile, "a failed load stranded the account routes")
    }

    func testSomebodyElsesProfileIsNeverTreatedAsYourOwn() async {
        let viewModel = makeViewModel(ScriptedProfileService(), handle: "yuki", viewerHandle: "aziz")

        await viewModel.load()

        XCTAssertFalse(viewModel.isOwnProfile)
        XCTAssertTrue(viewModel.showsFollowButton)
    }

    // MARK: - Following

    /// **The rule.** The optimistic `+1` is replaced by the server's number,
    /// which is higher here because another device followed too.
    func testTheServersFollowerCountReplacesTheOptimisticOne() async {
        let service = ScriptedProfileService()
        service.followResult = FollowResult(following: true, followerCount: 14)
        let viewModel = makeViewModel(service)
        await viewModel.load()
        XCTAssertEqual(viewModel.profile?.followerCount, 12)

        await viewModel.toggleFollow()

        XCTAssertEqual(viewModel.profile?.followerCount, 14, "the client kept its own guess of 13")
        XCTAssertTrue(viewModel.profile?.isFollowing ?? false)
        XCTAssertEqual(service.followCalls.map(\.following), [true])
        XCTAssertEqual(service.followCalls.map(\.handle), ["yuki"])
    }

    /// Following something you already follow is a success that changes nothing,
    /// and the client must not add one anyway.
    func testAFollowThatWasAlreadyStoredDoesNotMoveTheCount() async {
        let service = ScriptedProfileService()
        service.profile = Profile(
            user: FeedServiceMock.yuki,
            followerCount: 13,
            isFollowing: false
        )
        // The server already had the row: same count back.
        service.followResult = FollowResult(following: true, followerCount: 13)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.toggleFollow()

        XCTAssertEqual(viewModel.profile?.followerCount, 13)
        XCTAssertTrue(viewModel.profile?.isFollowing ?? false)
    }

    func testUnfollowingSendsADeleteAndAdoptsTheAnswer() async {
        let service = ScriptedProfileService()
        service.profile = Profile(user: FeedServiceMock.yuki, followerCount: 13, isFollowing: true)
        service.followResult = FollowResult(following: false, followerCount: 9)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.toggleFollow()

        XCTAssertEqual(service.followCalls.map(\.following), [false])
        XCTAssertEqual(viewModel.profile?.followerCount, 9)
        XCTAssertFalse(viewModel.profile?.isFollowing ?? true)
    }

    /// A failure puts the button back exactly where it was — not one below
    /// where the optimistic update left it.
    func testAFailedFollowRollsBackToWhatWasOnScreen() async {
        let service = ScriptedProfileService()
        service.followError = .http(status: 500, message: "boom")
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.toggleFollow()

        XCTAssertEqual(viewModel.profile?.followerCount, 12)
        XCTAssertFalse(viewModel.profile?.isFollowing ?? true)
        XCTAssertNotNil(viewModel.toast, "a silent failure would leave the button lying")
    }

    /// `400 self_follow` should be unreachable — the button is hidden — but the
    /// client still has to survive it rather than leave a wrong count behind.
    func testASelfFollowRefusalIsHandledRatherThanTrusted() async {
        let service = ScriptedProfileService()
        service.followError = .api(code: .selfFollow, message: "You cannot follow yourself", status: 400)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.toggleFollow()

        XCTAssertFalse(viewModel.profile?.isFollowing ?? true)
        XCTAssertEqual(viewModel.profile?.followerCount, 12)
        XCTAssertEqual(viewModel.toast?.text, "You can't follow yourself.")
    }

    /// The account was deleted while its page was open. The screen becomes the
    /// dead end instead of showing a follower count for somebody who is gone.
    func testFollowingAnAccountThatHasVanishedLandsOnTheUnavailableState() async {
        let service = ScriptedProfileService()
        service.followError = .api(code: .userNotFound, message: "No account", status: 404)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.toggleFollow()

        XCTAssertEqual(viewModel.loadState, .unavailable)
        XCTAssertNil(viewModel.profile)
    }

    func testASecondTapWhileTheFirstIsInFlightIsIgnored() async {
        let service = ScriptedProfileService()
        service.yieldsBeforeAnsweringFollow = true
        let viewModel = makeViewModel(service)
        await viewModel.load()

        async let first: Void = viewModel.toggleFollow()
        async let second: Void = viewModel.toggleFollow()
        _ = await (first, second)

        XCTAssertEqual(service.followCalls.count, 1, "the button double-fired")
    }

    // MARK: - Paging

    func testTheNextPageIsAppendedAndTheCursorIsCarried() async {
        let service = ScriptedProfileService()
        service.pages = [
            FeedPage(posts: [Self.post(1), Self.post(2)], nextCursor: "cursor-2", hasMore: true),
            FeedPage(posts: [Self.post(3)], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.count, 3)
        XCTAssertEqual(service.cursors, [nil, "cursor-2"])
        XCTAssertFalse(viewModel.hasMore)
    }

    /// A post written between the two requests can arrive on both pages.
    func testAPostArrivingOnTwoPagesIsOnlyKeptOnce() async {
        let service = ScriptedProfileService()
        service.pages = [
            FeedPage(posts: [Self.post(1), Self.post(2)], nextCursor: "cursor-2", hasMore: true),
            FeedPage(posts: [Self.post(2), Self.post(3)], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.count, 3)
        XCTAssertEqual(Set(viewModel.posts.map(\.id)).count, 3)
    }

    /// A first page that promises more and a second that delivers nothing must
    /// stop the pager rather than spin it.
    func testAPageThatPromisesMoreAndDeliversNothingStopsThePager() async {
        let service = ScriptedProfileService()
        service.pages = [
            FeedPage(posts: [Self.post(1)], nextCursor: "cursor-2", hasMore: true),
            FeedPage(posts: [], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.loadMore()
        await viewModel.loadMore()

        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(service.cursors, [nil, "cursor-2"], "the pager kept asking")
    }

    func testAFailedPageStopsThePagerAndSaysSo() async {
        let service = ScriptedProfileService()
        service.pages = [FeedPage(posts: [Self.post(1)], nextCursor: "cursor-2", hasMore: true)]
        let viewModel = makeViewModel(service)
        await viewModel.load()
        service.postsError = .transport("offline")

        await viewModel.loadMore()

        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.posts.count, 1, "the page already on screen was kept")
        XCTAssertNotNil(viewModel.toast)
    }

    func testPrefetchOnlyFiresNearTheEndOfTheList() async {
        let service = ScriptedProfileService()
        let loaded = (1...10).map { Self.post($0) }
        service.pages = [
            FeedPage(posts: loaded, nextCursor: "cursor-2", hasMore: true),
            FeedPage(posts: [Self.post(11)], nextCursor: nil, hasMore: false)
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.loadMoreIfNeeded(currentPost: loaded[0])
        XCTAssertEqual(service.cursors.count, 1, "a row at the top triggered a fetch")

        await viewModel.loadMoreIfNeeded(currentPost: loaded[9])
        XCTAssertEqual(service.cursors.count, 2)
    }

    // MARK: - Engagement

    func testALikeOnTheTimelineBehavesLikeALikeInTheFeed() async {
        let service = ScriptedProfileService()
        let post = FeedServiceMock.internationalRoot
        service.pages = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.toggleLike(post)

        XCTAssertTrue(viewModel.posts.first?.viewer.liked ?? false)
        XCTAssertEqual(viewModel.posts.first?.metrics.likes, post.metrics.likes + 1)
    }

    func testAPostChangedOnItsDetailScreenIsMergedBackIn() async {
        let service = ScriptedProfileService()
        let post = FeedServiceMock.internationalRoot
        service.pages = [FeedPage(posts: [post], nextCursor: nil, hasMore: false)]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        var elsewhere = post
        elsewhere.viewer = post.viewer.setting(bookmarked: true)
        elsewhere.metrics = post.metrics.adjusting(bookmarks: 1)
        viewModel.merge(elsewhere)

        XCTAssertTrue(viewModel.posts.first?.viewer.bookmarked ?? false)
        XCTAssertEqual(viewModel.posts.first?.metrics.bookmarks, post.metrics.bookmarks + 1)
    }
}
