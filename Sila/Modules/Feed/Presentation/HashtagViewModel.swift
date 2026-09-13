import Foundation
import Observation

/// A hashtag's page: every visible post that carries it, in the order the
/// viewer keeps.
///
/// The order is the account's, not the screen's: picking "Top" here is
/// remembered on the server (``PreferencesUpdate/hashtagSort``), so the next
/// tag opens the same way on every device. The first page is asked for with
/// no sort at all, and the server answers with the remembered one.
@MainActor
@Observable
public final class HashtagViewModel {

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The tag without its `#`, as the server keys it.
    public let tag: String
    public private(set) var posts: [Post] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = false
    /// How many visible posts carry the tag, from the server.
    public private(set) var postCount = 0
    /// The order the list is in. Newest until the server says otherwise.
    public private(set) var sort: HashtagSort = .newest
    public var toast: SLToastMessage?

    private var cursor: String?
    /// Set once the viewer has chosen; `nil` lets the server pick.
    private var chosenSort: HashtagSort?
    /// Bumped by every first-page load. A load whose number is stale was
    /// superseded — by a second tap on the order chips, say — and must not
    /// write its answer over the newer one's.
    private var generation = 0
    private let service: FeedServiceProtocol
    private let preferences: PreferencesServiceProtocol?
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?

    /// - Parameters:
    ///   - tag: With or without a leading `#`.
    ///   - service: Where the pages and the engagements go.
    ///   - preferences: Where the chosen order is remembered. `nil` keeps the
    ///     choice for this screen only.
    public init(
        tag: String,
        service: FeedServiceProtocol,
        preferences: PreferencesServiceProtocol? = nil,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil
    ) {
        self.tag = HashtagViewModel.normalised(tag)
        self.service = service
        self.preferences = preferences
        self.analytics = analytics
        self.suspension = suspension
    }

    /// The tag as it is written: `#riyadh`.
    public var hashtag: String { "#\(tag)" }

    public var isEmpty: Bool { loadState == .loaded && posts.isEmpty }

    /// The stored form: no `#`, no surrounding space, case-folded.
    nonisolated public static func normalised(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" })
            .lowercased()
    }

    /// Loads the first page, once.
    public func load() async {
        guard loadState == .idle else { return }
        analytics.track(.hashtagOpened, properties: ["tag": tag])
        await loadFirstPage()
    }

    /// Pull-to-refresh.
    public func reload() async {
        await loadFirstPage()
    }

    /// Changes the order — for this account everywhere, not just this page.
    ///
    /// The list reloads in the new order at once; remembering it is a
    /// separate request whose failure costs nothing visible, so it is not
    /// awaited before the reload.
    public func select(_ sort: HashtagSort) async {
        guard sort != self.sort || chosenSort == nil else { return }
        analytics.track(.hashtagSortChanged, properties: ["sort": sort.rawValue])
        chosenSort = sort
        self.sort = sort
        if let preferences {
            Task {
                _ = try? await preferences.updatePreferences(PreferencesUpdate(hashtagSort: sort))
            }
        }
        await loadFirstPage()
    }

    public func loadMoreIfNeeded(currentPost post: Post) async {
        guard hasMore, !isLoadingMore, let cursor else { return }
        guard let index = posts.firstIndex(where: { $0.id == post.id }),
              index >= posts.count - FeedConstants.prefetchThreshold
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchHashtagPosts(tag, sort: sort, cursor: cursor)
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            self.cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
        } catch {
            guard suspension?.notice(error) != true else { return }
            // A cancelled page — the card that asked for it scrolled away —
            // is not the end of the list; the next card asks again.
            guard !APIError.wrapping(error).isCancellation else { return }
            hasMore = false
            toast = .error(for: error)
        }
    }

    // MARK: - Engagement (optimistic)

    public func toggleLike(_ post: Post) async {
        await toggle(post, action: .like) { [service] desired, id in try await service.setLiked(desired, postId: id) }
    }

    public func toggleRepost(_ post: Post) async {
        await toggle(post, action: .repost) { [service] desired, id in try await service.setReposted(desired, postId: id) }
    }

    public func toggleBookmark(_ post: Post) async {
        await toggle(post, action: .bookmark) { [service] desired, id in try await service.setBookmarked(desired, postId: id) }
    }

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

    public func remove(postId: UUID) {
        posts.removeAll { $0.id == postId }
    }

    // MARK: - Helpers

    private func loadFirstPage() async {
        generation += 1
        let mine = generation
        if loadState != .loaded { loadState = .loading }
        do {
            let page = try await service.fetchHashtagPosts(tag, sort: chosenSort, cursor: nil)
            guard mine == generation else { return }
            posts = page.posts
            cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            postCount = page.postCount
            sort = page.sort
            loadState = .loaded
        } catch {
            guard mine == generation else { return }
            guard suspension?.notice(error) != true else { return }
            guard let message = APIError.wrapping(error).presentableMessage else {
                // Abandoned mid-flight (the screen went away): back to where
                // it was, so the next appearance loads rather than finding a
                // spinner it must not touch.
                loadState = posts.isEmpty ? .idle : .loaded
                return
            }
            if posts.isEmpty {
                loadState = .failed(message)
            } else {
                loadState = .loaded
                toast = .error(message)
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
            toast = .error(for: error)
        }
    }

    private func apply(id: UUID, _ transform: (Post) -> Post) {
        for index in posts.indices where posts[index].id == id {
            posts[index] = transform(posts[index])
        }
    }
}
