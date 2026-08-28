import Foundation

/// Everything the Search module can ask the backend to do (contract v3).
///
/// The seam Explore and the composer's `@mention` autocomplete both depend on;
/// ``SearchService`` and ``SearchServiceMock`` are interchangeable behind it.
public protocol SearchServiceProtocol: Sendable {

    /// Finds accounts by handle or display name, verified first.
    /// - Parameters:
    ///   - query: Raw search text. Trimmed by the implementation.
    ///   - limit: Page size, clamped to the contract's maximum of 20.
    /// - Returns: An empty array — with no request made — for a query shorter
    ///   than ``SearchConstants/minimumQueryLength``, which is what the server
    ///   would answer anyway.
    func searchUsers(query: String, limit: Int) async throws -> [UserSummary]

    /// Case-insensitive substring search over post text, newest first.
    /// - Parameters:
    ///   - query: Raw search text.
    ///   - cursor: An opaque cursor the server previously returned.
    ///   - limit: Page size, clamped to ``FeedConstants/maximumPageSize``.
    func searchPosts(query: String, cursor: String?, limit: Int) async throws -> FeedPage

    /// Hashtags counted across the most recent posts.
    /// - Parameter limit: Clamped to the contract's maximum of 20.
    func trendingTags(limit: Int) async throws -> [TrendingTag]
}

extension SearchServiceProtocol {

    /// Finds accounts using the contract's default limit of 8.
    public func searchUsers(query: String) async throws -> [UserSummary] {
        try await searchUsers(query: query, limit: SearchConstants.defaultUserLimit)
    }

    /// Searches posts using the contract's default page size.
    public func searchPosts(query: String, cursor: String? = nil) async throws -> FeedPage {
        try await searchPosts(query: query, cursor: cursor, limit: FeedConstants.defaultPageSize)
    }

    /// Fetches trending tags using the contract's default limit of 10.
    public func trendingTags() async throws -> [TrendingTag] {
        try await trendingTags(limit: SearchConstants.defaultTrendingLimit)
    }
}
