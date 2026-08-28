import Foundation

/// The production ``SearchServiceProtocol``.
///
/// Talks to contract v3's `/search/*` and `/explore/trending` through the
/// injected ``NetworkClient``, with the bearer token fetched per call.
public final class SearchService: SearchServiceProtocol {

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

    public func searchUsers(query: String, limit: Int) async throws -> [UserSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The contract says a short query returns nothing. Spending a round trip
        // to be told that would make every second keystroke a wasted request.
        guard trimmed.count >= SearchConstants.minimumQueryLength else { return [] }

        let token = try await tokens.accessToken()
        let request = APIRequest(
            path: "/search/users",
            accessToken: token,
            query: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "limit", value: String(clamp(limit, max: SearchConstants.maximumUserLimit)))
            ]
        )
        return try await network.send(request, as: UserSearchResponse.self).users
    }

    public func searchPosts(query: String, cursor: String?, limit: Int) async throws -> FeedPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= SearchConstants.minimumQueryLength else { return .empty }

        let token = try await tokens.accessToken()
        var items = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(clamp(limit, max: FeedConstants.maximumPageSize)))
        ]
        // An empty cursor is not the same as no cursor.
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }

        let page = try await network.send(
            APIRequest(path: "/search/posts", accessToken: token, query: items),
            as: FeedPage.self
        )
        analytics.track(.searchPerformed, properties: [
            "kind": "posts",
            "results": String(page.posts.count),
            "page": cursor == nil ? "first" : "next"
        ])
        return page
    }

    public func trendingTags(limit: Int) async throws -> [TrendingTag] {
        let token = try await tokens.accessToken()
        let request = APIRequest(
            path: "/explore/trending",
            accessToken: token,
            query: [
                URLQueryItem(
                    name: "limit",
                    value: String(clamp(limit, max: SearchConstants.maximumTrendingLimit))
                )
            ]
        )
        return try await network.send(request, as: TrendingResponse.self).tags
    }

    private func clamp(_ value: Int, max ceiling: Int) -> Int {
        min(Swift.max(value, 1), ceiling)
    }
}
