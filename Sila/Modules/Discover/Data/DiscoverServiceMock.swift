import Foundation

/// In-memory ``DiscoverServiceProtocol`` for previews, UI journeys and tests.
public final class DiscoverServiceMock: DiscoverServiceProtocol, @unchecked Sendable {

    public enum MockScenario: String, CaseIterable, Sendable {
        /// Every surface has something.
        case populated
        /// Every surface is empty.
        case empty
        /// Every call fails with a transport error.
        case offline
    }

    private let scenario: MockScenario
    private let latency: Double
    private let lock = NSLock()
    private var votes: [UUID: UUID] = [:]
    /// What the last onboarding call sent, for tests.
    public private(set) var submitted: OnboardingInterestsRequest?

    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
    }

    private func pause() async throws {
        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if scenario == .offline { throw APIError.transport("The Internet connection appears to be offline.") }
    }

    public func fetchNeedsReply(cursor: String?) async throws -> FeedPage {
        try await pause()
        guard scenario == .populated else { return .empty }
        return FeedPage(posts: [Self.openQuestion], nextCursor: nil, hasMore: false)
    }

    public func fetchPeople(topics: [String], limit: Int) async throws -> [SuggestedPerson] {
        try await pause()
        guard scenario == .populated else { return [] }
        return [
            SuggestedPerson(user: FeedServiceMock.yuki, reason: .topic, recentPosts: 6),
            SuggestedPerson(user: FeedServiceMock.noor, reason: .country, recentPosts: 3),
            SuggestedPerson(user: FeedServiceMock.maria, reason: .active, recentPosts: 2)
        ]
    }

    public func fetchTrending(topics: [String]) async throws -> [TrendingSection] {
        try await pause()
        guard scenario == .populated else { return [] }
        return [TrendingSection(topic: "technology", label: "Technology", labelAr: "التقنية",
                                posts: [FeedServiceMock.internationalRoot])]
    }

    public func fetchStarters() async throws -> [ComposerStarter] {
        try await pause()
        guard scenario == .populated else { return [] }
        return Self.starters
    }

    public func vote(postId: UUID, optionId: UUID) async throws -> Poll {
        try await pause()
        lock.lock(); defer { lock.unlock() }
        if votes[postId] != nil {
            throw APIError.api(code: .alreadyVoted, message: "You have already voted in this poll", status: 409)
        }
        votes[postId] = optionId
        let base = Self.samplePoll
        return Poll(
            id: base.id,
            options: base.options.map {
                PollOption(id: $0.id, position: $0.position, text: $0.text,
                           votes: ($0.id == optionId ? 1 : 0) + ($0.position == 0 ? 3 : 1))
            },
            totalVotes: 5,
            closesAt: base.closesAt,
            resultsVisibility: base.resultsVisibility,
            resultsVisible: true,
            viewerOptionId: optionId,
            canVote: false,
            voteBlockReason: .alreadyVoted
        )
    }

    public func fetchPoll(postId: UUID) async throws -> Poll {
        try await pause()
        return Self.samplePoll
    }

    public func submitOnboardingInterests(topics: [String], skipped: Bool) async throws -> FeedPreferences {
        try await pause()
        lock.lock(); submitted = OnboardingInterestsRequest(topics: topics, skipped: skipped); lock.unlock()
        return FeedPreferences(interests: skipped ? [] : topics)
    }

    // MARK: Fixtures

    public static let starters: [ComposerStarter] = [
        ComposerStarter(id: "advice", text: "I need advice on… ", textAr: "أحتاج نصيحة في… "),
        ComposerStarter(id: "recommend", text: "Can someone recommend… ?", textAr: "هل يمكن لأحد أن ينصحني بـ… ؟"),
        ComposerStarter(id: "choose", text: "Which one would you choose?", textAr: "أيهما ستختار؟", kind: .poll),
        ComposerStarter(id: "unpopular", text: "Unpopular opinion: ", textAr: "رأي غير شائع: ")
    ]

    public static var samplePoll: Poll {
        Poll(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000901")!,
            options: [
                PollOption(id: UUID(uuidString: "00000000-0000-4000-8000-000000000911")!, position: 0, text: "Tea"),
                PollOption(id: UUID(uuidString: "00000000-0000-4000-8000-000000000912")!, position: 1, text: "Coffee")
            ],
            totalVotes: 4,
            closesAt: Date().addingTimeInterval(3 * 3600),
            resultsVisibility: .afterVote,
            resultsVisible: false,
            canVote: true
        )
    }

    static var openQuestion: Post {
        Post(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000950")!,
            author: FeedServiceMock.maria,
            text: "Anyone know a good Arabic course for beginners in Riyadh?",
            createdAt: Date().addingTimeInterval(-40 * 60),
            language: "en",
            viewer: PostViewerState(canReply: true)
        )
    }

    static var pollPost: Post {
        Post(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000951")!,
            author: FeedServiceMock.noor,
            text: "Tea or coffee for the morning?",
            createdAt: Date().addingTimeInterval(-20 * 60),
            language: "en",
            viewer: PostViewerState(canReply: true),
            poll: samplePoll
        )
    }
}
