import Foundation

/// What the author of a post may do to it.
///
/// Separate from ``SafetyMenuActions`` because they are mutually exclusive by
/// construction: the safety menu is absent on your own post — you cannot block,
/// mute or report yourself — and deletion is absent on everybody else's. One
/// type carrying both would need every call site to reason about which half is
/// live.
public struct OwnPostActions {

    /// Opens the confirmation. **Never deletes on its own.**
    public let onDelete: @MainActor () -> Void

    public init(onDelete: @escaping @MainActor () -> Void) {
        self.onDelete = onDelete
    }
}

/// Deleting your own posts.
///
/// Held once and shared by every surface that renders a card, the same way
/// ``SafetyViewModel`` is, so a post deleted from the feed also disappears from
/// a profile timeline and from search without each screen re-fetching. The
/// alternative — per-screen deletion state — means a post you just deleted is
/// still sitting on the previous screen when you navigate back.
@MainActor
@Observable
public final class PostDeletionViewModel {

    private let service: FeedServiceProtocol
    private let analytics: AnalyticsClient
    /// The signed-in account's handle. Without it nothing is offered, which is
    /// the safe direction: showing Delete on somebody else's post would produce
    /// a 403 and look like a bug.
    private let viewerHandle: String?

    /// The post awaiting confirmation, or `nil`.
    public private(set) var pending: Post?
    /// True while the delete request is in flight.
    public private(set) var isDeleting = false
    /// Why the last attempt failed, for an alert.
    public private(set) var error: String?
    /// Everything deleted this session, so every list can drop it at once.
    public private(set) var deleted: Set<UUID> = []

    public init(
        service: FeedServiceProtocol,
        analytics: AnalyticsClient,
        viewerHandle: String? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.viewerHandle = viewerHandle.map(Handle.normalised)
    }

    /// The author's own menu for a post, or `nil` when it is not theirs.
    public func actions(for post: Post) -> OwnPostActions? {
        guard isMine(post) else { return nil }
        return OwnPostActions { [weak self] in self?.request(post) }
    }

    /// Whether this post belongs to the signed-in account.
    public func isMine(_ post: Post) -> Bool {
        guard let viewerHandle, !viewerHandle.isEmpty else { return false }
        return Handle.normalised(post.author.handle) == viewerHandle
    }

    /// Whether a card should be rendered at all.
    public func isDeleted(_ post: Post) -> Bool { deleted.contains(post.id) }

    /// Opens the confirmation. Deliberately does not delete.
    ///
    /// Deletion is irreversible — the server has no undo, and the post leaves
    /// every feed, thread and search result. A single tap is the wrong amount
    /// of intent for that.
    public func request(_ post: Post) {
        pending = post
        error = nil
    }

    public func cancel() {
        pending = nil
    }

    /// Performs the deletion the confirmation asked about.
    @discardableResult
    public func confirm() async -> Bool {
        guard let post = pending else { return false }
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await service.deletePost(post.id)
            // Recorded before clearing `pending`, so the list updates in the
            // same frame the sheet dismisses rather than a beat later.
            deleted.insert(post.id)
            pending = nil
            analytics.track(.postDeleted)
            return true
        } catch {
            let wrapped = APIError.wrapping(error)
            self.error = wrapped.userMessage
            pending = nil
            return false
        }
    }

    /// Dismisses the failure alert.
    public func clearError() { error = nil }
}
