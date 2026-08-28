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
}

extension FeedServiceProtocol {
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
