import Foundation

/// The production ``NotificationsServiceProtocol``.
///
/// Talks to `/notifications` through the injected ``NetworkClient``. Like every
/// other service it holds no session state: the bearer token is fetched per
/// call from ``AccessTokenProviding``.
public final class NotificationsService: NotificationsServiceProtocol {

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

    // MARK: - Reading

    public func fetchNotifications(
        cursor: String?,
        limit: Int,
        unreadOnly: Bool
    ) async throws -> NotificationPage {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(clamped(limit)))]
        // An empty cursor is not the same as no cursor — send the parameter
        // only when the server actually gave us one.
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        // Only sent when it is doing something. `unread_only=false` is the
        // server's default, and a URL that states defaults is a URL whose logs
        // cannot be read at a glance.
        if unreadOnly {
            query.append(URLQueryItem(name: "unread_only", value: "true"))
        }
        let page = try await network.send(
            APIRequest(path: "/notifications", accessToken: token, query: query),
            as: NotificationPage.self
        )
        analytics.track(.notificationsLoaded, properties: [
            "count": String(page.notifications.count),
            "unread": String(page.unreadCount),
            "page": cursor == nil ? "first" : "next",
            "filter": unreadOnly ? "unread" : "all"
        ])
        return page
    }

    public func fetchUnreadCount() async throws -> Int {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/notifications/unread-count", accessToken: token),
            as: NotificationUnreadCount.self
        ).unread
    }

    // MARK: - Marking read

    public func markRead(ids: [UUID]) async throws -> NotificationReadResult {
        // An empty array would encode as `{"ids": []}`. Whether the server
        // reads that as "none" or falls through to "all" is not something to
        // find out on somebody's real unread state, so it never leaves here.
        guard !ids.isEmpty else { return NotificationReadResult(markedRead: 0, unread: try await fetchUnreadCount()) }
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/notifications/read",
            method: .post,
            // Lower-cased strings rather than `UUID`, whose synthesised
            // encoding is upper case. Postgres does not care; a server that
            // string-matched would.
            body: MarkReadRequest(ids: ids.map { $0.uuidString.lowercased() }),
            accessToken: token
        )
        let result = try await network.send(request, as: NotificationReadResult.self)
        analytics.track(.notificationsMarkedRead, properties: [
            "scope": "ids",
            "marked": String(result.markedRead),
            "unread": String(result.unread)
        ])
        return result
    }

    public func markAllRead() async throws -> NotificationReadResult {
        let token = try await tokens.accessToken()
        // `{}` — an empty body, not a missing one. The contract distinguishes
        // them, and a `POST` with no body at all is a different request.
        let request = APIRequest(
            path: "/notifications/read",
            method: .post,
            body: Data("{}".utf8),
            accessToken: token
        )
        let result = try await network.send(request, as: NotificationReadResult.self)
        analytics.track(.notificationsMarkedRead, properties: [
            "scope": "all",
            "marked": String(result.markedRead),
            "unread": String(result.unread)
        ])
        return result
    }

    // MARK: - Plumbing

    private func clamped(_ limit: Int) -> Int {
        min(max(limit, 1), NotificationConstants.maximumPageSize)
    }
}

/// The `{"ids": [...]}` body of a targeted `POST /notifications/read`.
struct MarkReadRequest: Encodable, Equatable, Sendable {
    let ids: [String]
}
