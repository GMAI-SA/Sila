import Foundation
import Observation

/// Drives ``PostDetailScreen``.
///
/// Starts from the post the feed already has — so the screen paints instantly —
/// then re-reads it, its parent (when it is itself a reply) and its replies.
@MainActor
@Observable
public final class PostDetailViewModel {

    /// The focused post.
    public private(set) var post: Post
    /// The post this one replies to, when it is a reply and the fetch succeeded.
    public private(set) var parent: Post?
    /// Direct replies, chronologically.
    public private(set) var replies: [Post] = []
    /// `true` while the thread is loading for the first time.
    public private(set) var isLoading = false
    /// `true` while another page of replies is being appended.
    public private(set) var isLoadingMoreReplies = false
    /// `true` once the thread has loaded at least once.
    public private(set) var hasLoaded = false
    /// Banner message.
    public var toast: SLToastMessage?

    private var replyCursor: String?
    private var hasMoreReplies = true

    private let service: FeedServiceProtocol
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - post: The post the user tapped.
    ///   - service: Feed backend.
    ///   - analytics: Event sink.
    public init(post: Post, service: FeedServiceProtocol, analytics: AnalyticsClient) {
        self.post = post
        self.service = service
        self.analytics = analytics
    }

    /// Whether the viewer may reply, and why not when they may not.
    public var replyPermission: ReplyPermission { .make(for: post) }

    // MARK: - Loading

    /// Loads the post, its parent and the first page of replies.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        analytics.track(.postOpened, properties: ["scope": post.scope.rawValue])

        // A stale detail view is worse than a slightly slow one, so the post is
        // re-read even though the feed handed us a copy.
        if let fresh = try? await service.fetchPost(post.id) {
            post = fresh
        }

        if let parentId = post.replyToPostId {
            parent = try? await service.fetchPost(parentId)
        } else {
            parent = nil
        }

        do {
            let page = try await service.fetchReplies(for: post.id, cursor: nil)
            replies = page.posts
            replyCursor = page.nextCursor
            hasMoreReplies = page.hasMore && page.nextCursor != nil
        } catch {
            replies = []
            hasMoreReplies = false
            toast = .error(userMessage(for: error))
        }
    }

    /// Appends the next page of replies.
    public func loadMoreReplies() async {
        guard hasMoreReplies, let cursor = replyCursor, !isLoadingMoreReplies else { return }
        isLoadingMoreReplies = true
        defer { isLoadingMoreReplies = false }

        do {
            let page = try await service.fetchReplies(for: post.id, cursor: cursor)
            let known = Set(replies.map(\.id))
            replies.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            replyCursor = page.nextCursor
            hasMoreReplies = page.hasMore && page.nextCursor != nil
        } catch {
            hasMoreReplies = false
            toast = .error(userMessage(for: error))
        }
    }

    /// Triggers pagination near the end of the reply list.
    public func loadMoreRepliesIfNeeded(currentReply reply: Post) async {
        guard let index = replies.firstIndex(where: { $0.id == reply.id }) else { return }
        guard index >= replies.count - FeedConstants.prefetchThreshold else { return }
        await loadMoreReplies()
    }

    // MARK: - Engagement (optimistic)

    /// Toggles the like on any post on this screen, rolling back on failure.
    public func toggleLike(_ target: Post) async {
        await toggle(target, action: .like) { [service] desired, id in
            try await service.setLiked(desired, postId: id)
        }
    }

    /// Toggles the repost.
    public func toggleRepost(_ target: Post) async {
        await toggle(target, action: .repost) { [service] desired, id in
            try await service.setReposted(desired, postId: id)
        }
    }

    /// Toggles the bookmark.
    public func toggleBookmark(_ target: Post) async {
        await toggle(target, action: .bookmark) { [service] desired, id in
            try await service.setBookmarked(desired, postId: id)
        }
    }

    /// Appends replies the viewer just wrote, and bumps the reply counter.
    ///
    /// Called by ``ReplyComposerBar`` on success. The posts are the server's
    /// own, so the thread shows exactly what was stored; only the counter is
    /// predicted, and it is predicted by the same rule the server uses (one per
    /// direct reply).
    /// - Parameter newReplies: Everything the composer got through, in order.
    public func insert(replies newReplies: [Post]) {
        // A thread posted from the reply bar chains onto itself, so only the
        // segments that answer *this* post are direct replies to it.
        let direct = newReplies.filter { $0.replyToPostId == post.id }
        let known = Set(replies.map(\.id))
        let additions = direct.filter { !known.contains($0.id) }
        guard !additions.isEmpty else { return }

        replies.append(contentsOf: additions)
        post.metrics = PostMetrics(
            likes: post.metrics.likes,
            reposts: post.metrics.reposts,
            replies: post.metrics.replies + additions.count,
            views: post.metrics.views,
            bookmarks: post.metrics.bookmarks
        )
    }

    /// Removes a blocked account's replies from the thread, now.
    ///
    /// Only the replies. When the **focused** post's author is the one blocked
    /// there is nothing sensible left on this screen, so the host pops the whole
    /// destination instead — see ``isSubject(_:)``. Blanking the top of a thread
    /// in place would leave somebody staring at a reply list with no post above
    /// it.
    /// - Parameter handle: The blocked account's handle, any casing.
    /// - Returns: How many replies were taken out.
    @discardableResult
    public func removeAuthor(_ handle: String) -> Int {
        let target = Handle.normalised(handle)
        guard !target.isEmpty else { return 0 }
        let before = replies.count
        replies.removeAll { Handle.normalised($0.author.handle) == target }
        if let parent, Handle.normalised(parent.author.handle) == target {
            self.parent = nil
        }
        return before - replies.count
    }

    /// `true` when this screen is *about* the blocked account, and so has
    /// nothing left to show.
    public func isSubject(_ handle: String) -> Bool {
        Handle.normalised(post.author.handle) == Handle.normalised(handle)
    }

    /// Explains a reply the viewer is not allowed to write.
    public func replyBlocked(_ target: Post) {
        guard let message = ReplyPermission.make(for: target).blockedMessage else { return }
        analytics.track(.replyBlocked, properties: [
            "reason": target.viewer.replyBlockReason?.rawValue ?? "unspecified",
            "scope": target.scope.rawValue
        ])
        toast = .warning(message)
    }

    private func toggle(
        _ target: Post,
        action: PostEngagement.Action,
        perform: @escaping (Bool, UUID) async throws -> PostMetrics
    ) async {
        guard let snapshot = currentCopy(of: target.id) else { return }
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
            apply(id: snapshot.id) { current in
                var updated = current
                updated.metrics = snapshot.metrics
                updated.viewer = snapshot.viewer
                return updated
            }
            toast = .error(userMessage(for: error))
        }
    }

    private func currentCopy(of id: UUID) -> Post? {
        if post.id == id { return post }
        if let parent, parent.id == id { return parent }
        return replies.first { $0.id == id }
    }

    private func apply(id: UUID, _ transform: (Post) -> Post) {
        if post.id == id { post = transform(post) }
        if let parent, parent.id == id { self.parent = transform(parent) }
        for index in replies.indices where replies[index].id == id {
            replies[index] = transform(replies[index])
        }
    }

    private func userMessage(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? L10n.t("feed.error.pullToRefresh")
    }
}
