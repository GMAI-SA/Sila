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
    /// The signed-in account's handle, as a fallback for a server too old to
    /// say whose post it is. It is a `var` because the shell is built before
    /// the account has finished loading: captured once, it was empty for the
    /// whole session, and an empty handle matches nobody — which is how Delete
    /// came to be missing from a person's own posts.
    private var viewerHandle: String?

    /// The post awaiting confirmation, or `nil`. Drives the dialog.
    public private(set) var pending: Post?
    /// The post ``confirm()`` will delete.
    ///
    /// Separate from ``pending`` on purpose. Tapping Delete in the dialog
    /// makes SwiftUI dismiss it, which sets the presentation binding to false,
    /// which called ``cancel()`` — and only *then* did the button's async
    /// action run ``confirm()``, by which time ``pending`` was already `nil`
    /// and nothing was deleted. What is armed stays armed until it is either
    /// deleted or explicitly kept.
    private var armed: Post?
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

    /// Tells the model who is reading, once the account is known.
    ///
    /// Called when the session's user arrives or changes, so a shell built
    /// before sign-in finished still offers the author their own menu.
    public func setViewer(handle: String?) {
        viewerHandle = handle.map(Handle.normalised)
    }

    /// Whether this post belongs to the signed-in account.
    ///
    /// The server's word first: it knows, and it is right even when the post
    /// arrived on a screen built before the account did. The handle match is
    /// kept underneath it for a server that does not say.
    public func isMine(_ post: Post) -> Bool {
        if post.viewer.isAuthor { return true }
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
        armed = post
        error = nil
    }

    /// Takes the dialog down. Called by the presentation binding whenever
    /// the dialog closes — including on the way to a confirmed delete — so
    /// it must not disarm.
    public func cancel() {
        pending = nil
    }

    /// The person chose to keep the post. Nothing is armed any more.
    public func keep() {
        pending = nil
        armed = nil
    }

    /// Performs the deletion the confirmation asked about.
    @discardableResult
    public func confirm() async -> Bool {
        guard let post = armed else { return false }
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await service.deletePost(post.id)
            // Recorded before clearing the rest, so the list updates in the
            // same frame the sheet dismisses rather than a beat later.
            deleted.insert(post.id)
            pending = nil
            armed = nil
            analytics.track(.postDeleted)
            return true
        } catch {
            let wrapped = APIError.wrapping(error)
            self.error = wrapped.userMessage
            pending = nil
            armed = nil
            return false
        }
    }

    /// Dismisses the failure alert.
    public func clearError() { error = nil }
}
