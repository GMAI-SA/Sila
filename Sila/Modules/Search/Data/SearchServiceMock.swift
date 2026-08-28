import Foundation

/// Scripted ``SearchServiceProtocol`` used by tests, previews and the
/// `-mockSearch` launch argument.
///
/// Searches the same fixture world ``FeedServiceMock`` serves, so a mocked
/// Explore finds the posts and people a mocked feed shows — a demo that
/// contradicted itself would be worse than no demo.
public actor SearchServiceMock: SearchServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Substring search over the fixture posts and users; trending returns tags.
        case populated
        /// Every query matches nothing and there is nothing trending.
        case empty
        /// Every call fails with a transport error.
        case offline
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// Artificial latency, in seconds. Tests pass `0`.
    private let latency: Double

    /// Queries received, e.g. `"users:az"` — the assertion surface for debounce.
    public private(set) var recordedQueries: [String] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay.
    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - SearchServiceProtocol

    public func searchUsers(query: String, limit: Int) async throws -> [UserSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        recordedQueries.append("users:\(trimmed)")
        try await delay()
        try failIfOffline()
        guard trimmed.count >= SearchConstants.minimumQueryLength, scenario == .populated else {
            return []
        }
        let needle = trimmed.lowercased()
        return Self.users
            .filter { $0.handle.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle) }
            // The contract promises verified accounts sort first.
            .sorted { ($0.isVerified ? 0 : 1) < ($1.isVerified ? 0 : 1) }
            .prefix(min(max(limit, 1), SearchConstants.maximumUserLimit))
            .map { $0 }
    }

    public func searchPosts(query: String, cursor: String?, limit: Int) async throws -> FeedPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        recordedQueries.append("posts:\(trimmed)")
        try await delay()
        try failIfOffline()
        guard trimmed.count >= SearchConstants.minimumQueryLength,
              scenario == .populated,
              cursor == nil
        else { return .empty }

        let needle = trimmed.lowercased()
        let matches = FeedServiceMock.allSamplePosts()
            .filter { $0.text.lowercased().contains(needle) }
        return FeedPage(posts: matches, nextCursor: nil, hasMore: false)
    }

    public func trendingTags(limit: Int) async throws -> [TrendingTag] {
        recordedQueries.append("trending")
        try await delay()
        try failIfOffline()
        guard scenario == .populated else { return [] }
        return Array(Self.tags.prefix(min(max(limit, 1), SearchConstants.maximumTrendingLimit)))
    }

    // MARK: - Fixture world

    /// The accounts the mock can find — the same people the mocked feed shows.
    static let users: [UserSummary] = [
        FeedServiceMock.aziz,
        FeedServiceMock.yuki,
        FeedServiceMock.maria,
        FeedServiceMock.noor,
        FeedServiceMock.pending
    ]

    /// Tags counted from the fixture posts' hashtags.
    static let tags: [TrendingTag] = [
        TrendingTag(tag: "proofofpersonhood", postCount: 34),
        TrendingTag(tag: "riyadh", postCount: 21),
        TrendingTag(tag: "sila", postCount: 12)
    ]

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
