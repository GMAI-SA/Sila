import Foundation

/// Scripted ``ProfileServiceProtocol`` for tests, previews and the
/// `-mockProfile` launch argument.
///
/// The people and the posts are ``FeedServiceMock``'s, not a second cast: a
/// profile opened from a mocked feed has to be the same person who wrote the
/// post that was tapped, or the demo is showing something the app could never
/// show.
///
/// It reproduces the three server behaviours the screen actually has to survive:
///
/// * **The timeline excludes replies.** ``fetchPosts(handle:cursor:limit:)``
///   filters `replyToPostId == nil` exactly as the server's
///   `reply_to_post_id IS NULL` does, so a mocked profile cannot accidentally
///   demo a completeness the real one does not have.
/// * **Following is idempotent**, and every answer carries the authoritative
///   count — including ``MockScenario/followedElsewhere``, where the count comes
///   back higher than the client predicted because another device acted too.
///   That case is the entire reason the client reconciles instead of counting.
/// * **An unknown or deactivated handle is a 404**, indistinguishable from each
///   other on purpose.
public actor ProfileServiceMock: ProfileServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Verified accounts with country flags, bios and posts.
        case populated
        /// Every handle resolves to an account that is **not** verified and
        /// therefore carries no country at all — the badge must render nothing.
        case unverified
        /// The accounts exist and have written nothing.
        case empty
        /// Every handle 404s — the "isn't available" dead end.
        case notFound
        /// Every call fails with a transport error.
        case offline
        /// Loads fine; every follow and unfollow is rejected by the server.
        case followFails
        /// A second device followed the same account in the meantime, so the
        /// server's count is **two** higher than the local `+1` predicted.
        case followedElsewhere
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// Artificial latency, in seconds. Tests pass `0`.
    private let latency: Double

    /// The viewer's own handle — the one that answers `is_me: true`.
    private let viewerHandle: String

    /// Follow state, keyed by handle, mutated by accepted writes.
    private var following: Set<String> = []

    /// Follower counts, keyed by handle. Mutated the way the server would.
    private var followerCounts: [String: Int] = [:]

    /// Calls recorded for test assertions, e.g. `"setFollowing:true:yuki"`.
    public private(set) var recordedCalls: [String] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay.
    ///   - viewerHandle: Whose profile answers `is_me`. Defaults to the handle
    ///     `AuthServiceMock`'s verified account signs in with.
    public init(
        scenario: MockScenario = .populated,
        latency: Double = 0,
        viewerHandle: String = "aziz"
    ) {
        self.scenario = scenario
        self.latency = latency
        self.viewerHandle = Handle.normalised(viewerHandle)
        self.followerCounts = Self.startingFollowerCounts
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    /// Pre-seeds the viewer as already following an account.
    public func setFollowing(_ handles: [String]) {
        following = Set(handles.map(Handle.normalised))
    }

    // MARK: - ProfileServiceProtocol

    public func fetchProfile(handle: String) async throws -> Profile {
        record("fetchProfile:\(Handle.normalised(handle))")
        try await delay()
        try failIfOffline()
        let user = try person(handle)
        let key = user.handle
        let isMe = key == viewerHandle
        return Profile(
            user: user,
            bio: scenario == .empty ? nil : Self.bios[key],
            postCount: try posts(for: key).count,
            followerCount: followerCounts[key] ?? 0,
            followingCount: Self.followingCounts[key] ?? 0,
            isFollowing: following.contains(key),
            isMe: isMe
        )
    }

    public func fetchPosts(handle: String, cursor: String?, limit: Int) async throws -> FeedPage {
        record("fetchPosts:\(Handle.normalised(handle)):\(cursor == nil ? "first" : "next")")
        try await delay()
        try failIfOffline()
        let user = try person(handle)
        // One page is enough for every fixture account; a cursor that arrives
        // anyway gets the honest end-of-list answer rather than a repeat.
        guard cursor == nil else { return .empty }
        let rows = try posts(for: user.handle)
        return FeedPage(posts: rows, nextCursor: nil, hasMore: false)
    }

    public func setFollowing(_ following: Bool, handle: String) async throws -> FollowResult {
        record("setFollowing:\(following):\(Handle.normalised(handle))")
        try await delay()
        try failIfOffline()
        let user = try person(handle)
        let key = user.handle

        guard key != viewerHandle else {
            throw APIError.api(code: .selfFollow, message: "You cannot follow yourself", status: 400)
        }
        if scenario == .followFails {
            throw APIError.http(status: 500, message: "The follow could not be stored.")
        }

        let wasFollowing = self.following.contains(key)
        var count = followerCounts[key] ?? 0
        if following, !wasFollowing {
            count += 1
        } else if !following, wasFollowing {
            count = max(0, count - 1)
        }
        // A second device acted between the tap and this response, so the
        // authoritative number is not the one the client predicted. Idempotent
        // verbs make this ordinary rather than exotic.
        if scenario == .followedElsewhere, following {
            count += 1
        }

        if following {
            self.following.insert(key)
        } else {
            self.following.remove(key)
        }
        followerCounts[key] = count
        return FollowResult(following: following, followerCount: count)
    }

    // MARK: - Fixture world

    /// The cast, reused verbatim from the feed so a tapped author is the same
    /// person on both screens.
    static let people: [UserSummary] = [
        FeedServiceMock.aziz,
        FeedServiceMock.yuki,
        FeedServiceMock.maria,
        FeedServiceMock.noor,
        FeedServiceMock.pending
    ]

    /// Bios, at or under the server's 160-character limit.
    static let bios: [String: String] = [
        "aziz": "Building Sila. Verified humans only — no bots, no farms, no anonymous "
            + "crowds. Riyadh.",
        "yuki": "Tokyo. Writing about identity, trust and the internet we could have had.",
        "maria": "São Paulo · researcher · interested in what verification does to a "
            + "conversation.",
        "noor": "Abu Dhabi."
        // `pending` deliberately has none: a fresh account with no bio is the
        // case the header has to render without a hole in it.
    ]

    static let startingFollowerCounts: [String: Int] = [
        "aziz": 1_284, "yuki": 312, "maria": 87, "noor": 12, "newcomer": 0
    ]

    static let followingCounts: [String: Int] = [
        "aziz": 96, "yuki": 140, "maria": 23, "noor": 4, "newcomer": 1
    ]

    // MARK: - Internals

    /// The account behind a handle, honouring ``MockScenario/notFound`` and
    /// ``MockScenario/unverified``.
    private func person(_ handle: String) throws -> UserSummary {
        guard scenario != .notFound else { throw Self.notFoundError }
        let key = Handle.normalised(handle)
        guard let match = Self.people.first(where: { $0.handle == key }) else {
            throw Self.notFoundError
        }
        guard scenario == .unverified else { return match }
        // Strip the checkmark *and* the country together: the country is only
        // ever written by the verification pipeline, so an unverified account
        // that still carried a flag would be a bug this mock must not model.
        return UserSummary(
            id: match.id,
            handle: match.handle,
            displayName: match.displayName,
            avatarURL: match.avatarURL,
            isVerified: false,
            countryCode: nil,
            verifiedSince: nil
        )
    }

    /// The account's top-level posts — the same exclusion the server applies.
    private func posts(for handle: String) throws -> [Post] {
        guard scenario != .empty else { return [] }
        return FeedServiceMock.allSamplePosts()
            .filter { $0.author.handle == handle && !$0.isReply }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static let notFoundError = APIError.api(
        code: .userNotFound,
        message: "No account with that handle",
        status: 404
    )

    private func record(_ call: String) {
        recordedCalls.append(call)
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }
}
