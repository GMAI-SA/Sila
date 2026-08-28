import Foundation

/// The production ``FeedServiceProtocol``.
///
/// Talks to contract v2 at `https://sila.gmai.sa/api/v1` through the injected
/// ``NetworkClient``. It holds no session state: the bearer token comes from
/// ``AccessTokenProviding`` on every call, so a token that rotated in the
/// background is picked up without this type knowing that happened.
public final class FeedService: FeedServiceProtocol {

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

    // MARK: - Feeds

    public func fetchFeed(_ tab: FeedTab, cursor: String?, limit: Int) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(clamped(limit)))]
        // An empty cursor is not the same as no cursor — send the parameter
        // only when the server actually gave us one.
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let request = APIRequest(path: tab.path, accessToken: token, query: query)
        let page = try await network.send(request, as: FeedPage.self)
        analytics.track(.feedLoaded, properties: [
            "tab": tab.rawValue,
            "count": String(page.posts.count),
            "page": cursor == nil ? "first" : "next"
        ])
        return page
    }

    // MARK: - Posts

    public func fetchPost(_ id: UUID) async throws -> Post {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/posts/\(id.uuidString.lowercased())", accessToken: token),
            as: Post.self
        )
    }

    public func fetchReplies(for postId: UUID, cursor: String?) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await network.send(
            APIRequest(
                path: "/posts/\(postId.uuidString.lowercased())/replies",
                accessToken: token,
                query: query
            ),
            as: FeedPage.self
        )
    }

    public func deletePost(_ id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(path: "/posts/\(id.uuidString.lowercased())", method: .delete, accessToken: token)
        )
    }

    // MARK: - Engagement

    public func setLiked(_ liked: Bool, postId: UUID) async throws -> PostMetrics {
        let metrics = try await toggle("like", on: liked, postId: postId)
        analytics.track(liked ? .postLiked : .postUnliked)
        return metrics
    }

    public func setReposted(_ reposted: Bool, postId: UUID) async throws -> PostMetrics {
        let metrics = try await toggle("repost", on: reposted, postId: postId)
        analytics.track(reposted ? .postReposted : .postUnreposted)
        return metrics
    }

    public func setBookmarked(_ bookmarked: Bool, postId: UUID) async throws -> PostMetrics {
        let metrics = try await toggle("bookmark", on: bookmarked, postId: postId)
        analytics.track(bookmarked ? .postBookmarked : .postUnbookmarked)
        return metrics
    }

    // MARK: - Plumbing

    /// `POST` adds the interaction, `DELETE` removes it; both answer `metrics`.
    private func toggle(_ action: String, on: Bool, postId: UUID) async throws -> PostMetrics {
        let token = try await tokens.accessToken()
        let request = APIRequest(
            path: "/posts/\(postId.uuidString.lowercased())/\(action)",
            method: on ? .post : .delete,
            accessToken: token
        )
        return try await network.send(request, as: PostMetrics.self)
    }

    private func clamped(_ limit: Int) -> Int {
        min(max(limit, 1), FeedConstants.maximumPageSize)
    }
}
