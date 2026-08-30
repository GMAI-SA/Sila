import XCTest
@testable import Sila

/// ``Profile`` and ``FollowResult`` against bodies shaped like the server's.
///
/// The decoder is tolerant everywhere except `user`, so most of these are about
/// what a *missing* field turns into — and the last group is about the one
/// piece of arithmetic the client is explicitly not allowed to trust.
final class ProfileModelsTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The wire shape

    /// The exact body `GET /users/yuki` returns on the deployed server.
    private static let verifiedProfile = """
    {
      "user": {
        "id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2",
        "handle": "yuki",
        "display_name": "Yuki Tanaka",
        "avatar_url": "/api/v1/media/avatars/yuki.jpg",
        "is_verified": true,
        "country_code": "JP",
        "verified_since": "2026-08-28T10:13:40.851160Z"
      },
      "bio": "Tokyo. Identity and trust.",
      "post_count": 3,
      "follower_count": 12,
      "following_count": 4,
      "is_following": false,
      "is_me": false
    }
    """

    func testAVerifiedProfileDecodesWholeAndKeepsItsCountry() throws {
        let profile: Profile = try decode(Self.verifiedProfile)

        XCTAssertEqual(profile.handle, "yuki")
        XCTAssertEqual(profile.displayName, "Yuki Tanaka")
        XCTAssertEqual(profile.atHandle, "@yuki")
        XCTAssertEqual(profile.bio, "Tokyo. Identity and trust.")
        XCTAssertEqual(profile.postCount, 3)
        XCTAssertEqual(profile.followerCount, 12)
        XCTAssertEqual(profile.followingCount, 4)
        XCTAssertFalse(profile.isFollowing)
        XCTAssertFalse(profile.isMe)
        XCTAssertTrue(profile.user.isVerified)
        XCTAssertEqual(profile.user.countryCode, "JP")
        XCTAssertNotNil(profile.user.verifiedSince)
        // The root-relative avatar has to come out loadable, not hostless.
        XCTAssertNotNil(profile.user.avatarURL?.host)
    }

    /// `bio` is nullable on the wire and is `null` for every seeded account, so
    /// this is the ordinary case rather than an edge one.
    func testANullBioDecodesToNothingRatherThanAnEmptyLine() throws {
        let profile: Profile = try decode("""
        {
          "user": {"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2", "handle": "omar",
                   "display_name": "Omar", "avatar_url": null, "is_verified": true,
                   "country_code": "SA", "verified_since": null},
          "bio": null, "post_count": 2, "follower_count": 0, "following_count": 0,
          "is_following": false, "is_me": false
        }
        """)

        XCTAssertNil(profile.bio)
    }

    /// An empty string is not a bio either — it would render as a blank gap the
    /// header reserved space for.
    func testAnEmptyBioIsTreatedAsNoBio() throws {
        let profile: Profile = try decode("""
        {"user": {"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2", "handle": "omar",
                  "is_verified": true}, "bio": "", "post_count": 0,
         "follower_count": 0, "following_count": 0, "is_following": false, "is_me": false}
        """)

        XCTAssertNil(profile.bio)
    }

    /// **The trust invariant.** An unverified account has no checkmark and no
    /// country — the code is written only by the verification pipeline, and the
    /// badge must have nothing to draw.
    func testAnUnverifiedAccountCarriesNoCountryAndNoVerificationDate() throws {
        let profile: Profile = try decode("""
        {
          "user": {"id": "00000000-0000-4000-8000-000000000105", "handle": "newcomer",
                   "display_name": "Sam Reed", "avatar_url": null, "is_verified": false,
                   "country_code": null, "verified_since": null},
          "bio": null, "post_count": 0, "follower_count": 0, "following_count": 1,
          "is_following": false, "is_me": false
        }
        """)

        XCTAssertFalse(profile.user.isVerified)
        XCTAssertNil(profile.user.countryCode, "an unverified account must not carry a flag")
        XCTAssertNil(profile.user.verifiedSince)
        XCTAssertNil(CountryCode.flag(profile.user.countryCode), "there is nothing to render")
    }

    func testMissingCountersDecodeAsZeroRatherThanFailingTheWholeProfile() throws {
        let profile: Profile = try decode("""
        {"user": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz",
                  "is_verified": true}}
        """)

        XCTAssertEqual(profile.postCount, 0)
        XCTAssertEqual(profile.followerCount, 0)
        XCTAssertEqual(profile.followingCount, 0)
        XCTAssertFalse(profile.isFollowing)
        XCTAssertFalse(profile.isMe)
    }

    /// There is no `user` to fall back to: a header with no name, handle or
    /// checkmark is not a profile, so this one is allowed to throw.
    func testAProfileWithNoUserFails() {
        XCTAssertThrowsError(try decode(#"{"bio": null, "post_count": 1}"#, as: Profile.self))
    }

    /// The server answers `400 self_follow`, so "your own profile, which you
    /// follow" is not a state that exists. A body claiming it is corrected.
    func testYourOwnProfileIsNeverDecodedAsFollowed() throws {
        let profile: Profile = try decode("""
        {"user": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz",
                  "is_verified": true}, "is_following": true, "is_me": true,
         "post_count": 3, "follower_count": 9, "following_count": 2}
        """)

        XCTAssertTrue(profile.isMe)
        XCTAssertFalse(profile.isFollowing)
        XCTAssertFalse(profile.showsFollowControl, "there is no follow button on your own page")
    }

    // MARK: - FollowResult

    func testFollowResultDecodesTheAuthoritativeCount() throws {
        let result: FollowResult = try decode(#"{"following": true, "follower_count": 13}"#)

        XCTAssertTrue(result.following)
        XCTAssertEqual(result.followerCount, 13)
    }

    /// "The server said nothing" and "the server said zero" are different facts,
    /// and only the first must leave what is on screen alone.
    func testAFollowResultWithNoCountDecodesToNilNotZero() throws {
        let result: FollowResult = try decode(#"{"following": false}"#)

        XCTAssertFalse(result.following)
        XCTAssertNil(result.followerCount)
    }

    // MARK: - Optimistic prediction

    func testPredictingAFollowMovesTheCounterByExactlyOne() {
        let before = Profile(user: FeedServiceMock.yuki, followerCount: 12, isFollowing: false)

        let after = before.predicting(following: true)

        XCTAssertTrue(after.isFollowing)
        XCTAssertEqual(after.followerCount, 13)
    }

    func testPredictingAnUnfollowNeverGoesBelowZero() {
        let before = Profile(user: FeedServiceMock.yuki, followerCount: 0, isFollowing: true)

        XCTAssertEqual(before.predicting(following: false).followerCount, 0)
    }

    func testPredictingAStateAlreadyHeldChangesNothing() {
        let before = Profile(user: FeedServiceMock.yuki, followerCount: 12, isFollowing: true)

        XCTAssertEqual(before.predicting(following: true), before)
    }

    // MARK: - Reconciliation

    /// **The rule the whole feature turns on.** The local `+1` is a guess; the
    /// response is the stored truth, and it wins even when the two differ.
    func testTheServersCountOverwritesTheOptimisticOne() {
        let before = Profile(user: FeedServiceMock.yuki, followerCount: 12, isFollowing: false)
        let predicted = before.predicting(following: true)
        XCTAssertEqual(predicted.followerCount, 13, "precondition: the client guessed 13")

        // Another device followed the same account in the meantime.
        let reconciled = predicted.reconciled(with: FollowResult(following: true, followerCount: 14))

        XCTAssertEqual(reconciled.followerCount, 14, "the client kept its own arithmetic")
        XCTAssertTrue(reconciled.isFollowing)
    }

    /// The disagreement runs both ways: an unfollow can land on a *higher*
    /// number than before, because other people kept following meanwhile.
    func testReconcilingAnUnfollowAdoptsAHigherCountWithoutArgument() {
        let before = Profile(user: FeedServiceMock.yuki, followerCount: 12, isFollowing: true)

        let reconciled = before
            .predicting(following: false)
            .reconciled(with: FollowResult(following: false, followerCount: 40))

        XCTAssertEqual(reconciled.followerCount, 40)
        XCTAssertFalse(reconciled.isFollowing)
    }

    /// Idempotence made visible: following twice is a success that changes no
    /// count, and the second answer must not be read as "+1 again".
    func testFollowingSomebodyYouAlreadyFollowKeepsTheCountWhereItIs() {
        let before = Profile(user: FeedServiceMock.yuki, followerCount: 13, isFollowing: true)

        let reconciled = before.reconciled(with: FollowResult(following: true, followerCount: 13))

        XCTAssertEqual(reconciled.followerCount, 13)
        XCTAssertTrue(reconciled.isFollowing)
    }

    func testReconcilingWithNoStatedCountLeavesTheCountAlone() {
        let predicted = Profile(user: FeedServiceMock.yuki, followerCount: 12, isFollowing: false)
            .predicting(following: true)

        let reconciled = predicted.reconciled(with: FollowResult(following: true))

        XCTAssertEqual(reconciled.followerCount, 13, "nothing better was on offer")
    }

    // MARK: - Handles

    func testHandlesAreNormalisedTheWayTheServerMatchesThem() {
        XCTAssertEqual(Handle.normalised("@Yuki"), "yuki")
        XCTAssertEqual(Handle.normalised("  MARIA \n"), "maria")
        XCTAssertEqual(Handle.normalised("@@omar"), "omar")
        XCTAssertEqual(Handle.normalised(""), "")
    }

    /// A tapped mention is arbitrary text. It must never be able to become a
    /// different path.
    func testAHandleThatCouldTraverseThePathIsStrippedToNothingUsable() {
        XCTAssertEqual(Handle.pathComponent("@someone/../admin"), "someoneadmin")
        XCTAssertEqual(Handle.pathComponent("../.."), "")
        XCTAssertEqual(Handle.pathComponent("a b c"), "abc")
        XCTAssertEqual(Handle.pathComponent("عمر"), "", "nothing usable survives")
        XCTAssertEqual(Handle.pathComponent("real_handle_9"), "real_handle_9")
    }

    // MARK: - Copy

    /// The timeline must not be described as everything somebody has written —
    /// the server excludes replies from both the list and the count.
    func testTheTimelineNoteAdmitsRepliesAreMissing() {
        XCTAssertTrue(ProfileCopy.timelineScope.lowercased().contains("replies"))
        XCTAssertTrue(ProfileCopy.timelineScope.lowercased().contains("not listed"))
    }

    func testTheUnavailableCopyNamesTheHandleAndPromisesNoRetry() {
        let subtitle = ProfileCopy.unavailableSubtitle(for: "ghost")
        XCTAssertTrue(subtitle.contains("@ghost"))
        XCTAssertFalse(subtitle.lowercased().contains("try again"))
        XCTAssertEqual(ProfileCopy.unavailableSubtitle(for: "").hasPrefix("That handle"), true)
    }

    func testTheFollowLabelSaysWhatTheStateIsRatherThanWhatTheTapDoes() {
        XCTAssertEqual(ProfileCopy.followTitle(isFollowing: false), "Follow")
        XCTAssertEqual(ProfileCopy.followTitle(isFollowing: true), "Following")
    }
}
