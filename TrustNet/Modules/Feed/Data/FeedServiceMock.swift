import Foundation

/// Scripted ``FeedServiceProtocol`` used by tests, previews and the
/// `-mockFeed` launch argument.
///
/// Pick a ``MockScenario`` and every screen in the module behaves consistently
/// with it, so the whole feature is demoable without a backend — the same
/// contract `AuthServiceMock` offers for Phase 1.
///
/// ```swift
/// let service = FeedServiceMock(scenario: .unverifiedNoCountry)
/// ```
public actor FeedServiceMock: FeedServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// A healthy multi-country feed with two pages, quote posts, replies,
        /// a country thread the viewer cannot reply to, and one unverified
        /// author with no country flag.
        case populated
        /// Every feed returns zero posts — the empty state.
        case empty
        /// The viewer has no verified country: `/feed/country` answers
        /// 409 `no_country` while the other three feeds work normally.
        case unverifiedNoCountry
        /// Every call fails with a transport error.
        case offline
        /// The first page is full and advertises more, but the next page comes
        /// back empty with `has_more: false` — the case that used to spin the
        /// pager forever.
        case paginationExhausted
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// Artificial latency, in seconds, applied to every call. Tests pass `0`.
    private let latency: Double

    /// Calls recorded for test assertions, e.g. `"fetchFeed:forYou:first"`.
    public private(set) var recordedCalls: [String] = []

    /// Local engagement state so a like survives a re-read within a session.
    private var metricsOverrides: [UUID: PostMetrics] = [:]

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve. Defaults to ``MockScenario/populated``.
    ///   - latency: Seconds of simulated network delay.
    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
    }

    /// Switches scenario mid-flight (used by previews and UI-test hooks).
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - FeedServiceProtocol

    public func fetchFeed(_ tab: FeedTab, cursor: String?, limit: Int) async throws -> FeedPage {
        record("fetchFeed:\(tab.rawValue):\(cursor == nil ? "first" : cursor ?? "")")
        try await delay()
        try failIfOffline()

        if tab == .myCountry, scenario == .unverifiedNoCountry {
            throw APIError.api(
                code: .noCountry,
                message: "Your account has no verified country yet.",
                status: 409
            )
        }

        switch scenario {
        case .empty:
            return .empty

        case .paginationExhausted:
            // Page one promises more; page two delivers nothing. Both are legal
            // responses, and the pager must survive the pair.
            if cursor == nil {
                return FeedPage(posts: Self.samplePosts(for: tab), nextCursor: "cursor-page-2", hasMore: true)
            }
            return FeedPage(posts: [], nextCursor: nil, hasMore: false)

        case .populated, .unverifiedNoCountry, .offline:
            if cursor == nil {
                return applyOverrides(
                    FeedPage(posts: Self.samplePosts(for: tab), nextCursor: "cursor-page-2", hasMore: true)
                )
            }
            return applyOverrides(
                FeedPage(posts: Self.samplePosts(for: tab, page: 2), nextCursor: nil, hasMore: false)
            )
        }
    }

    public func fetchPost(_ id: UUID) async throws -> Post {
        record("fetchPost")
        try await delay()
        try failIfOffline()
        guard let post = Self.allSamplePosts().first(where: { $0.id == id }) else {
            throw APIError.api(code: .postNotFound, message: "No such post", status: 404)
        }
        return applyOverrides(to: post)
    }

    public func fetchReplies(for postId: UUID, cursor: String?) async throws -> FeedPage {
        record("fetchReplies:\(cursor == nil ? "first" : "next")")
        try await delay()
        try failIfOffline()
        guard scenario != .empty, cursor == nil else { return .empty }
        let replies = Self.allSamplePosts().filter { $0.replyToPostId == postId }
        return FeedPage(posts: replies.map(applyOverrides(to:)), nextCursor: nil, hasMore: false)
    }

    public func setLiked(_ liked: Bool, postId: UUID) async throws -> PostMetrics {
        try await mutate(postId: postId, call: "setLiked") { $0.adjusting(likes: liked ? 1 : -1) }
    }

    public func setReposted(_ reposted: Bool, postId: UUID) async throws -> PostMetrics {
        try await mutate(postId: postId, call: "setReposted") { $0.adjusting(reposts: reposted ? 1 : -1) }
    }

    public func setBookmarked(_ bookmarked: Bool, postId: UUID) async throws -> PostMetrics {
        try await mutate(postId: postId, call: "setBookmarked") { $0.adjusting(bookmarks: bookmarked ? 1 : -1) }
    }

    public func deletePost(_ id: UUID) async throws {
        record("deletePost")
        try await delay()
        try failIfOffline()
    }

    // MARK: - Internals

    private func mutate(
        postId: UUID,
        call: String,
        _ transform: (PostMetrics) -> PostMetrics
    ) async throws -> PostMetrics {
        record(call)
        try await delay()
        try failIfOffline()
        let base = metricsOverrides[postId]
            ?? Self.allSamplePosts().first { $0.id == postId }?.metrics
            ?? PostMetrics()
        let updated = transform(base)
        metricsOverrides[postId] = updated
        return updated
    }

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

    private func applyOverrides(_ page: FeedPage) -> FeedPage {
        FeedPage(
            posts: page.posts.map(applyOverrides(to:)),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
    }

    private func applyOverrides(to post: Post) -> Post {
        guard let metrics = metricsOverrides[post.id] else { return post }
        var updated = post
        updated.metrics = metrics
        return updated
    }
}

