import Foundation

/// Everything the Notifications module can ask the backend to do.
///
/// The seam ``NotificationsViewModel`` depends on; ``NotificationsService`` and
/// ``NotificationsServiceMock`` are interchangeable behind it, which is what
/// lets the one destructive path on this surface — marking everything read —
/// be driven end to end without doing it to a real account.
///
/// **Marking read is split into two methods, not one with an optional array.**
/// `POST /notifications/read` means "all of them" when the body is `{}` and
/// "these" when it carries `ids`; an `ids: [UUID]?` parameter would make an
/// accidental `nil` — an empty array that got optionalised somewhere upstream —
/// silently clear somebody's entire unread state. Two names cannot do that.
public protocol NotificationsServiceProtocol: Sendable {

    /// One page of `GET /notifications`, newest first.
    ///
    /// - Parameters:
    ///   - cursor: An opaque cursor the server previously returned, or `nil`
    ///     for the first page. Never construct one.
    ///   - limit: Page size. The server validates 1…50 and answers 422 outside
    ///     that, so the service clamps before sending.
    ///   - unreadOnly: Narrows to unread rows.
    /// - Returns: The page, including the server's authoritative unread count.
    func fetchNotifications(cursor: String?, limit: Int, unreadOnly: Bool) async throws -> NotificationPage

    /// The unread count on its own, `GET /notifications/unread-count`.
    ///
    /// Used for the tab-bar badge when the list is not on screen, so the badge
    /// is never a number this client worked out for itself.
    func fetchUnreadCount() async throws -> Int

    /// Marks specific notifications read, `POST /notifications/read` with `ids`.
    /// - Returns: What the server flipped, and what is left unread.
    func markRead(ids: [UUID]) async throws -> NotificationReadResult

    /// Marks **everything** read, `POST /notifications/read` with `{}`.
    ///
    /// Irreversible: there is no endpoint that puts an unread mark back. It is
    /// therefore only ever called from an explicit control the user pressed,
    /// never from a screen appearing.
    func markAllRead() async throws -> NotificationReadResult
}

extension NotificationsServiceProtocol {
    /// Fetches a page with the contract's defaults.
    public func fetchNotifications(cursor: String? = nil) async throws -> NotificationPage {
        try await fetchNotifications(
            cursor: cursor,
            limit: NotificationConstants.defaultPageSize,
            unreadOnly: false
        )
    }
}

/// Paging constants from the notifications contract.
public enum NotificationConstants {
    /// The server's default `limit`.
    public static let defaultPageSize = 20
    /// The server's hard maximum `limit`; anything above answers 422.
    public static let maximumPageSize = 50
    /// How many rows from the bottom the pager pre-fetches the next page.
    public static let prefetchThreshold = 3
}
