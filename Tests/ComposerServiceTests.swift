import XCTest
@testable import Sila

/// What ``ComposerService`` actually puts on the wire for `POST /posts`, and
/// how it reports the contract's failure codes back.
final class ComposerServiceTests: XCTestCase {

    /// A minimal `Post` payload, parameterised by the fields under test.
    private func postJSON(id: String = "11111111-1111-4111-8111-111111111111") -> String {
        """
        {
          "id": "\(id)",
          "author": {"id": "22222222-2222-4222-8222-222222222222", "handle": "aziz",
                     "display_name": "Abdulaziz", "is_verified": true, "country_code": "SA"},
          "text": "hello",
          "created_at": "2026-08-28T09:15:00Z",
          "scope": "international",
          "reply_to_post_id": null,
          "reply_count_direct": 0,
          "quoted_post": null,
          "metrics": {"likes": 0, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0},
          "viewer": {"liked": false, "reposted": false, "bookmarked": false,
                     "can_reply": true, "reply_block_reason": null}
        }
        """
    }

    private func makeService(_ network: StubNetworkClient) -> ComposerService {
        ComposerService(
            network: network,
            tokens: StaticAccessTokenProvider(token: "compose-token"),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func body(of request: APIRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Requests

    func testCreatingAPostSendsAuthenticatedJSONToThePostsEndpoint() async throws {
        let network = StubNetworkClient(responses: [postJSON()])

        let post = try await makeService(network).createPost(
            PostDraft(text: "hello", scope: .international)
        )

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/posts")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.accessToken, "compose-token")
        XCTAssertEqual(try body(of: request)["text"] as? String, "hello")
        XCTAssertEqual(post.text, "hello")
    }

    func testACountryScopedPostCarriesTheCountryCode() async throws {
        let network = StubNetworkClient(responses: [postJSON()])

        _ = try await makeService(network).createPost(
            PostDraft(text: "مرحبا", scope: .country("SA"))
        )

        let sent = try body(of: XCTUnwrap(network.lastRequest))
        XCTAssertEqual(sent["scope"] as? String, "country")
        XCTAssertEqual(sent["scope_country"] as? String, "SA")
        XCTAssertNil(sent["scope_region"])
    }

    func testARegionScopedPostCarriesTheRegion() async throws {
        let network = StubNetworkClient(responses: [postJSON()])

        _ = try await makeService(network).createPost(
            PostDraft(text: "hi", scope: .region(.mena))
        )

        let sent = try body(of: XCTUnwrap(network.lastRequest))
        XCTAssertEqual(sent["scope"] as? String, "region")
        XCTAssertEqual(sent["scope_region"] as? String, "MENA")
        XCTAssertNil(sent["scope_country"])
    }

    func testAReplyCarriesTheParentIdInLowercase() async throws {
        let network = StubNetworkClient(responses: [postJSON()])
        let parent = UUID()

        _ = try await makeService(network).createPost(
            PostDraft(text: "agreed", scope: .international, replyToPostId: parent)
        )

        XCTAssertEqual(
            try body(of: XCTUnwrap(network.lastRequest))["reply_to_post_id"] as? String,
            parent.uuidString.lowercased()
        )
    }

    // MARK: - Thread chaining

    func testTheThreadHelperChainsEachSegmentOntoTheLastPostsId() async throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "33333333-3333-4333-8333-333333333333"
        let network = StubNetworkClient(responses: [postJSON(id: first), postJSON(id: second)])

        let report = await makeService(network).createThread(
            segments: ["one", "two"],
            scope: .international
        )

        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertEqual(network.requests.count, 2)
        XCTAssertNil(try body(of: network.requests[0])["reply_to_post_id"])
        XCTAssertEqual(try body(of: network.requests[1])["reply_to_post_id"] as? String, first)
    }

    func testEmptySegmentsAreDroppedRatherThanPostedAsBlanks() async throws {
        let network = StubNetworkClient(responses: [postJSON()])

        let report = await makeService(network).createThread(
            segments: ["real", "   ", ""],
            scope: .international
        )

        XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(report.totalSegments, 1)
    }

    func testAThreadStopsAtTheFirstFailureAndKeepsWhatIsLeft() async throws {
        // The stub throws on every call, so nothing gets through.
        let network = StubNetworkClient(
            responses: [postJSON()],
            error: .api(code: .rateLimited, message: "Slow down", status: 429)
        )

        let report = await makeService(network).createThread(
            segments: ["one", "two", "three"],
            scope: .international
        )

        XCTAssertTrue(report.posted.isEmpty)
        XCTAssertEqual(report.remaining, ["one", "two", "three"])
        XCTAssertEqual(report.error?.code, .rateLimited)
        XCTAssertEqual(network.requests.count, 1, "The chain stops instead of hammering a failing endpoint")
    }

    // MARK: - Errors

    func testTheUnverifiedCodeSurvivesAsAStructuredError() async {
        let network = StubNetworkClient(
            error: .api(code: .unverified, message: "Verify first", status: 403)
        )

        do {
            _ = try await makeService(network).createPost(PostDraft(text: "hi", scope: .international))
            XCTFail("An unverified account must not appear to have posted")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, .unverified)
        }
    }

    func testEveryContractCodeUsedByTheComposerHasItsOwnSentence() {
        let codes: [APIErrorCode] = [.unverified, .replyNotAllowed, .invalidScope, .textTooLong, .rateLimited]

        for code in codes {
            let message = APIError.api(code: code, message: "", status: 400).userMessage
            XCTAssertFalse(message.isEmpty, "\(code) has nothing to say to the user")
            XCTAssertNotEqual(message, "Something went wrong. Please try again.", "\(code) fell through to the default")
        }
    }

    func testANonAPIErrorIsWrappedSoTheUserStillGetsASentence() {
        struct Boom: Error {}

        let wrapped = APIError.wrapping(Boom())

        if case .transport = wrapped {
            XCTAssertFalse(wrapped.userMessage.isEmpty)
        } else {
            XCTFail("An unknown error must still become something showable")
        }
    }

    func testAnAPIErrorIsNotDoubleWrapped() {
        let original = APIError.api(code: .textTooLong, message: "too long", status: 400)

        XCTAssertEqual(APIError.wrapping(original), original)
    }
}
