import Foundation

/// Everything the Feed module can ask the backend to do.
///
/// The seam every feed view model depends on; ``FeedService`` and
/// ``FeedServiceMock`` are interchangeable behind it, which is what makes the
/// view-model tests honest.
///
/// > Note: The Phase-3 spec listed separate `fetchForYouFeed` / `fetchFollowingFeed`
/// > methods. The v4 product has four feeds that differ only by path, so they
/// > collapse into one call parameterised by ``FeedTab`` — adding a fifth feed
/// > later is a new enum case, not a new protocol requirement.
public protocol FeedServiceProtocol: Sendable {

    /// Fetches one page of a feed.
    /// - Parameters:
    ///   - tab: Which feed.
    ///   - cursor: An opaque cursor the server previously returned, or `nil` for
    ///     the first page. Never construct one.
    ///   - limit: Page size. The server clamps to 1…50; 20 is the default.
    /// - Throws: ``APIError`` with ``APIErrorCode/noCountry`` (HTTP 409) from
    ///   ``FeedTab/myCountry`` when the viewer has no verified country.
    func fetchFeed(_ tab: FeedTab, cursor: String?, limit: Int) async throws -> FeedPage

    /// The same feed, narrowed to the subjects pinned in the strip above the
    /// timeline. An empty array means nothing is pinned.
    ///
    /// Several subjects mean posts about **any** of them: somebody who taps
    /// Sports and Finance is asking for two conversations, not for the rare
    /// post about both.
    ///
    /// Given a default below rather than made a requirement, so a service
    /// that knows nothing about subjects serves the whole feed instead of
    /// failing to compile. The two that do know — ``FeedService`` and
    /// ``PublicFeedService`` — implement it.
    func fetchFeed(_ tab: FeedTab, topics: [String], cursor: String?, limit: Int) async throws -> FeedPage

    /// Fetches a single post.
    /// - Throws: ``APIError`` with ``APIErrorCode/postNotFound``.
    func fetchPost(_ id: UUID) async throws -> Post

    /// Fetches one page of a post's direct replies, chronologically.
    func fetchReplies(for postId: UUID, cursor: String?) async throws -> FeedPage

    /// Adds or removes a like.
    /// - Returns: The authoritative metrics after the change.
    func setLiked(_ liked: Bool, postId: UUID) async throws -> PostMetrics

    /// Adds or removes a repost.
    func setReposted(_ reposted: Bool, postId: UUID) async throws -> PostMetrics

    /// Adds or removes a bookmark.
    func setBookmarked(_ bookmarked: Bool, postId: UUID) async throws -> PostMetrics

    /// Deletes a post the viewer authored.
    /// - Throws: ``APIError`` with ``APIErrorCode/notPostAuthor``.
    func deletePost(_ id: UUID) async throws

    /// What the viewer bookmarked, newest save first — `GET /me/bookmarks`.
    /// Private: nobody else can read this list, and reading it never tells an
    /// author their post was saved.
    func fetchBookmarks(cursor: String?) async throws -> FeedPage

    /// A hashtag's header — `GET /hashtags/{tag}` (contract v17).
    func fetchHashtag(_ tag: String) async throws -> HashtagHeader

    /// One page of a hashtag — `GET /hashtags/{tag}/posts`. A `nil` sort asks
    /// for the order the account keeps in its preferences.
    func fetchHashtagPosts(_ tag: String, sort: HashtagSort?, cursor: String?) async throws -> HashtagPage

    /// A feed page in a chosen order (contract v19). Defaulted below.
    func fetchFeed(_ tab: FeedTab, topics: [String], order: FeedOrder, cursor: String?, limit: Int) async throws -> FeedPage

    /// Collapse or restore a reply in your own thread. Defaulted below.
    func setHidden(_ hidden: Bool, replyId: UUID) async throws -> Post
}

/// How For You is ordered (contract v19): ranked — newest first, lifted for
/// saved subjects and for replies — or strictly newest.
public enum FeedOrder: String, Sendable, CaseIterable, Identifiable {
    case ranked
    case newest

    public var id: String { rawValue }

    public var title: String {
        L10n.t(self == .ranked ? "feed.order.ranked" : "feed.order.newest")
    }
}

extension FeedServiceProtocol {
    /// A feed page in a chosen order. Only For You has more than one order;
    /// stubs that do not implement it serve their one order.
    public func fetchFeed(_ tab: FeedTab, topics: [String], order: FeedOrder, cursor: String?, limit: Int) async throws -> FeedPage {
        try await fetchFeed(tab, topics: topics, cursor: cursor, limit: limit)
    }

    /// `POST`/`DELETE /posts/{id}/hide` — collapse a reply in your own thread.
    /// Returns the reply as the server now holds it; its `hiddenByAuthor` is
    /// the confirmation. Stubs that never hide inherit this refusal.
    public func setHidden(_ hidden: Bool, replyId: UUID) async throws -> Post {
        throw APIError.transport("Hiding replies is not available here")
    }

    /// A service with no notion of subjects serves the whole feed.
    public func fetchFeed(_ tab: FeedTab, topics: [String], cursor: String?, limit: Int) async throws -> FeedPage {
        try await fetchFeed(tab, cursor: cursor, limit: limit)
    }

    /// Fetches a page using the contract's default limit of 20.
    public func fetchFeed(_ tab: FeedTab, cursor: String? = nil) async throws -> FeedPage {
        try await fetchFeed(tab, cursor: cursor, limit: FeedConstants.defaultPageSize)
    }
}

/// Paging constants from the API contract.
public enum FeedConstants {
    /// The server's default `limit`.
    public static let defaultPageSize = 20
    /// The server's hard maximum `limit`.
    public static let maximumPageSize = 50
    /// Maximum post length the server accepts, in characters.
    public static let maximumPostLength = 280
    /// How many rows from the bottom the pager pre-fetches the next page.
    public static let prefetchThreshold = 3
}
