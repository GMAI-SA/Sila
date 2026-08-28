import XCTest
@testable import TrustNet

/// Drives the deployed server through the Composer and Search stacks.
///
/// Every other Composer and Search test runs against fixtures written from the
/// contract, so they agree with each other by construction and would stay green
/// if the *server* drifted. These are the only ones that would notice — and
/// posting in particular has no read-only equivalent: a decoder mismatch on
/// `POST /posts` surfaces the first time a real person tries to speak.
///
/// Opt-in, same as the other live suites. Anything created here is deleted
/// again, so the account is left as it was found:
/// ```
/// TEST_RUNNER_TRUSTNET_LIVE_API=1 TEST_RUNNER_TRUSTNET_LIVE_EMAIL=… \
/// TEST_RUNNER_TRUSTNET_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LiveComposerSearchTests: XCTestCase {

    private var token: String?
    private var me: AuthUser?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TRUSTNET_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set TRUSTNET_LIVE_API=1")
        }
        guard let email = env["TRUSTNET_LIVE_EMAIL"],
              let password = env["TRUSTNET_LIVE_PASSWORD"] else {
            throw XCTSkip("Set TRUSTNET_LIVE_EMAIL and TRUSTNET_LIVE_PASSWORD")
        }
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        let pair = try await auth.signIn(email: email, password: password)
        token = pair.token.accessToken
        me = pair.user
    }

    private func composer() throws -> ComposerService {
        ComposerService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func search() throws -> SearchService {
        SearchService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func feed() throws -> FeedService {
        FeedService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func marker() -> String { "livetest-\(UUID().uuidString.prefix(8))" }

    // MARK: - Composing

    /// The round trip that has no read-only equivalent: what we send must be
    /// accepted, and what comes back must decode.
    func testPostingInternationallyRoundTrips() async throws {
        let service = try composer()
        let text = "Live composer check \(marker())"

        let created = try await service.createPost(
            PostDraft(text: text, scope: .international)
        )
        XCTAssertEqual(created.text, text)
        XCTAssertEqual(created.scope, .international)
        XCTAssertFalse(created.author.handle.isEmpty)

        try await feed().deletePost( created.id)
    }

    /// A country thread must come back carrying the country it was opened for —
    /// the scope is what the whole reply rule is enforced against.
    func testCountryThreadKeepsItsScope() async throws {
        let author = try XCTUnwrap(me)
        guard let country = author.countryCode else {
            throw XCTSkip("account has no verified country badge")
        }
        let service = try composer()

        let created = try await service.createPost(
            PostDraft(text: "Country thread \(marker())", scope: .country(country))
        )
        XCTAssertEqual(created.scope, .country)
        XCTAssertEqual(created.scopeCountry, country)
        XCTAssertTrue(created.viewer.canReply, "the author must be able to reply to their own thread")

        try await feed().deletePost( created.id)
    }

    /// A reply inherits the parent's scope. If the client's inheritance and the
    /// server's ever disagree, replies silently change who may join a thread.
    func testReplyInheritsTheParentScope() async throws {
        let author = try XCTUnwrap(me)
        guard let country = author.countryCode else {
            throw XCTSkip("account has no verified country badge")
        }
        let service = try composer()

        let parent = try await service.createPost(
            PostDraft(text: "Parent \(marker())", scope: .country(country))
        )
        let reply = try await service.createPost(
            PostDraft(text: "Reply \(marker())", scope: .international, replyToPostId: parent.id)
        )
        XCTAssertEqual(reply.scope, .country, "a reply must not widen its thread's audience")
        XCTAssertEqual(reply.scopeCountry, country)

        try await feed().deletePost( reply.id)
        try await feed().deletePost( parent.id)
    }

    /// The server refuses a thread the author would be locked out of. The
    /// picker refuses it too — this checks the two agree.
    func testCannotOpenARegionThreadYouAreNotIn() async throws {
        let author = try XCTUnwrap(me)
        guard let country = author.countryCode,
              let outsider = GeoRegion.allCases.first(where: { !$0.contains(country) })
        else { throw XCTSkip("no region this account sits outside of") }

        do {
            let stray = try await composer().createPost(
                PostDraft(text: "should be refused \(marker())", scope: .region(outsider))
            )
            try? await feed().deletePost( stray.id)
            XCTFail("server accepted a \(outsider) thread from a \(country) account")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .replyNotAllowed)
        }
    }

    /// Threads are a client-side chain of self-replies; each segment must
    /// actually attach to the one before it.
    func testThreadSegmentsChainTogether() async throws {
        let service = try composer()
        let tag = marker()
        let report = await service.createThread(
            segments: ["Thread 1/2 \(tag)", "Thread 2/2 \(tag)"],
            scope: .international
        )
        XCTAssertNil(report.error, "thread run reported: \(String(describing: report.error))")
        XCTAssertEqual(report.posted.count, 2, "both segments should post")
        if report.posted.count == 2 {
            XCTAssertEqual(
                report.posted[1].replyToPostId, report.posted[0].id,
                "segment 2 must reply to segment 1, not start a second thread"
            )
        }
        for post in report.posted.reversed() {
            try? await feed().deletePost( post.id)
        }
    }

    // MARK: - Search

    func testANewPostIsFindableBySearch() async throws {
        let tag = marker()
        let created = try await composer().createPost(
            PostDraft(text: "Findable \(tag)", scope: .international)
        )
        let page = try await search().searchPosts(query: tag)
        XCTAssertEqual(page.posts.map(\.id), [created.id])

        try await feed().deletePost( created.id)
    }

    func testUserSearchDecodesAndPrefersVerifiedAccounts() async throws {
        let people = try await search().searchUsers(query: "fa")
        for person in people {
            XCTAssertFalse(person.handle.isEmpty)
            if person.countryCode != nil {
                XCTAssertTrue(
                    person.isVerified,
                    "@\(person.handle) carries a country flag without being verified"
                )
            }
        }
    }

    func testTrendingTagsDecodeWithoutTheirHash() async throws {
        let tags = try await search().trendingTags()
        XCTAssertFalse(tags.isEmpty, "no trending tags — seed the demo data")
        for tag in tags {
            XCTAssertFalse(tag.tag.hasPrefix("#"), "the server sends bare tags; the UI adds the #")
            XCTAssertEqual(tag.tag, tag.tag.lowercased())
            XCTAssertGreaterThan(tag.postCount, 0)
        }
    }

    /// A query shorter than the minimum is answered locally, not by the server.
    ///
    /// The client short-circuits instead of round-tripping: someone who has
    /// typed one letter should see nothing yet, not an error, and the request
    /// would be refused anyway. The server keeps its own `query_too_short`
    /// guard for callers that skip the client — that half is covered by the
    /// backend's integration suite.
    func testAShortQueryIsAnsweredWithoutCallingTheServer() async throws {
        let people = try await search().searchUsers(query: "a")
        XCTAssertTrue(people.isEmpty)

        let posts = try await search().searchPosts(query: "a")
        XCTAssertTrue(posts.posts.isEmpty)
        XCTAssertFalse(posts.hasMore, "an unsent query must not promise a next page")
    }
}
