import XCTest
@testable import Sila

/// What happens to a post *after* the composer succeeds.
///
/// A post that vanishes into the network leaves the user re-reading a stale
/// list and wondering whether it worked, so the feeds and the open thread adopt
/// the server's own returned posts immediately.
@MainActor
final class NewPostVisibilityTests: XCTestCase {

    private func makeHome(_ service: ScriptedFeedService = ScriptedFeedService()) -> HomeViewModel {
        HomeViewModel(service: service, analytics: RecordingAnalyticsClient())
    }

    private func post(scope: PostScope, country: String? = nil, replyTo: UUID? = nil) -> Post {
        Post(
            id: UUID(),
            author: FeedServiceMock.aziz,
            text: "fresh",
            createdAt: Date(),
            scope: scope,
            scopeCountry: country,
            replyToPostId: replyTo
        )
    }

    // MARK: - Feeds

    func testAnInternationalPostLandsAtTheTopOfForYouAndInternational() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedPage(posts: [FeedServiceMock.quotePost])]
        service.pages[.international] = [FeedPage(posts: [])]
        service.pages[.myCountry] = [FeedPage(posts: [])]
        let viewModel = makeHome(service)
        await viewModel.loadIfNeeded(.forYou)
        await viewModel.loadIfNeeded(.international)
        await viewModel.loadIfNeeded(.myCountry)

        let fresh = post(scope: .international)
        viewModel.insert(newPosts: [fresh])

        XCTAssertEqual(viewModel.state(for: .forYou).posts.first?.id, fresh.id)
        XCTAssertEqual(viewModel.state(for: .international).posts.first?.id, fresh.id)
        XCTAssertTrue(
            viewModel.state(for: .myCountry).posts.isEmpty,
            "An international post is not a country-feed post"
        )
    }

    func testACountryPostLandsInMyCountryButNotInInternational() async {
        let service = ScriptedFeedService()
        for tab in FeedTab.allCases { service.pages[tab] = [FeedPage(posts: [])] }
        let viewModel = makeHome(service)
        for tab in FeedTab.allCases { await viewModel.loadIfNeeded(tab) }

        let fresh = post(scope: .country, country: "SA")
        viewModel.insert(newPosts: [fresh])

        XCTAssertEqual(viewModel.state(for: .myCountry).posts.map(\.id), [fresh.id])
        XCTAssertTrue(viewModel.state(for: .international).posts.isEmpty)
        XCTAssertEqual(viewModel.state(for: .forYou).posts.map(\.id), [fresh.id])
    }

    func testRepliesDoNotJumpToTheTopOfTheFeed() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedPage(posts: [])]
        let viewModel = makeHome(service)
        await viewModel.loadIfNeeded(.forYou)

        viewModel.insert(newPosts: [post(scope: .international, replyTo: UUID())])

        XCTAssertTrue(
            viewModel.state(for: .forYou).posts.isEmpty,
            "A reply belongs under its parent, not at the top of For You"
        )
    }

    func testInsertingClearsAnEmptyStateThatIsNoLongerTrue() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedPage(posts: [])]
        let viewModel = makeHome(service)
        await viewModel.loadIfNeeded(.forYou)
        XCTAssertEqual(viewModel.state(for: .forYou).emptyKind, .noPosts)

        viewModel.insert(newPosts: [post(scope: .international)])

        XCTAssertNil(viewModel.state(for: .forYou).emptyKind, "The feed is no longer empty; it must not say it is")
    }

    func testATabThatHasNeverLoadedIsLeftAloneSoItStillFetchesItsFirstPage() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedPage(posts: [FeedServiceMock.quotePost])]
        let viewModel = makeHome(service)

        viewModel.insert(newPosts: [post(scope: .international)])
        XCTAssertTrue(viewModel.state(for: .forYou).posts.isEmpty)

        await viewModel.loadIfNeeded(.forYou)
        XCTAssertEqual(
            viewModel.state(for: .forYou).posts.map(\.id),
            [FeedServiceMock.quotePost.id],
            "Marking an unloaded tab as loaded would strand it empty forever"
        )
    }

    func testTheSamePostIsNeverInsertedTwice() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedPage(posts: [])]
        let viewModel = makeHome(service)
        await viewModel.loadIfNeeded(.forYou)
        let fresh = post(scope: .international)

        viewModel.insert(newPosts: [fresh])
        viewModel.insert(newPosts: [fresh])

        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 1)
    }

    // MARK: - Threads

    func testAReplyAppearsUnderTheOpenPostAndBumpsTheCounter() {
        let parent = FeedServiceMock.internationalRoot
        let viewModel = PostDetailViewModel(
            post: parent,
            service: ScriptedFeedService(),
            analytics: RecordingAnalyticsClient()
        )
        let before = parent.metrics.replies

        let reply = post(scope: .international, replyTo: parent.id)
        viewModel.insert(replies: [reply])

        XCTAssertEqual(viewModel.replies.map(\.id), [reply.id])
        XCTAssertEqual(viewModel.post.metrics.replies, before + 1)
    }

    func testOnlyDirectRepliesToTheOpenPostAreCountedAsItsReplies() {
        let parent = FeedServiceMock.internationalRoot
        let viewModel = PostDetailViewModel(
            post: parent,
            service: ScriptedFeedService(),
            analytics: RecordingAnalyticsClient()
        )

        // A thread written from the reply bar: the first answers this post, the
        // second answers the first.
        let first = post(scope: .international, replyTo: parent.id)
        let second = post(scope: .international, replyTo: first.id)
        viewModel.insert(replies: [first, second])

        XCTAssertEqual(viewModel.replies.map(\.id), [first.id])
        XCTAssertEqual(
            viewModel.post.metrics.replies,
            parent.metrics.replies + 1,
            "metrics.replies counts direct replies only"
        )
    }

    func testInsertingTheSameReplyTwiceDoesNotDoubleTheCount() {
        let parent = FeedServiceMock.internationalRoot
        let viewModel = PostDetailViewModel(
            post: parent,
            service: ScriptedFeedService(),
            analytics: RecordingAnalyticsClient()
        )
        let reply = post(scope: .international, replyTo: parent.id)

        viewModel.insert(replies: [reply])
        viewModel.insert(replies: [reply])

        XCTAssertEqual(viewModel.replies.count, 1)
        XCTAssertEqual(viewModel.post.metrics.replies, parent.metrics.replies + 1)
    }

    // MARK: - The author's badge

    func testAuthUserDecodesTheContractV2Fields() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "email": "aziz@example.com",
          "display_name": "Abdulaziz",
          "email_verified": true,
          "verification_status": "verified",
          "created_at": "2026-08-28T09:15:00Z",
          "handle": "aziz",
          "country_code": "sa",
          "avatar_url": null
        }
        """

        let user = try JSONCoding.decoder.decode(AuthUser.self, from: Data(json.utf8))

        XCTAssertEqual(user.handle, "aziz")
        XCTAssertEqual(user.atHandle, "@aziz")
        XCTAssertEqual(user.countryCode, "SA", "Codes are normalised on the way in")
        XCTAssertNil(user.avatarURL)
    }

    func testAnAccountWithoutTheV2FieldsStillDecodes() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "email": "aziz@example.com",
          "email_verified": true,
          "verification_status": "pending_review",
          "created_at": "2026-08-28T09:15:00Z"
        }
        """

        let user = try JSONCoding.decoder.decode(AuthUser.self, from: Data(json.utf8))

        XCTAssertNil(user.handle)
        XCTAssertNil(user.countryCode)
        XCTAssertNil(user.atHandle)
    }

    func testTheComposerAuthorMirrorsTheSignedInAccount() {
        let verified = AuthUser(
            id: UUID(), email: "a@b.c", emailVerified: true,
            verificationStatus: .verified, createdAt: Date(),
            handle: "aziz", countryCode: "SA"
        )

        let author = ComposerAuthor(user: verified)

        XCTAssertTrue(author.isVerified)
        XCTAssertTrue(author.hasCountryBadge)
        XCTAssertEqual(author.countryFlag, "🇸🇦")
        XCTAssertEqual(author.countryName, "Saudi Arabia")
    }

    func testNoSessionMeansTheMostRestrictiveAuthor() {
        let author = ComposerAuthor(user: nil)

        XCTAssertFalse(author.isVerified)
        XCTAssertFalse(author.hasCountryBadge)
        XCTAssertEqual(ScopePicker.options(for: author).filter(\.isAvailable).map(\.scope), [.international])
    }
}
