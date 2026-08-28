import XCTest
@testable import Sila

/// Drives the real deployed feed through the app's own service and decoders.
///
/// Every other Feed test runs against fixtures written from the contract, so
/// they all agree with each other by construction and would stay green if the
/// *server* drifted. This is the only test that would notice.
///
/// Opt-in, same as ``LiveAPITests``:
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
/// Assumes the account is verified with a country badge and that the demo
/// content has been seeded.
final class LiveFeedTests: XCTestCase {

    private var token: String?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"],
              let password = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        token = try await auth.signIn(email: email, password: password).token.accessToken
    }

    private func makeService() throws -> FeedService {
        FeedService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    /// Every tab must decode. A field the server renamed or nulled shows up
    /// here as a decoding error rather than an empty screen in production.
    func testEveryFeedTabDecodes() async throws {
        let service = try makeService()
        for tab in FeedTab.allCases {
            let page = try await service.fetchFeed(tab, cursor: nil, limit: 10)
            XCTAssertFalse(page.posts.isEmpty, "\(tab) returned nothing — seed the demo data")
            for post in page.posts {
                XCTAssertFalse(post.text.isEmpty)
                XCTAssertFalse(post.author.handle.isEmpty)
            }
        }
    }

    /// The product's core claim, asserted against the live server: a country
    /// thread must not be repliable by everyone, and a country badge must only
    /// ever appear on a verified account.
    func testCountryScopedPostsCarryAnHonestBadgeAndReplyRule() async throws {
        let page = try await makeService().fetchFeed(.forYou, cursor: nil, limit: 50)

        for post in page.posts where post.author.countryCode != nil {
            XCTAssertTrue(
                post.author.isVerified,
                "@\(post.author.handle) shows a country flag without being verified — "
                + "the badge must be derived from verification, never stored past it"
            )
        }

        let countryPosts = page.posts.filter { $0.scope == .country }
        XCTAssertFalse(countryPosts.isEmpty, "no country-scoped posts — seed the demo data")
        for post in countryPosts {
            XCTAssertNotNil(post.scopeCountry, "a country thread must name its country")
            if !post.viewer.canReply {
                XCTAssertNotNil(
                    post.viewer.replyBlockReason,
                    "a blocked reply must state why, or the UI can only show a dead button"
                )
            }
        }
    }

    /// Keyset pagination must not repeat or skip rows between pages.
    func testPaginationDoesNotOverlap() async throws {
        let service = try makeService()
        let first = try await service.fetchFeed(.forYou, cursor: nil, limit: 3)
        guard let cursor = first.nextCursor else {
            throw XCTSkip("only one page of demo content")
        }
        let second = try await service.fetchFeed(.forYou, cursor: cursor, limit: 3)
        let firstIDs = Set(first.posts.map(\.id))
        let secondIDs = Set(second.posts.map(\.id))
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs), "cursor paging repeated a post")
    }

    /// Liking twice must not double-count: the server's uniqueness constraint
    /// is what makes an optimistic UI safe to retry.
    func testLikeIsIdempotentThenReversible() async throws {
        let service = try makeService()
        let page = try await service.fetchFeed(.international, cursor: nil, limit: 1)
        let post = try XCTUnwrap(page.posts.first)

        let once = try await service.setLiked(true, postId: post.id)
        let twice = try await service.setLiked(true, postId: post.id)
        XCTAssertEqual(once.likes, twice.likes, "a repeated like inflated the count")

        let removed = try await service.setLiked(false, postId: post.id)
        XCTAssertEqual(removed.likes, once.likes - 1)
    }
}
