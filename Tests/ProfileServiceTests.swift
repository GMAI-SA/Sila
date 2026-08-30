import XCTest
@testable import Sila

/// ``ProfileService`` against a scripted transport: paths, verbs, cursors and
/// the one query parameter the server refuses to clamp for us.
final class ProfileServiceTests: XCTestCase {

    private func makeService(
        _ network: StubNetworkClient,
        token: String? = "access-123"
    ) -> ProfileService {
        ProfileService(
            network: network,
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let profile = """
    {"user": {"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2", "handle": "yuki",
              "display_name": "Yuki", "is_verified": true, "country_code": "JP"},
     "bio": null, "post_count": 3, "follower_count": 12, "following_count": 4,
     "is_following": false, "is_me": false}
    """

    private static let page = #"{"posts": [], "next_cursor": null, "has_more": false}"#

    // MARK: - Paths and verbs

    func testEveryEndpointUsesTheDocumentedPathAndVerb() async throws {
        let network = StubNetworkClient(responses: [
            Self.profile,
            Self.page,
            #"{"following": true, "follower_count": 13}"#,
            #"{"following": false, "follower_count": 12}"#
        ])
        let service = makeService(network)

        _ = try await service.fetchProfile(handle: "yuki")
        _ = try await service.fetchPosts(handle: "yuki", cursor: nil, limit: 20)
        _ = try await service.setFollowing(true, handle: "yuki")
        _ = try await service.setFollowing(false, handle: "yuki")

        XCTAssertEqual(network.requests.map { "\($0.method.rawValue) \($0.path)" }, [
            "GET /users/yuki",
            "GET /users/yuki/posts",
            "POST /users/yuki/follow",
            "DELETE /users/yuki/follow"
        ])
        XCTAssertTrue(network.requests.allSatisfy { $0.accessToken == "access-123" })
    }

    /// A handle arrives from a mention or a tapped author with an `@` on it and
    /// whatever casing the author typed. The server folds case, so the client
    /// sends the folded form rather than relying on it.
    func testHandlesAreNormalisedBeforeTheyReachTheURL() async throws {
        let network = StubNetworkClient(responses: [Self.profile])

        _ = try await makeService(network).fetchProfile(handle: "  @Yuki ")

        XCTAssertEqual(network.lastRequest?.path, "/users/yuki")
    }

    /// The one thing a hostile mention could do is change which endpoint is
    /// called. It cannot: the separators are dropped, not encoded, so the
    /// result is always exactly one path component.
    func testAHandleCannotTraverseIntoADifferentEndpoint() async throws {
        let network = StubNetworkClient(responses: [Self.profile])

        _ = try? await makeService(network).fetchProfile(handle: "../../me/account")

        XCTAssertEqual(network.lastRequest?.path, "/users/meaccount")
        XCTAssertEqual(network.requests.count, 1)
    }

    /// A "handle" with nothing usable in it would build `/users//posts`, which
    /// is a different endpoint. It is reported as the 404 it would have been.
    func testAHandleThatSanitisesToNothingNeverProducesARequest() async {
        let network = StubNetworkClient(responses: [Self.profile])

        do {
            _ = try await makeService(network).fetchProfile(handle: "@ /.. ")
            XCTFail("a handle that sanitises to nothing produced a request")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .userNotFound)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(network.requests.isEmpty, "nothing should have gone over the wire")
    }

    // MARK: - Paging

    /// `limit` is validated `ge=1, le=50` server-side and answers **422**
    /// outside it — a body this client does not model and could not show
    /// anybody. So the clamp happens before the request.
    func testTheLimitIsClampedToTheRangeTheServerAccepts() async throws {
        let network = StubNetworkClient(responses: [Self.page, Self.page, Self.page])
        let service = makeService(network)

        _ = try await service.fetchPosts(handle: "yuki", cursor: nil, limit: 0)
        _ = try await service.fetchPosts(handle: "yuki", cursor: nil, limit: 999)
        _ = try await service.fetchPosts(handle: "yuki", cursor: nil, limit: 20)

        XCTAssertEqual(network.requests.map { $0.queryValue("limit") }, ["1", "50", "20"])
    }

    func testTheDefaultLimitIsTheContractsTwenty() async throws {
        let network = StubNetworkClient(responses: [Self.page])

        _ = try await makeService(network).fetchPosts(handle: "yuki")

        XCTAssertEqual(network.lastRequest?.queryValue("limit"), "20")
    }

    /// An empty cursor is not the same as no cursor: sending `cursor=` would
    /// ask the server to decode nothing as a keyset position.
    func testTheCursorIsSentOnlyWhenTheServerGaveUsOne() async throws {
        let network = StubNetworkClient(responses: [Self.page, Self.page, Self.page])
        let service = makeService(network)

        _ = try await service.fetchPosts(handle: "yuki", cursor: nil, limit: 20)
        _ = try await service.fetchPosts(handle: "yuki", cursor: "", limit: 20)
        _ = try await service.fetchPosts(handle: "yuki", cursor: "opaque-cursor", limit: 20)

        XCTAssertEqual(
            network.requests.map { $0.queryValue("cursor") },
            [nil, nil, "opaque-cursor"]
        )
    }

    /// The timeline is the feed's own page shape, decoded by the feed's own
    /// type — which is the whole reason there is no second page model.
    func testTheTimelineDecodesAsTheSameFeedPageTheFeedsUse() async throws {
        let network = StubNetworkClient(responses: ["""
        {"posts": [{"id": "8ce9cb7e-f7c1-44f6-96ae-f6e05852a0b0",
                    "author": {"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2",
                               "handle": "yuki", "display_name": "Yuki",
                               "is_verified": true, "country_code": "JP"},
                    "text": "Bot farms cannot fake a government ID.",
                    "created_at": "2026-08-28T10:58:06.356760Z",
                    "scope": "international", "reply_to_post_id": null,
                    "reply_count_direct": 1,
                    "metrics": {"likes": 0, "reposts": 0, "replies": 1, "views": 0, "bookmarks": 0},
                    "viewer": {"liked": false, "reposted": false, "bookmarked": false,
                               "can_reply": true, "reply_block_reason": null}}],
         "next_cursor": "MjAyNi0wOA==", "has_more": true}
        """])

        let page = try await makeService(network).fetchPosts(handle: "yuki")

        XCTAssertEqual(page.posts.count, 1)
        XCTAssertEqual(page.posts.first?.author.handle, "yuki")
        XCTAssertFalse(page.posts.first?.isReply ?? true, "this endpoint never returns replies")
        XCTAssertEqual(page.nextCursor, "MjAyNi0wOA==")
        XCTAssertTrue(page.hasMore)
    }

    // MARK: - Errors

    func testAnUnknownHandleSurfacesAsUserNotFound() async {
        let network = StubNetworkClient(
            responses: [],
            error: .api(code: .userNotFound, message: "No account with that handle", status: 404)
        )

        do {
            _ = try await makeService(network).fetchProfile(handle: "ghost")
            XCTFail("a missing account decoded as a profile")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .userNotFound)
            XCTAssertEqual(error.userMessage, "This account isn't available.")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The undocumented-until-now code the deployed server actually sends.
    func testTheServersNotFoundCodeIsRecognisedRatherThanFallingThroughToUnknown() {
        XCTAssertEqual(APIErrorCode(serverCode: "user_not_found"), .userNotFound)
    }

    func testASignedOutCallerNeverReachesTheNetwork() async {
        let network = StubNetworkClient(responses: [Self.profile])

        do {
            _ = try await makeService(network, token: nil).fetchProfile(handle: "yuki")
            XCTFail("an unauthenticated profile request was sent")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthenticated)
        }
        XCTAssertTrue(network.requests.isEmpty)
    }
}

// MARK: - The mock's fidelity

/// ``ProfileServiceMock`` is what the view-model tests, the previews and the
/// UI-test runs stand on, so the behaviours it claims to reproduce are asserted
/// rather than assumed.
final class ProfileServiceMockTests: XCTestCase {

    func testTheMockedTimelineExcludesRepliesLikeTheServerDoes() async throws {
        let mock = ProfileServiceMock(scenario: .populated)

        let page = try await mock.fetchPosts(handle: "yuki", cursor: nil, limit: 20)

        XCTAssertFalse(page.posts.isEmpty, "the fixture account should have written something")
        XCTAssertTrue(page.posts.allSatisfy { !$0.isReply }, "a reply reached a profile timeline")
        XCTAssertTrue(page.posts.allSatisfy { $0.author.handle == "yuki" })
    }

    func testFollowingTwiceSucceedsAndReportsTheSameCount() async throws {
        let mock = ProfileServiceMock(scenario: .populated)

        let first = try await mock.setFollowing(true, handle: "yuki")
        let second = try await mock.setFollowing(true, handle: "yuki")

        XCTAssertTrue(first.following)
        XCTAssertTrue(second.following)
        XCTAssertEqual(first.followerCount, second.followerCount, "the second call double-counted")
    }

    func testUnfollowingSomebodyYouDoNotFollowIsNotAnError() async throws {
        let mock = ProfileServiceMock(scenario: .populated)

        let result = try await mock.setFollowing(false, handle: "yuki")

        XCTAssertFalse(result.following)
    }

    func testFollowingYourselfIsRefusedTheWayTheServerRefusesIt() async {
        let mock = ProfileServiceMock(scenario: .populated, viewerHandle: "aziz")

        do {
            _ = try await mock.setFollowing(true, handle: "aziz")
            XCTFail("the mock allowed a self-follow")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .selfFollow)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testYourOwnHandleAnswersIsMe() async throws {
        let mock = ProfileServiceMock(scenario: .populated, viewerHandle: "aziz")

        let mine = try await mock.fetchProfile(handle: "aziz")
        let theirs = try await mock.fetchProfile(handle: "yuki")

        XCTAssertTrue(mine.isMe)
        XCTAssertFalse(theirs.isMe)
    }

    func testTheUnverifiedScenarioStripsTheCountryAlongWithTheCheckmark() async throws {
        let mock = ProfileServiceMock(scenario: .unverified)

        let profile = try await mock.fetchProfile(handle: "yuki")

        XCTAssertFalse(profile.user.isVerified)
        XCTAssertNil(profile.user.countryCode, "an unverified account kept a flag")
    }

    func testTheNotFoundScenarioAnswersTheSameCodeAsADeactivatedAccount() async {
        let mock = ProfileServiceMock(scenario: .notFound)

        do {
            _ = try await mock.fetchProfile(handle: "yuki")
            XCTFail("the mock served a profile it should not have")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .userNotFound)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
