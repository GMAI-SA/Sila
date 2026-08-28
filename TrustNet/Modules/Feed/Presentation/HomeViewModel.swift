import Foundation
import Observation

/// Why a feed is showing nothing.
///
/// Distinguished because "no posts yet" and "you have no verified country" want
/// completely different copy — and the second is an explainer, not an error.
public enum FeedEmptyKind: Equatable, Sendable {
    /// The server returned zero posts.
    case noPosts
    /// `GET /feed/country` answered 409 `no_country`.
    case noCountry
    /// The request failed; the message is already user-safe.
    case failed(String)
}

/// One feed tab's independent state.
///
/// Each tab owns its own posts, cursor and load flags, which is what lets the
/// user swipe between tabs without triggering a refetch of a feed they have
/// already read.
public struct FeedTabState: Equatable, Sendable {

    /// Posts loaded so far, in server order.
    public var posts: [Post] = []
    /// The cursor to pass for the next page, or `nil` at the end.
    public var cursor: String?
    /// Whether the server says another page exists.
    public var hasMore: Bool = true
    /// `true` during the first load of this tab.
    public var isLoading: Bool = false
    /// `true` while appending a page.
    public var isLoadingMore: Bool = false
    /// `true` during pull-to-refresh.
    public var isRefreshing: Bool = false
    /// `true` once a load has completed, successfully or not.
    public var hasLoaded: Bool = false
    /// Set when there is nothing to render.
    public var emptyKind: FeedEmptyKind?

    public init() {}

    /// `true` when the tab has content on screen.
    public var isPopulated: Bool { !posts.isEmpty }
}

/// Drives ``HomeScreen``.
///
/// Owns four independent ``FeedTabState`` values, cursor pagination, and the
/// optimistic engagement updates. Engagement changes are applied to *every*
/// tab holding the post, so liking something in For You is already liked when
/// the user swipes to International.
@MainActor
@Observable
public final class HomeViewModel {

    /// The visible tab.
    public private(set) var selectedTab: FeedTab = .forYou
    /// Per-tab state, keyed by tab.
    public private(set) var states: [FeedTab: FeedTabState] = [:]
    /// Banner message.
    public var toast: TNToastMessage?

    private let service: FeedServiceProtocol
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - service: Feed backend.
    ///   - analytics: Event sink.
    ///   - initialTab: Tab to open on. Defaults to ``FeedTab/forYou``.
    public init(
        service: FeedServiceProtocol,
        analytics: AnalyticsClient,
        initialTab: FeedTab = .forYou
    ) {
        self.service = service
        self.analytics = analytics
        self.selectedTab = initialTab
        for tab in FeedTab.allCases {
            states[tab] = FeedTabState()
        }
    }

    /// The state of one tab. Never `nil` — an unknown tab reads as empty.
    public func state(for tab: FeedTab) -> FeedTabState {
        states[tab] ?? FeedTabState()
    }

    /// The visible tab's state.
    public var currentState: FeedTabState { state(for: selectedTab) }

    // MARK: - Tab selection

    /// Switches tab and loads it **only if it has never been loaded**.
    /// - Parameter tab: The tab the user picked.
    public func select(_ tab: FeedTab) async {
        guard tab != selectedTab else { return }
        selectedTab = tab
        analytics.track(.feedTabSelected, properties: ["tab": tab.rawValue])
        await loadIfNeeded(tab)
    }

    /// Loads a tab's first page unless it already has one.
    public func loadIfNeeded(_ tab: FeedTab) async {
        guard !state(for: tab).hasLoaded else { return }
        await loadFirstPage(tab, isRefresh: false)
    }

    // MARK: - Loading

    /// Pull-to-refresh: discards the cursor and re-reads page one.
    public func refresh(_ tab: FeedTab) async {
        await loadFirstPage(tab, isRefresh: true)
    }

    /// Appends the next page, if there is one and nothing is already in flight.
    public func loadMore(_ tab: FeedTab) async {
        var current = state(for: tab)
        guard current.hasMore,
              let cursor = current.cursor,
              !current.isLoadingMore,
              !current.isLoading,
              !current.isRefreshing
        else { return }

        current.isLoadingMore = true
        states[tab] = current

        do {
            let page = try await service.fetchFeed(tab, cursor: cursor, limit: FeedConstants.defaultPageSize)
            var updated = state(for: tab)
            updated.isLoadingMore = false
            // De-duplicate: a post inserted between two requests can otherwise
            // arrive on both pages and break the ForEach's id uniqueness.
            let known = Set(updated.posts.map(\.id))
            updated.posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            updated.cursor = page.nextCursor
            updated.hasMore = page.hasMore && page.nextCursor != nil
            states[tab] = updated
        } catch {
            var updated = state(for: tab)
            updated.isLoadingMore = false
            // Stop the pager rather than hammering a failing endpoint on every
            // scroll; pull-to-refresh is the way back.
            updated.hasMore = false
            states[tab] = updated
            toast = .error(userMessage(for: error))
        }
    }

