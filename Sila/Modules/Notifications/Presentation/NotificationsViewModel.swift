import Foundation
import Observation

/// Which slice of the list is on screen.
public enum NotificationFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Everything, read and unread.
    case all
    /// `unread_only=true`.
    case unread

    public var id: String { rawValue }

    /// Segment label.
    public var title: String {
        switch self {
        case .all: return L10n.t("notifications.filter.all")
        case .unread: return L10n.t("notifications.filter.unread")
        }
    }

    /// Accessibility hint for the segmented control.
    public var accessibilityHint: String {
        switch self {
        case .all: return L10n.t("notifications.filter.all.hint")
        case .unread: return L10n.t("notifications.filter.unread.hint")
        }
    }
}

/// Where a tapped row leads.
///
/// Returned from ``NotificationsViewModel/open(_:)`` rather than pushed by the
/// view model itself, so navigation stays where every other screen keeps it and
/// a test can assert *what* a row opens without a navigation stack.
public enum NotificationDestination: Equatable, Sendable {
    /// A post row — the post has already been fetched, because
    /// ``FeedRoute/postDetail(_:)`` carries a whole ``Post``.
    case post(Post)
    /// A follow row — nothing to fetch, the handle is enough.
    case profile(handle: String)
}

/// Drives ``NotificationsScreen``.
///
/// Three rules shape it.
///
/// **The unread count is never counted here.** Every number on screen comes out
/// of a server response — the page's `unread_count`, or the read call's
/// `unread`. The server hides notifications from blocked and deactivated
/// accounts, so a count derived from the rows this client happens to hold would
/// drift away from the truth and the badge would start disagreeing with the
/// list it belongs to.
///
/// **Nothing is marked read by arriving.** Opening the tab loads and displays;
/// it does not clear. The only two things that mark anything read are the
/// explicit "Mark all read" control and opening one specific row — both of them
/// something the person did on purpose. Auto-clearing on appearance would
/// destroy the single signal that says what somebody has not seen yet, and
/// there is no endpoint to put it back.
///
/// **A row is never dropped for being awkward.** A notification whose post has
/// been deleted still renders, without an excerpt. "Someone replied to you" is
/// true whatever happened to the reply afterwards.
@MainActor
@Observable
public final class NotificationsViewModel {

    /// The visible slice.
    public private(set) var filter: NotificationFilter = .all
    /// The rows, newest first.
    public private(set) var notifications: [UserNotification] = []
    /// The server's unread count. Never computed from ``notifications``.
    public private(set) var unreadCount = 0
    /// The cursor for the next page, or `nil` at the end.
    public private(set) var cursor: String?
    /// Whether the server says another page exists.
    public private(set) var hasMore = false
    /// `true` during the first load.
    public private(set) var isLoading = false
    /// `true` while another page is being appended.
    public private(set) var isLoadingMore = false
    /// `true` during pull-to-refresh.
    public private(set) var isRefreshing = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the list could not load. Already user-safe.
    public private(set) var loadError: String?
    /// `true` while "Mark all read" is in flight.
    public private(set) var isMarkingAll = false
    /// The row whose target is being fetched, if any.
    public private(set) var openingId: UUID?
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: NotificationsServiceProtocol
    private let feed: FeedServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?