// MARK: - Fixture world

extension FeedServiceMock {

    /// Deterministic ids so a preview, a test and a demo all show the same feed.
    private static func id(_ suffix: Int) -> UUID {
        let padded = String(format: "%012d", suffix)
        return UUID(uuidString: "00000000-0000-4000-8000-\(padded)") ?? UUID()
    }

    /// Fixed "now" so relative timestamps in previews do not drift.
    private static func minutesAgo(_ minutes: Double) -> Date {
        Date().addingTimeInterval(-minutes * 60)
    }

    static let aziz = UserSummary(
        id: id(101), handle: "aziz", displayName: "Abdulaziz Alwakeel",
        isVerified: true, countryCode: "SA", verifiedSince: minutesAgo(60 * 24 * 30)
    )
    static let yuki = UserSummary(
        id: id(102), handle: "yuki", displayName: "Yuki Tanaka",
        isVerified: true, countryCode: "JP", verifiedSince: minutesAgo(60 * 24 * 90)
    )
    static let maria = UserSummary(
        id: id(103), handle: "maria", displayName: "Maria Souza",
        isVerified: true, countryCode: "BR", verifiedSince: minutesAgo(60 * 24 * 14)
    )
    static let noor = UserSummary(
        id: id(104), handle: "noor", displayName: "Noor Al-Fahad",
        isVerified: true, countryCode: "AE", verifiedSince: minutesAgo(60 * 24 * 7)
    )
    /// An account still in the verification queue: verified `false`, and
    /// therefore **no country flag at all**. The card must show nothing.
    static let pending = UserSummary(
        id: id(105), handle: "newcomer", displayName: "Sam Reed",
        isVerified: false, countryCode: nil, verifiedSince: nil
    )

    /// The internationally-scoped root thread, quoted elsewhere.
    static var internationalRoot: Post {
        Post(
            id: id(1),
            author: aziz,
            text: "What's the single biggest change identity verification will bring to social media? Answers from every country welcome 👇 #ProofOfPersonhood",
            createdAt: minutesAgo(125),
            scope: .international,
            replyCountDirect: 2,
            metrics: PostMetrics(likes: 412, reposts: 88, replies: 2, views: 20_140, bookmarks: 61),
            viewer: PostViewerState(canReply: true)
        )
    }

    /// A 🇸🇦-only thread the mocked viewer cannot reply to.
    static var countryThread: Post {
        Post(
            id: id(2),
            author: noor,
            text: "الطقس اليوم في الرياض ممتاز. Anyone else out walking? #Riyadh",
            createdAt: minutesAgo(46),
            scope: .country,
            scopeCountry: "SA",
            replyCountDirect: 0,
            metrics: PostMetrics(likes: 96, reposts: 4, replies: 0, views: 3_310, bookmarks: 7),
            viewer: PostViewerState(canReply: false, replyBlockReason: .countryMismatch)
        )
    }

