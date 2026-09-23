import Foundation

/// The engagement surfaces of contract v19: somewhere to start, a poll to
/// answer, and the first-run subjects step.
public protocol DiscoverServiceProtocol: Sendable {
    /// `GET /discover/needs-reply` — unanswered posts this viewer may answer.
    func fetchNeedsReply(cursor: String?) async throws -> FeedPage
    /// `GET /discover/people` — verified people worth following.
    func fetchPeople(topics: [String], limit: Int) async throws -> [SuggestedPerson]
    /// `GET /discover/trending` — the most-discussed posts per subject.
    func fetchTrending(topics: [String]) async throws -> [TrendingSection]
    /// `GET /composer/starters`.
    func fetchStarters() async throws -> [ComposerStarter]
    /// `POST /posts/{id}/poll/votes` — one anonymous, final vote.
    func vote(postId: UUID, optionId: UUID) async throws -> Poll
    /// `GET /posts/{id}/poll`.
    func fetchPoll(postId: UUID) async throws -> Poll
    /// `POST /me/onboarding/interests` — answer or skip the subjects step.
    func submitOnboardingInterests(topics: [String], skipped: Bool) async throws -> FeedPreferences
}
