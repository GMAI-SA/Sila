import Foundation

/// Everything the Profile module can ask the backend to do.
///
/// The seam ``ProfileScreen`` depends on; ``ProfileService`` and
/// ``ProfileServiceMock`` are interchangeable behind it, which is what lets the
/// follow reconciliation — the one piece of state two devices can disagree
/// about — be driven end to end without a network.
///
/// > Note: There is no `fetchTimeline` returning some profile-specific page
/// > type. `GET /users/{handle}/posts` answers the **same `FeedPageOut`** the
/// > four feeds answer, so it decodes into ``FeedPage`` and pages with the same
/// > opaque cursors. A parallel page type would be a second place for a cursor
/// > bug to live.
public protocol ProfileServiceProtocol: Sendable {

    /// One account as this viewer sees it, `GET /users/{handle}`.
    ///
    /// - Throws: ``APIError`` with ``APIErrorCode/userNotFound`` (HTTP 404) for
    ///   an unknown **or deactivated** handle. The two are deliberately
    ///   indistinguishable: a deactivated account has asked not to be here, and
    ///   an error that admitted the account exists would leak that.
    func fetchProfile(handle: String) async throws -> Profile

    /// One page of an account's **top-level** posts, `GET /users/{handle}/posts`.
    ///
    /// Replies are excluded by the server (`reply_to_post_id IS NULL`), so this
    /// is not everything the person has written and must never be labelled as
    /// though it were.
    /// - Parameters:
    ///   - handle: The account.
    ///   - cursor: An opaque cursor the server previously returned, or `nil` for
    ///     the first page. Never construct one.
    ///   - limit: Page size. **The server rejects anything outside 1…50 with a
    ///     422 rather than clamping**, so implementations clamp before sending.
    /// - Throws: ``APIErrorCode/userNotFound`` (HTTP 404).
    func fetchPosts(handle: String, cursor: String?, limit: Int) async throws -> FeedPage

    /// Follows or unfollows an account.
    ///
    /// `POST` and `DELETE /users/{handle}/follow` are both idempotent, so this
    /// takes the **desired state** rather than an action: asking to follow
    /// somebody you already follow is a success, and so is the reverse.
    /// - Returns: The authoritative relationship and follower count afterwards.
    /// - Throws: ``APIErrorCode/selfFollow`` (HTTP 400) when the handle is the
    ///   viewer's own, ``APIErrorCode/userNotFound`` (HTTP 404) otherwise.
    func setFollowing(_ following: Bool, handle: String) async throws -> FollowResult

    /// The people waiting to follow the viewer's private account,
    /// `GET /me/follow-requests`, newest first.
    func fetchFollowRequests() async throws -> [FollowRequest]

    /// Answers one request.
    ///
    /// Accepting makes them a follower and tells them. Declining removes the
    /// request and tells **nobody** — they may ask again, and be declined
    /// again, silently. Nothing in this app describes a decline as sent.
    /// - Throws: ``APIErrorCode/notFound`` (HTTP 404) when there is no such
    ///   request — it was answered from another device, or withdrawn.
    func answerFollowRequest(handle: String, accept: Bool) async throws
}

extension ProfileServiceProtocol {
    /// Fetches a page using the contract's default limit of 20.
    public func fetchPosts(handle: String, cursor: String? = nil) async throws -> FeedPage {
        try await fetchPosts(handle: handle, cursor: cursor, limit: FeedConstants.defaultPageSize)
    }
}
