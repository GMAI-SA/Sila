import Foundation

/// The production ``PreferencesServiceProtocol``.
///
/// Talks to contract v4's `/topics` and `/me/preferences` through the injected
/// ``NetworkClient``. Like every other service it holds no session state: the
/// bearer token is fetched per call from ``AccessTokenProviding``.
public final class PreferencesService: PreferencesServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - network: HTTP transport.
    ///   - tokens: Supplies the bearer token.
    ///   - analytics: Event sink.
    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    public func fetchTopics() async throws -> [TopicOption] {
        let token = try await tokens.accessToken()
        let request = APIRequest(path: "/topics", accessToken: token)
        return try await network.send(request, as: TopicsResponse.self).topics
    }

    public func fetchPreferences() async throws -> FeedPreferences {
        let token = try await tokens.accessToken()
        let request = APIRequest(path: "/me/preferences", accessToken: token)
        return try await network.send(request, as: FeedPreferences.self)
    }

    public func updatePreferences(_ update: PreferencesUpdate) async throws -> FeedPreferences {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/preferences",
            method: .put,
            body: update,
            accessToken: token
        )
        let stored = try await network.send(request, as: FeedPreferences.self)

        analytics.track(.preferencesSaved, properties: [
            "interests": String(stored.interests.count),
            "muted_topics": String(stored.mutedTopics.count),
            "muted_countries": String(stored.mutedCountries.count),
            // The honest field: whether the feed is genuinely narrowed, not
            // whether the switch is on.
            "narrows": String(stored.narrowsToInterests)
        ])
        return stored
    }
}