    /// A regional thread, blocked for a different reason.
    static var regionThread: Post {
        Post(
            id: id(3),
            author: yuki,
            text: "GCC founders: what's the hardest part of cross-border KYC right now? Ask @aziz too.",
            createdAt: minutesAgo(300),
            scope: .region,
            scopeRegion: "GCC",
            replyCountDirect: 0,
            metrics: PostMetrics(likes: 51, reposts: 12, replies: 0, views: 1_902, bookmarks: 19),
            viewer: PostViewerState(liked: true, canReply: false, replyBlockReason: .regionMismatch)
        )
    }

    /// A quote post — one level deep, exactly as the contract promises.
    static var quotePost: Post {
        Post(
            id: id(4),
            author: maria,
            text: "This is the part nobody outside the region gets yet.",
            createdAt: minutesAgo(18),
            scope: .international,
            metrics: PostMetrics(likes: 77, reposts: 21, replies: 0, views: 4_006, bookmarks: 12),
            viewer: PostViewerState(bookmarked: true, canReply: true),
            quotedPost: internationalRoot
        )
    }

    /// An unverified author: no checkmark, no flag, nothing invented.
    static var unverifiedAuthorPost: Post {
        Post(
            id: id(5),
            author: pending,
            text: "Just joined — waiting on my ID review. Reading only for now.",
            createdAt: minutesAgo(9),
            scope: .international,
            metrics: PostMetrics(likes: 3, reposts: 0, replies: 0, views: 88, bookmarks: 0),
            viewer: PostViewerState(canReply: true)
        )
    }

    static var replyFromJapan: Post {
        Post(
            id: id(6),
            author: yuki,
            text: "The end of anonymous brigading. Every voice traceable to a real human in a real country.",
            createdAt: minutesAgo(110),
            scope: .international,
            replyToPostId: id(1),
            metrics: PostMetrics(likes: 140, reposts: 9, replies: 0, views: 5_500, bookmarks: 4),
            viewer: PostViewerState(canReply: true)
        )
    }

    static var replyFromBrazil: Post {
        Post(
            id: id(7),
            author: maria,
            text: "Cross-border commerce with verified counterparties. Trust unlocks trade.",
            createdAt: minutesAgo(95),
            scope: .international,
            replyToPostId: id(1),
            metrics: PostMetrics(likes: 88, reposts: 3, replies: 0, views: 2_410, bookmarks: 2),
            viewer: PostViewerState(canReply: true)
        )
    }

    static var secondPagePost: Post {
        Post(
            id: id(8),
            author: aziz,
            text: "Voice Rooms next. Country rooms first — the majlis, digitised. #TrustNet",
            createdAt: minutesAgo(60 * 26),
            scope: .country,
            scopeCountry: "SA",
            metrics: PostMetrics(likes: 233, reposts: 40, replies: 0, views: 9_800, bookmarks: 30),
            viewer: PostViewerState(canReply: false, replyBlockReason: .countryMismatch)
        )
    }

    /// Every fixture, for id lookups.
    static func allSamplePosts() -> [Post] {
        [
            internationalRoot, countryThread, regionThread, quotePost,
            unverifiedAuthorPost, replyFromJapan, replyFromBrazil, secondPagePost
        ]
    }

    /// The page a given tab serves.
    static func samplePosts(for tab: FeedTab, page: Int = 1) -> [Post] {
        guard page == 1 else { return [secondPagePost] }
        switch tab {
        case .forYou:
            return [quotePost, countryThread, unverifiedAuthorPost, internationalRoot, regionThread]
        case .following:
            return [internationalRoot, regionThread]
        case .myCountry:
            return [countryThread, secondPagePost]
        case .international:
            return [quotePost, internationalRoot, unverifiedAuthorPost]
        }
    }
}