    /// Called by the list as rows appear. Triggers ``loadMore(_:)`` when `post`
    /// is within ``FeedConstants/prefetchThreshold`` rows of the end of `tab`.
    /// - Parameters:
    ///   - post: The row that just appeared.
    ///   - tab: The tab it belongs to.
    public func loadMoreIfNeeded(currentPost post: Post, tab: FeedTab) async {
        let current = state(for: tab)
        guard let index = current.posts.firstIndex(where: { $0.id == post.id }) else { return }
        guard index >= current.posts.count - FeedConstants.prefetchThreshold else { return }
        await loadMore(tab)
    }

    private func loadFirstPage(_ tab: FeedTab, isRefresh: Bool) async {
        var current = state(for: tab)
        guard !current.isLoading, !current.isRefreshing else { return }
        if isRefresh {
            current.isRefreshing = true
        } else {
            current.isLoading = true
        }
        current.emptyKind = nil
        states[tab] = current

        do {
            let page = try await service.fetchFeed(tab, cursor: nil, limit: FeedConstants.defaultPageSize)
            var updated = state(for: tab)
            updated.posts = page.posts
            updated.cursor = page.nextCursor
            updated.hasMore = page.hasMore && page.nextCursor != nil
            updated.emptyKind = page.posts.isEmpty ? .noPosts : nil
            updated.isLoading = false
            updated.isRefreshing = false
            updated.hasLoaded = true
            states[tab] = updated
        } catch {
            var updated = state(for: tab)
            updated.isLoading = false
            updated.isRefreshing = false
            updated.hasLoaded = true
            updated.hasMore = false

            if isNoCountry(error) {
                // Not an error the user did anything wrong to cause — it is the
                // product explaining that the flag comes from verification.
                updated.posts = []
                updated.emptyKind = .noCountry
            } else if updated.posts.isEmpty {
                updated.emptyKind = .failed(userMessage(for: error))
            } else {
                // Keep what is already on screen and say so in a banner.
                toast = .error(userMessage(for: error))
            }
            states[tab] = updated
        }
    }

    // MARK: - Engagement (optimistic)

    /// Toggles the like, predicting the counter and rolling back on failure.
    public func toggleLike(_ post: Post) async {
        await toggle(post, action: .like) { [service] desired, id in
            try await service.setLiked(desired, postId: id)
        }
    }

    /// Toggles the repost.
    public func toggleRepost(_ post: Post) async {
        await toggle(post, action: .repost) { [service] desired, id in
            try await service.setReposted(desired, postId: id)
        }
    }

    /// Toggles the bookmark.
    public func toggleBookmark(_ post: Post) async {
        await toggle(post, action: .bookmark) { [service] desired, id in
            try await service.setBookmarked(desired, postId: id)
        }
    }

    /// Records that a blocked reply button was pressed and explains why.
    public func replyBlocked(_ post: Post) {
        let permission = ReplyPermission.make(for: post)
        guard let message = permission.blockedMessage else { return }
        analytics.track(.replyBlocked, properties: [
            "reason": post.viewer.replyBlockReason?.rawValue ?? "unspecified",
            "scope": post.scope.rawValue
        ])
        toast = .warning(message)
    }

    private func toggle(
        _ post: Post,
        action: PostEngagement.Action,
        perform: @escaping (Bool, UUID) async throws -> PostMetrics
    ) async {
        // The list's copy is the source of truth; the caller may be holding a
        // stale value captured when the row was built.
        let snapshot = findPost(post.id) ?? post
        let desired = !PostEngagement.isOn(action, in: snapshot)

        applyEverywhere(id: snapshot.id) { PostEngagement.applying(action, on: desired, to: $0) }

        do {
            let metrics = try await perform(desired, snapshot.id)
            applyEverywhere(id: snapshot.id) { current in
                var updated = current
                updated.metrics = metrics
                return updated
            }
        } catch {
            // Roll back to exactly what was on screen before the tap — not an
            // inverse toggle, which would drift if the server had also moved.
            applyEverywhere(id: snapshot.id) { current in
                var updated = current
                updated.metrics = snapshot.metrics
                updated.viewer = snapshot.viewer
                return updated
            }
            toast = .error(userMessage(for: error))
        }
    }

