import Foundation

/// The production ``DiscoverServiceProtocol``.
public final class DiscoverService: DiscoverServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    public func fetchNeedsReply(cursor: String?) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await network.send(
            APIRequest(path: "/discover/needs-reply", accessToken: token, query: query),
            as: FeedPage.self
        )
    }

    public func fetchPeople(topics: [String], limit: Int) async throws -> [SuggestedPerson] {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 40)))]
        query += topics.map { URLQueryItem(name: "topic", value: $0) }
        return try await network.send(
            APIRequest(path: "/discover/people", accessToken: token, query: query),
            as: PeopleResponse.self
        ).people
    }

    public func fetchTrending(topics: [String]) async throws -> [TrendingSection] {
        let token = try await tokens.accessToken()
        let query = topics.map { URLQueryItem(name: "topic", value: $0) }
        return try await network.send(
            APIRequest(path: "/discover/trending", accessToken: token, query: query),
            as: TrendingResponseV19.self
        ).sections
    }

    public func fetchStarters() async throws -> [ComposerStarter] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/composer/starters", accessToken: token),
            as: StartersResponse.self
        ).starters
    }

    public func vote(postId: UUID, optionId: UUID) async throws -> Poll {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/posts/\(postId.uuidString.lowercased())/poll/votes",
            body: PollVoteRequest(optionId: optionId),
            accessToken: token
        )
        let poll = try await network.send(request, as: Poll.self)
        analytics.track(.pollVoted, properties: ["post_id": postId.uuidString.lowercased()])
        return poll
    }

    public func fetchPoll(postId: UUID) async throws -> Poll {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/posts/\(postId.uuidString.lowercased())/poll", accessToken: token),
            as: Poll.self
        )
    }

    public func submitOnboardingInterests(topics: [String], skipped: Bool) async throws -> FeedPreferences {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/onboarding/interests",
            body: OnboardingInterestsRequest(topics: topics, skipped: skipped),
            accessToken: token
        )
        let stored = try await network.send(request, as: FeedPreferences.self)
        analytics.track(skipped ? .onboardingInterestsSkipped : .onboardingInterestsChosen, properties: [
            "count": String(topics.count)
        ])
        return stored
    }
}
