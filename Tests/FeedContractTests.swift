import XCTest
@testable import TrustNet

/// The wire contract with contract v2 (`/feed`, `/posts`).
///
/// These decode the exact payload shapes the backend documents, so a change on
/// the server surfaces here rather than as a blank feed on device.
final class FeedContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: UserSummary

    func testUserSummaryDecodesTheVerifiedCountryFlag() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "handle": "aziz",
          "display_name": "Abdulaziz",
          "avatar_url": null,
          "is_verified": true,
          "country_code": "SA",
          "verified_since": "2026-08-28T09:15:00Z"
        }
        """

        let user = try decode(UserSummary.self, from: json)

        XCTAssertEqual(user.handle, "aziz")
        XCTAssertEqual(user.displayName, "Abdulaziz")
        XCTAssertEqual(user.atHandle, "@aziz")
        XCTAssertNil(user.avatarURL)
        XCTAssertTrue(user.isVerified)
        XCTAssertEqual(user.countryCode, "SA")
        XCTAssertNotNil(user.verifiedSince)
    }

    func testUnverifiedUserHasNoCountryAndTheUIShowsNothing() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "handle": "newcomer",
          "display_name": "Sam Reed",
          "avatar_url": null,
          "is_verified": false,
          "country_code": null,
          "verified_since": null
        }
        """

        let user = try decode(UserSummary.self, from: json)

        XCTAssertNil(user.countryCode, "A null country_code must stay null — never inferred")
        XCTAssertNil(CountryCode.flag(user.countryCode), "No flag may be rendered for a null country")
        XCTAssertNil(CountryCode.accessibilityLabel(user.countryCode))
        XCTAssertFalse(user.isVerified)
    }

    func testAGarbageCountryCodeIsRejectedRatherThanRendered() throws {
        let json = """
        { "id": "x", "handle": "h", "display_name": "H", "is_verified": true, "country_code": "ZZ" }
        """

        let user = try decode(UserSummary.self, from: json)

        XCTAssertNil(user.countryCode, "ZZ is not an ISO region; showing a flag for it would be a guess")
    }

    func testLowercaseCountryCodeIsNormalisedNotDropped() throws {
        let json = """
        { "id": "x", "handle": "h", "display_name": "H", "is_verified": true, "country_code": "jp" }
        """

        XCTAssertEqual(try decode(UserSummary.self, from: json).countryCode, "JP")
    }

    func testMissingDisplayNameFallsBackToTheHandle() throws {
        let json = """
        { "id": "x", "handle": "aziz", "display_name": null, "is_verified": true }
        """

        XCTAssertEqual(try decode(UserSummary.self, from: json).displayName, "aziz")
    }

    // MARK: Post

    private let fullPostJSON = """
    {
      "id": "11111111-1111-4111-8111-111111111111",
      "author": {
        "id": "22222222-2222-4222-8222-222222222222",
        "handle": "maria", "display_name": "Maria Souza", "avatar_url": null,
        "is_verified": true, "country_code": "BR", "verified_since": "2026-07-01T00:00:00Z"
      },
      "text": "This is the part nobody outside the region gets yet. #ProofOfPersonhood",
      "created_at": "2026-08-28T10:00:00.512Z",
      "scope": "international",
      "scope_country": null,
      "scope_region": null,
      "reply_to_post_id": null,
      "reply_count_direct": 3,
      "quoted_post": {
        "id": "33333333-3333-4333-8333-333333333333",
        "author": {
          "id": "44444444-4444-4444-8444-444444444444",
          "handle": "aziz", "display_name": "Abdulaziz", "avatar_url": null,
          "is_verified": true, "country_code": "SA", "verified_since": "2026-01-01T00:00:00Z"
        },
        "text": "Answers from every country welcome",
        "created_at": "2026-08-28T08:00:00Z",
        "scope": "international",
        "reply_to_post_id": null,
        "reply_count_direct": 2,
        "quoted_post": null,
        "metrics": { "likes": 412, "reposts": 88, "replies": 2, "views": 20140, "bookmarks": 61 },
        "viewer": { "liked": false, "reposted": false, "bookmarked": false,
                    "can_reply": true, "reply_block_reason": null }
      },
      "metrics": { "likes": 77, "reposts": 21, "replies": 3, "views": 4006, "bookmarks": 12 },
      "viewer": { "liked": true, "reposted": false, "bookmarked": true,
                  "can_reply": true, "reply_block_reason": null }
    }
    """

    func testPostDecodesEveryDocumentedField() throws {
        let post = try decode(Post.self, from: fullPostJSON)

        XCTAssertEqual(post.author.handle, "maria")
        XCTAssertEqual(post.author.countryCode, "BR")
        XCTAssertEqual(post.scope, .international)
        XCTAssertNil(post.scopeCountry)
        XCTAssertNil(post.replyToPostId)
        XCTAssertFalse(post.isReply)
        XCTAssertEqual(post.replyCountDirect, 3)
        XCTAssertEqual(post.metrics.likes, 77)
        XCTAssertEqual(post.metrics.views, 4006)
        XCTAssertTrue(post.viewer.liked)
        XCTAssertTrue(post.viewer.bookmarked)
        XCTAssertTrue(post.viewer.canReply)
        XCTAssertNil(post.viewer.replyBlockReason)
    }

    func testNestedQuotedPostDecodesOneLevelDeep() throws {
        let post = try decode(Post.self, from: fullPostJSON)

        let quoted = try XCTUnwrap(post.quotedPost)
        XCTAssertEqual(quoted.author.handle, "aziz")
        XCTAssertEqual(quoted.author.countryCode, "SA")
        XCTAssertEqual(quoted.metrics.likes, 412)
        XCTAssertNil(quoted.quotedPost, "The contract promises one level; the client enforces it")
    }

    func testADoublyNestedQuoteIsFlattenedRatherThanRecursed() throws {
        // A server bug (or a future contract change) must not produce an
        // unbounded render tree on device.
        let json = """
        {
          "id": "a", "text": "outer", "created_at": "2026-08-28T10:00:00Z", "scope": "international",
          "author": { "id": "1", "handle": "a", "display_name": "A", "is_verified": true, "country_code": "SA" },
          "metrics": {}, "viewer": {},
          "quoted_post": {
            "id": "b", "text": "middle", "created_at": "2026-08-28T09:00:00Z", "scope": "international",
            "author": { "id": "2", "handle": "b", "display_name": "B", "is_verified": true, "country_code": "JP" },
            "metrics": {}, "viewer": {},
            "quoted_post": {
              "id": "c", "text": "inner", "created_at": "2026-08-28T08:00:00Z", "scope": "international",
              "author": { "id": "3", "handle": "c", "display_name": "C", "is_verified": false, "country_code": null },
              "metrics": {}, "viewer": {}, "quoted_post": null
            }
          }
        }
        """

        let post = try decode(Post.self, from: json)

        XCTAssertEqual(post.text, "outer")
        XCTAssertEqual(post.quotedPost?.text, "middle")
        XCTAssertNil(post.quotedPost?.quotedPost, "Deeper nesting is dropped, not rendered")
    }

    func testCountryScopedPostCarriesItsCountryAndBlockReason() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "author": { "id": "2", "handle": "noor", "display_name": "Noor",
                      "is_verified": true, "country_code": "AE" },
          "text": "Riyadh today",
          "created_at": "2026-08-28T10:00:00Z",
          "scope": "country",
          "scope_country": "SA",
          "scope_region": null,
          "reply_to_post_id": null,
          "reply_count_direct": 0,
          "quoted_post": null,
          "metrics": { "likes": 96, "reposts": 4, "replies": 0, "views": 3310, "bookmarks": 7 },
          "viewer": { "liked": false, "reposted": false, "bookmarked": false,
                      "can_reply": false, "reply_block_reason": "country_mismatch" }
        }
        """

        let post = try decode(Post.self, from: json)

        XCTAssertEqual(post.scope, .country)
        XCTAssertEqual(post.scopeCountry, "SA")
        XCTAssertFalse(post.viewer.canReply)
        XCTAssertEqual(post.viewer.replyBlockReason, .countryMismatch)
    }

    func testRegionScopedPostDecodes() throws {
        let json = """
        {
          "id": "1", "author": { "id": "2", "handle": "yuki", "display_name": "Yuki",
                                 "is_verified": true, "country_code": "JP" },
          "text": "GCC founders", "created_at": "2026-08-28T10:00:00Z",
          "scope": "region", "scope_region": "GCC",
          "metrics": {}, "viewer": { "can_reply": false, "reply_block_reason": "region_mismatch" }
        }
        """

        let post = try decode(Post.self, from: json)

        XCTAssertEqual(post.scope, .region)
        XCTAssertEqual(post.scopeRegion, "GCC")
        XCTAssertEqual(post.viewer.replyBlockReason, .regionMismatch)
    }

    func testReplyCarriesItsParentId() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "author": { "id": "2", "handle": "yuki", "display_name": "Yuki",
                      "is_verified": true, "country_code": "JP" },
          "text": "The end of anonymous brigading.",
          "created_at": "2026-08-28T10:00:00Z",
          "scope": "international",
          "reply_to_post_id": "33333333-3333-4333-8333-333333333333",
          "metrics": {}, "viewer": {}
        }
        """

        let post = try decode(Post.self, from: json)

        XCTAssertTrue(post.isReply)
        XCTAssertEqual(post.replyToPostId?.uuidString.lowercased(), "33333333-3333-4333-8333-333333333333")
    }

    func testAnUnknownScopeDecodesAsInternationalRatherThanFailing() throws {
        let json = """
        {
          "id": "1", "author": { "id": "2", "handle": "a", "display_name": "A", "is_verified": true },
          "text": "hi", "created_at": "2026-08-28T10:00:00Z", "scope": "continent",
          "metrics": {}, "viewer": {}
        }
        """

        XCTAssertEqual(try decode(Post.self, from: json).scope, .international)
    }

    func testAnUnknownBlockReasonStillBlocksTheButton() throws {
        let json = """
        {
          "id": "1", "author": { "id": "2", "handle": "a", "display_name": "A", "is_verified": true },
          "text": "hi", "created_at": "2026-08-28T10:00:00Z", "scope": "country", "scope_country": "SA",
          "metrics": {}, "viewer": { "can_reply": false, "reply_block_reason": "moon_phase" }
        }
        """

        let post = try decode(Post.self, from: json)

        XCTAssertEqual(post.viewer.replyBlockReason, .unknown)
        XCTAssertFalse(ReplyPermission.make(for: post).canReply)
        XCTAssertNotNil(ReplyPermission.make(for: post).blockedMessage)
    }

    // MARK: FeedPage

    func testFeedPageDecodesPostsCursorAndHasMore() throws {
        let json = """
        {
          "posts": [\(fullPostJSON)],
          "next_cursor": "MjAyNi0wOC0yOFQxMDowMDowMHwx",
          "has_more": true
        }
        """

        let page = try decode(FeedPage.self, from: json)

        XCTAssertEqual(page.posts.count, 1)
        XCTAssertEqual(page.nextCursor, "MjAyNi0wOC0yOFQxMDowMDowMHwx")
        XCTAssertTrue(page.hasMore)
    }

    func testTheLastPageHasNoCursor() throws {
        let json = """
        { "posts": [], "next_cursor": null, "has_more": false }
        """

        let page = try decode(FeedPage.self, from: json)

        XCTAssertTrue(page.posts.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    func testHasMoreWithoutACursorIsTreatedAsTheEnd() throws {
        // Otherwise the pager would loop forever asking for a page it has no
        // cursor to request.
        let json = """
        { "posts": [], "next_cursor": null, "has_more": true }
        """

        XCTAssertFalse(try decode(FeedPage.self, from: json).hasMore)
    }

    // MARK: Errors

    func testNoCountryErrorDecodesFromThe409Envelope() throws {
        let data = Data("""
        { "detail": { "code": "no_country", "message": "Your account has no verified country yet." } }
        """.utf8)

        let error = URLSessionNetworkClient.makeError(status: 409, data: data)

        XCTAssertEqual(error.code, .noCountry)
        XCTAssertEqual(error, .api(
            code: .noCountry,
            message: "Your account has no verified country yet.",
            status: 409
        ))
    }

    func testEveryContractV2ErrorCodeIsRecognised() {
        let codes: [String: APIErrorCode] = [
            "post_not_found": .postNotFound,
            "reply_not_allowed": .replyNotAllowed,
            "no_country": .noCountry,
            "text_too_long": .textTooLong,
            "not_post_author": .notPostAuthor,
            "handle_taken": .handleTaken,
            "invalid_handle": .invalidHandle,
            "self_follow": .selfFollow
        ]
        for (raw, expected) in codes {
            XCTAssertEqual(APIErrorCode(serverCode: raw), expected, "\(raw) is not mapped")
            XCTAssertFalse(
                APIError.api(code: expected, message: "", status: 400).userMessage.isEmpty,
                "\(raw) has no user-facing sentence"
            )
        }
    }
}
