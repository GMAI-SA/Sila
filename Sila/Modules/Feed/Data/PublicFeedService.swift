import Foundation

/// The read-only half of the API, for somebody who has not joined yet.
///
/// Conforms to the same ``FeedServiceProtocol`` the signed-in app uses, so
/// every screen that shows posts works unchanged for a guest. The half of
/// the protocol that *changes* something throws ``APIError/signInRequired``
/// without touching the network: the server would answer exactly that, and
/// a round trip to be told so would only make the invitation slower.
public final class PublicFeedService: FeedServiceProtocol {

    private let network: NetworkClient
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, analytics: AnalyticsClient) {
        self.network = network
        self.analytics = analytics
    }

    // MARK: - Reading

    public func fetchFeed(_ tab: FeedTab, cursor: String?, limit: Int) async throws -> FeedPage {
        try await fetchFeed(tab, topics: [], cursor: cursor, limit: limit)
    }

    public func fetchFeed(_ tab: FeedTab, topics: [String], cursor: String?, limit: Int) async throws -> FeedPage {
        // There is one timeline before you join: the square. "For You" needs
        // a you, and the country feed belongs to people an identity check has
        // placed somewhere.
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 30)))]
        for subject in topics where !subject.isEmpty {
            query.append(URLQueryItem(name: "topic", value: subject))
        }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await network.send(APIRequest(path: "/public/feed", query: query), as: FeedPage.self)
        analytics.track(.feedLoaded, properties: [
            "tab": "public", "count": String(page.posts.count), "page": cursor == nil ? "first" : "next"
        ])
        return page
    }

    public func fetchPost(_ id: UUID) async throws -> Post {
        try await network.send(APIRequest(path: "/public/posts/\(id.uuidString.lowercased())"), as: Post.self)
    }

    public func fetchReplies(for postId: UUID, cursor: String?) async throws -> FeedPage {
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await network.send(
            APIRequest(path: "/public/posts/\(postId.uuidString.lowercased())/replies", query: query),
            as: FeedPage.self
        )
    }

    public func fetchHashtag(_ tag: String) async throws -> HashtagHeader {
        // The header carries a remembered ordering, which belongs to an
        // account. A guest gets the tag and the count from the page itself.
        let page = try await fetchHashtagPosts(tag, sort: nil, cursor: nil)
        return HashtagHeader(tag: page.tag, postCount: page.postCount, sort: .newest)
    }

    public func fetchHashtagPosts(_ tag: String, sort: HashtagSort?, cursor: String?) async throws -> HashtagPage {
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let bare = FeedService.tagComponent(tag)
        let page = try await network.send(
            APIRequest(path: "/public/hashtags/\(bare)/posts", query: query),
            as: FeedPage.self
        )
        return HashtagPage(
            posts: page.posts,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            tag: HashtagViewModel.normalised(tag),
            sort: .newest,
            postCount: page.posts.count
        )
    }

    /// The subject strip's vocabulary, for somebody with no account.
    public func fetchTopics() async throws -> [TopicOption] {
        struct Envelope: Decodable { let topics: [TopicOption] }
        return try await network.send(APIRequest(path: "/public/topics"), as: Envelope.self).topics
    }

    // MARK: - Everything that acts

    public func setLiked(_ liked: Bool, postId: UUID) async throws -> PostMetrics { throw APIError.signInRequired }
    public func setReposted(_ reposted: Bool, postId: UUID) async throws -> PostMetrics { throw APIError.signInRequired }
    public func setBookmarked(_ bookmarked: Bool, postId: UUID) async throws -> PostMetrics { throw APIError.signInRequired }
    public func deletePost(_ id: UUID) async throws { throw APIError.signInRequired }
    public func fetchBookmarks(cursor: String?) async throws -> FeedPage { throw APIError.signInRequired }
}