    /// The first copy of a post across all tabs.
    public func findPost(_ id: UUID) -> Post? {
        for tab in FeedTab.allCases {
            if let post = states[tab]?.posts.first(where: { $0.id == id }) { return post }
        }
        return nil
    }

    /// Applies `transform` to every copy of a post in every tab.
    ///
    /// Also reaches into quoted posts, so liking the original updates the quote
    /// card rendered inside someone else's post.
    public func applyEverywhere(id: UUID, _ transform: (Post) -> Post) {
        for tab in FeedTab.allCases {
            guard var tabState = states[tab] else { continue }
            var changed = false
            for index in tabState.posts.indices where tabState.posts[index].id == id {
                tabState.posts[index] = transform(tabState.posts[index])
                changed = true
            }
            if changed { states[tab] = tabState }
        }
    }

    /// Puts posts the viewer just wrote at the top of the feeds they belong in.
    ///
    /// Called after the Phase-4 composer succeeds. These are the server's own
    /// ``Post`` values, not a local guess at what it stored, so nothing here is
    /// fabricated — the alternative is a user staring at an unchanged list
    /// wondering whether their post went anywhere.
    ///
    /// Replies are skipped: they belong under their parent on the detail
    /// screen, not at the top of For You.
    /// - Parameter newPosts: Everything that reached the server, in order.
    public func insert(newPosts: [Post]) {
        let roots = newPosts.filter { !$0.isReply }
        guard !roots.isEmpty else { return }

        for tab in FeedTab.allCases {
            let relevant = roots.filter { belongs($0, in: tab) }
            guard !relevant.isEmpty, var tabState = states[tab] else { continue }
            // A tab that has never loaded has nothing stale to correct, and
            // marking it loaded here would suppress its first fetch entirely.
            guard tabState.hasLoaded else { continue }

            let known = Set(tabState.posts.map(\.id))
            let additions = relevant.filter { !known.contains($0.id) }
            guard !additions.isEmpty else { continue }

            tabState.posts.insert(contentsOf: additions, at: 0)
            // The tab now has content, whatever it was showing before.
            tabState.emptyKind = nil
            states[tab] = tabState
        }
    }

    /// Which feeds a freshly written post shows up in.
    ///
    /// Conservative on purpose: a post is only placed where the server's own
    /// rules would certainly put it. `Following` is left alone because you do
    /// not follow yourself, and `My Country` only takes country-scoped posts —
    /// the country feed is "posts by verified compatriots", which the viewer's
    /// own post qualifies for exactly when it carries that scope.
    private func belongs(_ post: Post, in tab: FeedTab) -> Bool {
        switch tab {
        case .forYou: return true
        case .following: return false
        case .myCountry: return post.scope == .country
        case .international: return post.scope == .international
        }
    }

    /// Merges a post edited elsewhere (e.g. the detail screen) back into the feeds.
    public func merge(_ post: Post) {
        applyEverywhere(id: post.id) { current in
            var updated = current
            updated.metrics = post.metrics
            updated.viewer = post.viewer
            return updated
        }
    }

    // MARK: - Helpers

    private func isNoCountry(_ error: Error) -> Bool {
        (error as? APIError)?.code == .noCountry
    }

    private func userMessage(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? "Something went wrong. Pull to refresh."
    }
}

/// Pure functions for the three toggleable engagements.
///
/// Extracted from the view models so the optimistic prediction and the rollback
/// are the same code in the feed and on the detail screen — and so both are
/// testable without a view.
public enum PostEngagement {

    /// The engagements a viewer can toggle.
    public enum Action: String, Sendable, CaseIterable {
        case like, repost, bookmark
    }

    /// Whether `action` is currently on for `post`.
    public static func isOn(_ action: Action, in post: Post) -> Bool {
        switch action {
        case .like: return post.viewer.liked
        case .repost: return post.viewer.reposted
        case .bookmark: return post.viewer.bookmarked
        }
    }

    /// A copy of `post` with `action` set to `on` and the matching counter
    /// moved by exactly one — the client's prediction of the server's answer.
    public static func applying(_ action: Action, on: Bool, to post: Post) -> Post {
        guard isOn(action, in: post) != on else { return post }
        let delta = on ? 1 : -1
        var updated = post
        switch action {
        case .like:
            updated.viewer = post.viewer.setting(liked: on)
            updated.metrics = post.metrics.adjusting(likes: delta)
        case .repost:
            updated.viewer = post.viewer.setting(reposted: on)
            updated.metrics = post.metrics.adjusting(reposts: delta)
        case .bookmark:
            updated.viewer = post.viewer.setting(bookmarked: on)
            updated.metrics = post.metrics.adjusting(bookmarks: delta)
        }
        return updated
    }
}
