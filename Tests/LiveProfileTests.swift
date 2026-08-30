import XCTest
@testable import Sila

/// Drives the deployed profile API through the app's own service and decoders.
///
/// The fixture tests agree with the contract by construction, so they would stay
/// green if the server drifted. These are the ones that would notice — and the
/// drift worth noticing here is subtle: `post_count` and the timeline are two
/// different queries, and the follow verbs are idempotent, so a client that
/// counted for itself would look right until somebody used two devices.
///
/// **Deliberately non-destructive.** It never touches the live account's own
/// profile fields — no name, no handle, no bio, no picture. The only state it
/// changes at all is *whether the live account follows a seeded demo person*,
/// and `tearDown` puts that back exactly as it was found, whichever way round
/// it started.
///
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LiveProfileTests: XCTestCase {

    /// Seeded demo accounts. Verified, and safe to read.
    private static let demoHandles = ["yuki", "maria", "omar", "faisal", "noura"]

    /// The one account this suite is allowed to follow and unfollow.
    private static let followTarget = "yuki"

    private var token: String?
    private var myHandle = ""
    /// Whether the live account followed ``followTarget`` before this ran.
    private var wasFollowingTarget = false
    /// Set once ``wasFollowingTarget`` is known, so `tearDown` never "restores"
    /// a state it failed to observe.
    private var recordedOriginalFollowState = false

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"], let password = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }

        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        let session = try await auth.signIn(email: email, password: password)
        token = session.token.accessToken
        myHandle = session.user.handle ?? ""

        // Record what to put back before anything is changed.
        if let profile = try? await service().fetchProfile(handle: Self.followTarget) {
            wasFollowingTarget = profile.isFollowing
            recordedOriginalFollowState = true
        }
    }

    override func tearDown() async throws {
        guard recordedOriginalFollowState, let token, !token.isEmpty else { return }
        let service = ProfileService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
        // Idempotent both ways, so this is safe to run even when nothing moved.
        _ = try? await service.setFollowing(wasFollowingTarget, handle: Self.followTarget)
    }

    private func service() throws -> ProfileService {
        ProfileService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    // MARK: - Reading

    /// The whole `ProfileOut` shape, decoded by the type the screen renders.
    func testASeededProfileDecodesWithEveryFieldTheHeaderNeeds() async throws {
        let profile = try await service().fetchProfile(handle: Self.followTarget)

        XCTAssertEqual(profile.handle, Self.followTarget)
        XCTAssertFalse(profile.displayName.isEmpty, "a header with no name is not a profile")
        XCTAssertFalse(profile.isMe, "a demo account is not the signed-in one")
        XCTAssertGreaterThanOrEqual(profile.postCount, 0)
        XCTAssertGreaterThanOrEqual(profile.followerCount, 0)
        XCTAssertGreaterThanOrEqual(profile.followingCount, 0)
    }

    /// The product's core trust signal, end to end: a country flag exists only
    /// where a verified identity put one, and never anywhere else.
    func testTheCountryFlagOnlyEverAppearsOnAVerifiedAccount() async throws {
        let service = try service()

        for handle in Self.demoHandles {
            let profile = try await service.fetchProfile(handle: handle)
            if !profile.user.isVerified {
                XCTAssertNil(
                    profile.user.countryCode,
                    "\(handle) is unverified and still carries a country"
                )
            }
            if let code = profile.user.countryCode {
                XCTAssertTrue(profile.user.isVerified)
                XCTAssertNotNil(CountryCode.flag(code), "\(code) is not a renderable ISO region")
            }
        }
    }

    /// `bio` is nullable and is `null` on every seeded account, which is exactly
    /// the case a non-optional field would have crashed the whole screen on.
    func testANullBioDecodesRatherThanFailingTheProfile() async throws {
        let profile = try await service().fetchProfile(handle: "omar")

        XCTAssertNotNil(profile.user.handle)
        if let bio = profile.bio {
            XCTAssertFalse(bio.isEmpty, "an empty bio should decode as none at all")
            XCTAssertLessThanOrEqual(bio.count, AccountLimits.maximumBioLength)
        }
    }

    func testYourOwnProfileAnswersIsMeAndHidesTheFollowButton() async throws {
        try XCTSkipIf(myHandle.isEmpty, "this session carries no handle")

        let profile = try await service().fetchProfile(handle: myHandle)

        XCTAssertTrue(profile.isMe)
        XCTAssertFalse(profile.isFollowing, "you cannot follow yourself")
        XCTAssertFalse(profile.showsFollowControl)
    }

    // MARK: - The timeline

    /// **The exclusion the UI must not overclaim.** `/users/{handle}/posts`
    /// filters `reply_to_post_id IS NULL`, so nothing it returns is a reply.
    func testTheTimelineNeverContainsAReply() async throws {
        let service = try service()

        for handle in Self.demoHandles {
            let page = try await service.fetchPosts(handle: handle, cursor: nil, limit: 50)
            XCTAssertTrue(
                page.posts.allSatisfy { !$0.isReply },
                "\(handle)'s timeline contained a reply"
            )
            XCTAssertTrue(
                page.posts.allSatisfy { $0.author.handle == handle },
                "\(handle)'s timeline contained somebody else's post"
            )
        }
    }

    /// The count above the list and the list itself come from two different
    /// queries. They are only allowed to disagree in one direction — and on this
    /// deployment they apply the same filter, so they should not disagree at all.
    func testThePostCountAgreesWithWhatCanActuallyBePagedThrough() async throws {
        let service = try service()
        let profile = try await service.fetchProfile(handle: Self.followTarget)

        var seen: [UUID] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await service.fetchPosts(handle: Self.followTarget, cursor: cursor, limit: 50)
            seen.append(contentsOf: page.posts.map(\.id))
            cursor = page.hasMore ? page.nextCursor : nil
            pages += 1
        } while cursor != nil && pages < 10

        XCTAssertEqual(Set(seen).count, seen.count, "a post arrived on two pages")
        XCTAssertLessThanOrEqual(
            seen.count,
            profile.postCount,
            "more rows are pageable than post_count admits"
        )
    }

    /// Cursor paging over the real endpoint, at the smallest page size the
    /// server accepts — where an off-by-one in the keyset shows up.
    func testCursorPagingWalksTheTimelineWithoutRepeatingOrStalling() async throws {
        let service = try service()

        let first = try await service.fetchPosts(handle: Self.followTarget, cursor: nil, limit: 1)
        try XCTSkipIf(first.posts.isEmpty, "nothing to page through")
        XCTAssertEqual(first.posts.count, 1)

        guard first.hasMore, let cursor = first.nextCursor else { return }
        let second = try await service.fetchPosts(handle: Self.followTarget, cursor: cursor, limit: 1)

        XCTAssertNotEqual(
            second.posts.first?.id,
            first.posts.first?.id,
            "the cursor handed back the same row"
        )
    }

    /// The server validates `limit` with `ge=1, le=50` and answers 422 outside
    /// it. The service clamps, so an out-of-range request still succeeds.
    func testAnOutOfRangeLimitIsClampedRatherThanRejected() async throws {
        let page = try await service().fetchPosts(handle: Self.followTarget, cursor: nil, limit: 9_999)

        XCTAssertLessThanOrEqual(page.posts.count, FeedConstants.maximumPageSize)
    }

    // MARK: - The dead end

    func testAnUnknownHandleIsUserNotFoundOnBothProfileEndpoints() async throws {
        let service = try service()
        let ghost = "nosuchhandle_xyz"

        do {
            _ = try await service.fetchProfile(handle: ghost)
            XCTFail("the server served a profile for a handle nobody holds")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .userNotFound)
        }

        do {
            _ = try await service.fetchPosts(handle: ghost, cursor: nil, limit: 20)
            XCTFail("the server served a timeline for a handle nobody holds")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .userNotFound)
        }
    }

    // MARK: - Following (restored in tearDown)

    /// The behaviour the client's reconciliation exists for, proven against the
    /// real server: both verbs are idempotent, and both report the stored count.
    func testFollowingIsIdempotentAndAlwaysReportsTheStoredCount() async throws {
        let service = try service()
        let before = try await service.fetchProfile(handle: Self.followTarget)

        let first = try await service.setFollowing(true, handle: Self.followTarget)
        XCTAssertTrue(first.following)
        let firstCount = try XCTUnwrap(first.followerCount)

        // Again. A second row is not created, and the count must not move.
        let second = try await service.setFollowing(true, handle: Self.followTarget)
        XCTAssertTrue(second.following)
        XCTAssertEqual(second.followerCount, firstCount, "following twice double-counted")

        // And the profile agrees with what the follow call reported.
        let after = try await service.fetchProfile(handle: Self.followTarget)
        XCTAssertTrue(after.isFollowing)
        XCTAssertEqual(after.followerCount, firstCount)

        // A local `+1` would only be right when the row was genuinely new.
        if !before.isFollowing {
            XCTAssertEqual(firstCount, before.followerCount + 1)
        } else {
            XCTAssertEqual(firstCount, before.followerCount)
        }
    }

    func testUnfollowingIsIdempotentToo() async throws {
        let service = try service()

        _ = try await service.setFollowing(true, handle: Self.followTarget)
        let first = try await service.setFollowing(false, handle: Self.followTarget)
        let second = try await service.setFollowing(false, handle: Self.followTarget)

        XCTAssertFalse(first.following)
        XCTAssertFalse(second.following)
        XCTAssertEqual(first.followerCount, second.followerCount)
        let reread = try await service.fetchProfile(handle: Self.followTarget)
        XCTAssertFalse(reread.isFollowing)
    }

    /// The full client-side round trip: predict, call, reconcile. The number on
    /// screen at the end is the server's, whatever the prediction was.
    func testTheClientEndsUpOnTheServersCountAndNotItsOwn() async throws {
        let service = try service()
        _ = try await service.setFollowing(false, handle: Self.followTarget)
        let loaded = try await service.fetchProfile(handle: Self.followTarget)

        let predicted = loaded.predicting(following: true)
        let result = try await service.setFollowing(true, handle: Self.followTarget)
        let reconciled = loaded.reconciled(with: result)

        XCTAssertTrue(reconciled.isFollowing)
        XCTAssertEqual(reconciled.followerCount, result.followerCount)
        let stored = try await service.fetchProfile(handle: Self.followTarget)
        XCTAssertEqual(
            reconciled.followerCount,
            stored.followerCount,
            "what the screen shows disagrees with what the server holds"
        )
        // Not asserted as equal on purpose: the prediction is allowed to be
        // wrong, which is the entire reason it is thrown away.
        XCTAssertGreaterThanOrEqual(reconciled.followerCount, 1)
        XCTAssertGreaterThanOrEqual(predicted.followerCount, 1)
    }

    /// Safe to provoke precisely because it fails.
    func testFollowingYourselfIsRefused() async throws {
        try XCTSkipIf(myHandle.isEmpty, "this session carries no handle")

        do {
            _ = try await service().setFollowing(true, handle: myHandle)
            XCTFail("the server let an account follow itself")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .selfFollow)
        }
    }

    func testFollowingAHandleNobodyHoldsIsRefused() async throws {
        do {
            _ = try await service().setFollowing(true, handle: "nosuchhandle_xyz")
            XCTFail("the server stored a follow for a handle nobody holds")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .userNotFound)
        }
    }
}