    /// - Parameters:
    ///   - service: Notifications backend.
    ///   - feed: Used to fetch the post behind a tapped row, because the post
    ///     detail route carries a whole ``Post`` and a notification carries
    ///     only its id.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    public init(
        service: NotificationsServiceProtocol,
        feed: FeedServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil
    ) {
        self.service = service
        self.feed = feed
        self.analytics = analytics
        self.suspension = suspension
    }

    // MARK: - Derived state

    /// `true` when the visible list has nothing in it and nothing went wrong.
    public var isEmpty: Bool {
        hasLoaded && loadError == nil && notifications.isEmpty
    }

    /// `true` when there is anything for "Mark all read" to do.
    ///
    /// Derived from the **server's** count, not from the rows on screen: page
    /// one can be entirely read while page four is not.
    public var canMarkAllRead: Bool { unreadCount > 0 && !isMarkingAll }

    /// The line above the list.
    public var unreadSummary: String { NotificationCopy.unreadSummary(unreadCount) }

    /// Whether a specific row is waiting on its target.
    public func isOpening(_ notification: UserNotification) -> Bool {
        openingId == notification.id
    }

    // MARK: - Loading

    /// Loads the first page. Safe on every appearance — it does nothing once
    /// loaded, which is also what stops a tab switch from silently refetching
    /// over somebody's place in a list.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry and pull-to-refresh path.
    public func reload(isRefresh: Bool = false) async {
        if isRefresh {
            isRefreshing = true
        } else {
            isLoading = true
        }
        loadError = nil
        defer {
            isLoading = false
            isRefreshing = false
            hasLoaded = true
        }

        do {
            let page = try await service.fetchNotifications(
                cursor: nil,
                limit: NotificationConstants.defaultPageSize,
                unreadOnly: filter == .unread
            )
            adopt(page, appending: false)
        } catch {
            guard suspension?.notice(error) != true else { return }
            notifications = []
            cursor = nil
            hasMore = false
            loadError = APIError.wrapping(error).userMessage
        }
    }

    /// Switches slice and reloads.
    ///
    /// A reload rather than a client-side filter: `unread_only` is the server's
    /// own predicate, and filtering the page already in hand would show "the
    /// unread ones out of the twenty I happen to have" while calling it Unread.
    public func setFilter(_ filter: NotificationFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        hasLoaded = false
        notifications = []
        cursor = nil
        hasMore = false
        await reload()
    }

    /// Appends the next page, if there is one and nothing is already in flight.
    public func loadMore() async {
        guard hasMore, let cursor, !isLoadingMore, !isLoading, !isRefreshing else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await service.fetchNotifications(
                cursor: cursor,
                limit: NotificationConstants.defaultPageSize,
                unreadOnly: filter == .unread
            )
            adopt(page, appending: true)
        } catch {
            guard suspension?.notice(error) != true else { return }
            // Stop the pager rather than hammering a failing endpoint on every
            // scroll; pull-to-refresh is the way back.
            hasMore = false
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Called by the list as rows appear. Triggers ``loadMore()`` when
    /// `notification` is within ``NotificationConstants/prefetchThreshold``
    /// rows of the end.
    public func loadMoreIfNeeded(current notification: UserNotification) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else { return }
        guard index >= notifications.count - NotificationConstants.prefetchThreshold else { return }
        await loadMore()
    }

    /// Re-reads the badge without touching the list.
    ///
    /// Used when the shell wants a current count for a tab the user is not
    /// looking at. Failures are swallowed: a badge is not worth an error
    /// banner in front of somebody who asked for nothing.
    public func refreshUnreadCount() async {
        guard let count = try? await service.fetchUnreadCount() else { return }
        unreadCount = count
    }

    // MARK: - Reading

    /// Marks everything read, on purpose.
    ///
    /// Only ever called from the button. The count afterwards is the server's
    /// `unread`, not zero — those are the same number today, and if they ever
    /// stop being, the screen should show what is true rather than what this
    /// client assumed.
    public func markAllRead() async {
        guard canMarkAllRead else { return }
        isMarkingAll = true
        defer { isMarkingAll = false }

        do {
            let result = try await service.markAllRead()
            unreadCount = result.unread
            for index in notifications.indices {
                notifications[index].read = true
            }
            toast = .success(NotificationCopy.markedAll(result.markedRead))
            // In the Unread slice, marking everything read empties the list by
            // definition. Reloading is what makes the screen say "all caught
            // up" instead of showing rows it has just contradicted.
            if filter == .unread {
                await reload(isRefresh: true)
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Opens what a row is about, and marks that one row read.
    ///
    /// - Returns: The destination, or `nil` when there is nothing to open —
    ///   which on this screen means the post has been deleted since, and the
    ///   caller has already been told so by a toast.
    ///
    /// The single row is marked read only **after** its target was successfully
    /// produced. Reading is meant to record that somebody saw the thing; a
    /// fetch that failed means they did not.
    public func open(_ notification: UserNotification) async -> NotificationDestination? {
        analytics.track(.notificationOpened, properties: [
            "kind": notification.kind.rawValue,
            "read": String(notification.read),
            "deleted_post": String(notification.postWasDeleted)
        ])

        guard let postId = notification.postId else {
            await markRead(notification)
            return .profile(handle: notification.actor.handle)
        }

        guard openingId == nil else { return nil }
        openingId = notification.id
        defer { openingId = nil }

        do {
            let post = try await feed.fetchPost(postId)
            await markRead(notification)
            return .post(post)
        } catch {
            guard suspension?.notice(error) != true else { return nil }
            let wrapped = APIError.wrapping(error)
            // The excerpt already told the user this post was gone; the toast
            // is what confirms the tap did something rather than nothing.
            toast = wrapped.code == .postNotFound
                ? .info(L10n.t("notifications.open.postGone"))
                : .error(wrapped.userMessage)
            return nil
        }
    }

    // MARK: - Helpers

    /// Adopts a page. The unread count always comes from the response.
    private func adopt(_ page: NotificationPage, appending: Bool) {
        if appending {
            // De-duplicate: something read on another device can shift the
            // window and repeat a row across two pages, which would break the
            // ForEach's id uniqueness.
            let known = Set(notifications.map(\.id))
            notifications.append(contentsOf: page.notifications.filter { !known.contains($0.id) })
        } else {
            notifications = page.notifications
        }
        cursor = page.nextCursor
        hasMore = page.hasMore
        unreadCount = page.unreadCount
    }

    /// Marks one row read, server first.
    ///
    /// A failure is deliberately silent and leaves the row unread: a read
    /// receipt that did not reach the server is not worth a banner, and showing
    /// the row as read anyway would be the client claiming something it knows
    /// did not happen.
    private func markRead(_ notification: UserNotification) async {
        guard !notification.read else { return }
        guard let result = try? await service.markRead(ids: [notification.id]) else { return }
        unreadCount = result.unread
        for index in notifications.indices where notifications[index].id == notification.id {
            notifications[index].read = true
        }
    }
}
