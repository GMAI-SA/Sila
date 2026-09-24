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
        try await fetchFeed(tab, topics: [], cursor: cursor, limit: limit)
    }

    public func fetchFeed(_ tab: FeedTab, topics: [String], cursor: String?, limit: Int) async throws -> FeedPage {
        try await fetchFeed(tab, topics: topics, cursor: cursor, limit: limit, extra: [])
    }

    private func fetchFeed(
        _ tab: FeedTab, topics: [String], cursor: String?, limit: Int, extra: [URLQueryItem]
    ) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(clamped(limit)))] + extra
        // Sent only when one is pinned: an empty value would mean the same
        // thing to the server, but a request that states its empties is a
        // request whose logs cannot be read at a glance.
        // One `topic` per subject: the server reads them as "any of these".
        for subject in topics where !subject.isEmpty {
            query.append(URLQueryItem(name: "topic", value: subject))
        }
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
            "page": cursor == nil ? "first" : "next",
            "subject": topics.isEmpty ? "all" : topics.joined(separator: ",")
        ])
        return page
    }

    public func fetchBookmarks(cursor: String?) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(clamped(20)))]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await network.send(
            APIRequest(path: "/me/bookmarks", accessToken: token, query: query),
            as: FeedPage.self
        )
    }

    // MARK: - Hashtags

    public func fetchHashtag(_ tag: String) async throws -> HashtagHeader {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/hashtags/\(Self.tagComponent(tag))", accessToken: token),
            as: HashtagHeader.self
        )
    }

    public func fetchHashtagPosts(_ tag: String, sort: HashtagSort?, cursor: String?) async throws -> HashtagPage {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(clamped(20)))]
        if let sort { query.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await network.send(
            APIRequest(path: "/hashtags/\(Self.tagComponent(tag))/posts", accessToken: token, query: query),
            as: HashtagPage.self
        )
        analytics.track(.hashtagLoaded, properties: [
            "sort": page.sort.rawValue,
            "count": String(page.posts.count),
            "page": cursor == nil ? "first" : "next"
        ])
        return page
    }

    /// The tag as a path segment: no `#`, percent-encoded so an Arabic tag
    /// travels intact.
    static func tagComponent(_ tag: String) -> String {
        let bare = tag.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" })
        return String(bare).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(bare)
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

    public func setReaction(_ kind: ReactionKind, on: Bool, postId: UUID) async throws -> PostMetrics {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/posts/\(postId.uuidString.lowercased())/reactions/\(kind.rawValue)",
                       method: on ? .post : .delete, accessToken: token),
            as: PostMetrics.self
        )
    }

    public func fetchThread(_ id: UUID) async throws -> PostThread {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/posts/\(id.uuidString.lowercased())/thread", accessToken: token,
                       query: [URLQueryItem(name: "limit", value: "30")]),
            as: PostThread.self
        )
    }

    public func setHidden(_ hidden: Bool, replyId: UUID) async throws -> Post {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(
                path: "/posts/\(replyId.uuidString.lowercased())/hide",
                method: hidden ? .post : .delete,
                accessToken: token
            ),
            as: Post.self
        )
    }

    public func fetchFeed(_ tab: FeedTab, topics: [String], order: FeedOrder, cursor: String?, limit: Int) async throws -> FeedPage {
        try await fetchFeed(tab, topics: topics, cursor: cursor, limit: limit, extra: order == .newest && tab == .forYou
            ? [URLQueryItem(name: "sort", value: "new")] : [])
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
