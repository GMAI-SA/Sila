import XCTest
@testable import Sila

/// Looking around before joining.
///
/// A wall in front of the front door is how a social product loses the people
/// who would have liked it. Reading is genuinely open; everything that acts
/// is an invitation naming the thing somebody just reached for, and never an
/// error they have to interpret.
final class GuestModeTests: XCTestCase {

    // MARK: The read-only service

    func testReadingGoesToThePublicSurfaceWithNoToken() async throws {
        let network = StubNetworkClient(responses: [#"{"posts": [], "next_cursor": null, "has_more": false}"#])
        let service = PublicFeedService(network: network, analytics: RecordingAnalyticsClient())

        _ = try await service.fetchFeed(.forYou, cursor: nil, limit: 20)

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/public/feed", "a guest reads the square, not a personal feed")
        XCTAssertNil(request.accessToken, "a guest has no token to send")
    }

    func testEveryFeedTabIsTheSquareBecauseThereIsNoYouYet() async throws {
        let network = StubNetworkClient(responses: [#"{"posts": []}"#])
        let service = PublicFeedService(network: network, analytics: RecordingAnalyticsClient())
        for tab in FeedTab.allCases {
            _ = try await service.fetchFeed(tab, cursor: nil, limit: 20)
            XCTAssertEqual(network.lastRequest?.path, "/public/feed", "\(tab) reached somewhere private")
        }
    }

    func testAPostAndItsRepliesReadWithoutAnAccount() async throws {
        let network = StubNetworkClient(responses: [#"{"posts": []}"#])
        let service = PublicFeedService(network: network, analytics: RecordingAnalyticsClient())
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

        _ = try? await service.fetchReplies(for: id, cursor: nil)
        XCTAssertEqual(network.lastRequest?.path, "/public/posts/11111111-1111-4111-8111-111111111111/replies")
    }

    func testATagPageReadsWithoutAnAccountAndArabicSurvivesTheURL() async throws {
        let network = StubNetworkClient(responses: [#"{"posts": []}"#])
        let service = PublicFeedService(network: network, analytics: RecordingAnalyticsClient())

        _ = try await service.fetchHashtagPosts("#الرياض", sort: .top, cursor: nil)

        let path = try XCTUnwrap(network.lastRequest?.path)
        XCTAssertEqual(path, "/public/hashtags/%D8%A7%D9%84%D8%B1%D9%8A%D8%A7%D8%B6/posts")
        XCTAssertNil(network.lastRequest?.queryValue("sort"), "an ordering belongs to an account")
    }

    func testEverythingThatActsAsksToJoinWithoutTouchingTheNetwork() async {
        let network = StubNetworkClient(responses: ["{}"])
        let service = PublicFeedService(network: network, analytics: RecordingAnalyticsClient())
        let id = UUID()

        for action in ["like", "repost", "bookmark", "delete", "bookmarks"] {
            do {
                switch action {
                case "like": _ = try await service.setLiked(true, postId: id)
                case "repost": _ = try await service.setReposted(true, postId: id)
                case "bookmark": _ = try await service.setBookmarked(true, postId: id)
                case "delete": try await service.deletePost(id)
                default: _ = try await service.fetchBookmarks(cursor: nil)
                }
                XCTFail("\(action) was allowed without an account")
            } catch {
                let wrapped = APIError.wrapping(error)
                XCTAssertTrue(wrapped.isSignInRequired, "\(action) failed rather than invited")
            }
        }
        XCTAssertTrue(network.requests.isEmpty, "an invitation must not cost a round trip")
    }

    // MARK: The refusal is an invitation

    func testTheServersRefusalIsReadAsAnInvitation() {
        let error = URLSessionNetworkClient.makeError(
            status: 401,
            data: Data(#"{"detail":{"code":"sign_in_required","message":"Join Sila to do that"}}"#.utf8)
        )
        XCTAssertEqual(error.code, .signInRequired)
        XCTAssertTrue(error.isSignInRequired)
        XCTAssertFalse(error.isCancellation)
        // Distinct from a session that went bad, which routes somewhere else.
        let expired = URLSessionNetworkClient.makeError(
            status: 401, data: Data(#"{"detail":{"code":"unauthorized","message":"Missing bearer token"}}"#.utf8)
        )
        XCTAssertFalse(expired.isSignInRequired)
    }

    func testEveryPromptSaysWhatJoiningWouldLetYouDo() {
        for prompt in JoinPrompt.allCases {
            XCTAssertFalse(prompt.title.isEmpty, "\(prompt.rawValue) has no headline")
            XCTAssertFalse(prompt.detail.isEmpty, "\(prompt.rawValue) gives no reason")
            XCTAssertFalse(prompt.title.contains("guest.join"), "\(prompt.rawValue) is showing its key")
            XCTAssertFalse(prompt.detail.contains("guest.join"), "\(prompt.rawValue) is showing its key")
            XCTAssertFalse(prompt.icon.isEmpty)
        }
    }

    // MARK: The session

    @MainActor
    func testLookingAroundIsItsOwnRouteAndLeavingItGoesToTheDoor() async {
        let session = AuthSession(
            service: AuthServiceMock(scenario: .verified),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            analytics: RecordingAnalyticsClient()
        )
        session.browseAsGuest()
        XCTAssertEqual(session.route, .guest)

        session.joinPrompt = .reply
        session.leaveGuest()
        XCTAssertEqual(session.route, .unauthenticated, "the door, not the feed")
        XCTAssertNil(session.joinPrompt, "the invitation does not follow them out")
    }
}
