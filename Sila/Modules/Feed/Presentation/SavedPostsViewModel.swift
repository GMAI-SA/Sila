import Foundation
import Observation

/// The viewer's saved posts, most recently saved first.
///
/// A bookmark is the one engagement that is private to the viewer, so this is
/// the only list that shows it back to them. Un-saving from here removes the
/// row once the server has agreed; the other two engagements behave exactly as
/// they do in the feed.
@MainActor
@Observable
public final class SavedPostsViewModel {

    /// Where the first page stands.
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var posts: [Post] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = false
    /// Transient failures — an engagement that did not stick.
    public var toast: SLToastMessage?

    private var cursor: String?
    private let service: FeedServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?

    /// - Parameters:
    ///   - service: Where the list and the engagements go.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    public init(
        service: FeedServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
    }

    /// True once the first page is in and empty.
    public var isEmpty: Bool { loadState == .loaded && posts.isEmpty }

    /// Loads the first page, once. Safe to call from `.task`.
    public func load() async {
        guard loadState == .idle else { return }
        analytics.track(.savedPostsOpened)
        await loadFirstPage()
    }

    /// Pull-to-refresh: fetches the first page again.
    public func reload() async {
        await loadFirstPage()
    }

    /// Called by the list as rows appear; fetches the next page near the end.
    public func loadMoreIfNeeded(currentPost post: Post) async {
        guard hasMore, !isLoadingMore, let cursor else { return }
        guard let index = posts.firstIndex(where: { $0.id == post.id }),
              index >= posts.count - FeedConstants.prefetchThreshold
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchBookmarks(cursor: cursor)
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            self.cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
        } catch {
            guard suspension?.notice(error) != true else { return }
            hasMore = false
            toast = .error(userMessage(for: error))
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

    /// Toggles the bookmark. Un-saving takes the row out of this list once
    /// the server has confirmed it; saving again (a second tap before that)
    /// keeps it.
    public func toggleBookmark(_ post: Post) async {
        await toggle(post, action: .bookmark) { [service] desired, id in
            try await service.setBookmarked(desired, postId: id)
        }
        if let current = posts.first(where: { $0.id == post.id }), !current.viewer.bookmarked {
            posts.removeAll { $0.id == post.id }
        }
    }

    /// Records that a blocked reply button was pressed and explains why.
    public func replyBlocked(_ post: Post) {
        guard let message = ReplyPermission.make(for: post).blockedMessage else { return }
        toast = .warning(message)
    }

    /// Merges a post changed elsewhere (the detail screen) back into the list.
    public func merge(_ post: Post) {
        apply(id: post.id) { current in
            var updated = current
            updated.metrics = post.metrics
            updated.viewer = post.viewer
            return updated
        }
    }

    /// Drops a post the viewer deleted.
    public func remove(postId: UUID) {
        posts.removeAll { $0.id == postId }
    }

    // MARK: - Helpers

    private func loadFirstPage() async {
        if loadState != .loaded { loadState = .loading }
        do {
            let page = try await service.fetchBookmarks(cursor: nil)
            posts = page.posts
            cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            loadState = .loaded
        } catch {
            guard suspension?.notice(error) != true else { return }
            if posts.isEmpty {
                loadState = .failed(userMessage(for: error))
            } else {
                loadState = .loaded
                toast = .error(userMessage(for: error))
            }
        }
    }

    private func toggle(
        _ post: Post,
        action: PostEngagement.Action,
        perform: @escaping (Bool, UUID) async throws -> PostMetrics
    ) async {
        guard let snapshot = posts.first(where: { $0.id == post.id }) else { return }
        let desired = !PostEngagement.isOn(action, in: snapshot)

        apply(id: snapshot.id) { PostEngagement.applying(action, on: desired, to: $0) }

        do {
            let metrics = try await perform(desired, snapshot.id)
            apply(id: snapshot.id) { current in
                var updated = current
                updated.metrics = metrics
                return updated
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            apply(id: snapshot.id) { current in
                var updated = current
                updated.metrics = snapshot.metrics
                updated.viewer = snapshot.viewer
                return updated
            }
            toast = .error(userMessage(for: error))
        }
    }

    private func apply(id: UUID, _ transform: (Post) -> Post) {
        for index in posts.indices where posts[index].id == id {
            posts[index] = transform(posts[index])
        }
    }

    private func userMessage(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? L10n.t("feed.error.pullToRefresh")
    }
}
