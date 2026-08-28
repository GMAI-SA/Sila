import Foundation
import Observation

/// Why the results area is showing nothing.
///
/// "Type two characters", "nothing matched" and "the request failed" are three
/// different situations and get three different sentences — a single generic
/// empty state would leave the user unsure whether search is broken.
public enum SearchEmptyKind: Equatable, Sendable {
    /// Nothing typed yet — trending is on screen instead.
    case idle
    /// One character typed; the server needs two.
    case queryTooShort
    /// The query ran and matched nothing.
    case noResults
    /// The request failed; the message is already user-safe.
    case failed(String)
}

/// Drives ``ExploreScreen``.
///
/// Owns a debounced query, two result lists (posts and people), the trending
/// tags shown while the field is empty, and the optimistic engagement updates
/// for post results — a like in a search result must behave exactly like a like
/// in the feed.
@MainActor
@Observable
public final class ExploreViewModel {

    /// The two result lists.
    public enum ResultTab: String, CaseIterable, Identifiable, Sendable, Hashable {
        case posts, people

        public var id: String { rawValue }

        /// Segmented-control label.
        public var title: String {
            switch self {
            case .posts: return "Posts"
            case .people: return "People"
            }
        }

        /// Accessibility hint for the segmented control.
        public var accessibilityHint: String {
            switch self {
            case .posts: return "Shows posts whose text matches your search"
            case .people: return "Shows accounts whose handle or name matches your search"
            }
        }
    }

    /// What is in the search field.
    public private(set) var query = ""
    /// Which result list is visible.
    public private(set) var tab: ResultTab = .posts
    /// Post results, in server order.
    public private(set) var posts: [Post] = []
    /// People results, verified first (the server sorts them).
    public private(set) var people: [UserSummary] = []
    /// Hashtags shown while the query is empty.
    public private(set) var trending: [TrendingTag] = []
    /// `true` while a search is in flight.
    public private(set) var isSearching = false
    /// `true` while another page of post results is being appended.
    public private(set) var isLoadingMore = false
    /// `true` while trending is loading.
    public private(set) var isLoadingTrending = false
    /// Why the results area is empty, when it is.
    public private(set) var emptyKind: SearchEmptyKind = .idle
    /// Why trending is empty, when it is.
    public private(set) var trendingError: String?
    /// Banner message.
    public var toast: SLToastMessage?

    private var cursor: String?
    private var hasMore = false
    private var searchTask: Task<Void, Never>?

    private let search: SearchServiceProtocol
    private let feed: FeedServiceProtocol
    private let analytics: AnalyticsClient
    private let debounce: TimeInterval

    /// - Parameters:
    ///   - search: Search backend.
    ///   - feed: Used only for engagement on post results, so a like here is the
    ///     same call a like in the feed makes.
    ///   - analytics: Event sink.
    ///   - debounce: Seconds to wait after a keystroke. Tests pass a tiny value.
    public init(
        search: SearchServiceProtocol,
        feed: FeedServiceProtocol,
        analytics: AnalyticsClient,
        debounce: TimeInterval = SearchConstants.searchDebounce
    ) {
        self.search = search
        self.feed = feed
        self.analytics = analytics
        self.debounce = debounce
    }

    // MARK: - Derived state

    /// `true` when the trending list should be on screen instead of results.
    public var isShowingTrending: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `true` when the visible list has rows.
    public var hasResults: Bool {
        switch tab {
        case .posts: return !posts.isEmpty
        case .people: return !people.isEmpty
        }
    }

    // MARK: - Trending

    /// Loads the trending tags. Safe to call on every appearance.
    public func loadTrending() async {
        guard trending.isEmpty, !isLoadingTrending else { return }
        isLoadingTrending = true
        trendingError = nil
        defer { isLoadingTrending = false }

        do {
            trending = try await search.trendingTags()
        } catch {
            trending = []
            trendingError = APIError.wrapping(error).userMessage
        }
    }

    /// Runs a search for a trending tag.
    /// - Parameter tag: The tag the user tapped.
    public func select(_ tag: TrendingTag) {
        analytics.track(.trendingTagOpened, properties: ["tag": tag.tag])
        // Searching with the `#` matches the hashtag itself rather than every
        // stray mention of the word, which is what the tag was counted from.
        updateQuery(tag.hashtag, immediately: true)
    }

    // MARK: - Query

    /// Handles a keystroke, debouncing the network call.
    /// - Parameters:
    ///   - query: The field's new contents.
    ///   - immediately: Skips the debounce (a submit, or a tapped tag).
    public func updateQuery(_ query: String, immediately: Bool = false) {
        self.query = query
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            posts = []
            people = []
            cursor = nil
            hasMore = false
            isSearching = false
            emptyKind = .idle
            return
        }

        guard SearchConstants.isSearchable(trimmed) else {
            // The server answers a one-character query with an empty list; the
            // client says why rather than showing "no results".
            posts = []
            people = []
            isSearching = false
            emptyKind = .queryTooShort
            return
        }

        isSearching = true
        searchTask = Task { [weak self, debounce] in
            if !immediately, debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    /// Clears the field and returns to trending.
    public func clear() {
        updateQuery("")
    }

    /// Switches result list. Both lists are fetched by one search, so this
    /// never issues a request.
    public func select(_ tab: ResultTab) {
        guard tab != self.tab else { return }
        self.tab = tab
        refreshEmptyKind()
    }

    private func performSearch(_ trimmed: String) async {
        defer { isSearching = false }
        do {
            // Both lists come back from one round so switching tabs is instant
            // and the counts never contradict each other.
            async let postsPage = search.searchPosts(query: trimmed, cursor: nil)
            async let users = search.searchUsers(query: trimmed)

            let page = try await postsPage
            let found = try await users

            guard !Task.isCancelled else { return }

            posts = page.posts
            people = found
            cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            refreshEmptyKind()

            analytics.track(.searchPerformed, properties: [
                "posts": String(page.posts.count),
                "people": String(found.count)
            ])
        } catch {
            guard !Task.isCancelled else { return }
            posts = []
            people = []
            hasMore = false
            emptyKind = .failed(APIError.wrapping(error).userMessage)
        }
    }

    private func refreshEmptyKind() {
        emptyKind = hasResults ? .idle : .noResults
    }

    // MARK: - Pagination

    /// Appends the next page of post results.
    public func loadMore() async {
        guard hasMore, let cursor, !isLoadingMore, !isSearching else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SearchConstants.isSearchable(trimmed) else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await search.searchPosts(query: trimmed, cursor: cursor)
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            self.cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
        } catch {
            // Stop the pager rather than hammering a failing endpoint.
            hasMore = false
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Triggers pagination near the end of the post results.
    public func loadMoreIfNeeded(currentPost post: Post) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        guard index >= posts.count - FeedConstants.prefetchThreshold else { return }
        await loadMore()
    }

    // MARK: - Engagement (optimistic)

    /// Toggles the like on a post result.
    public func toggleLike(_ post: Post) async {
        await toggle(post, action: .like) { [feed] desired, id in
            try await feed.setLiked(desired, postId: id)
        }
    }

    /// Toggles the repost.
    public func toggleRepost(_ post: Post) async {
        await toggle(post, action: .repost) { [feed] desired, id in
            try await feed.setReposted(desired, postId: id)
        }
    }

    /// Toggles the bookmark.
    public func toggleBookmark(_ post: Post) async {
        await toggle(post, action: .bookmark) { [feed] desired, id in
            try await feed.setBookmarked(desired, postId: id)
        }
    }

    /// Explains a reply the viewer is not allowed to write.
    public func replyBlocked(_ post: Post) {
        guard let message = ReplyPermission.make(for: post).blockedMessage else { return }
        toast = .warning(message)
    }

    /// Merges a post changed elsewhere (the detail screen) back into the results.
    public func merge(_ post: Post) {
        apply(id: post.id) { current in
            var updated = current
            updated.metrics = post.metrics
            updated.viewer = post.viewer
            return updated
        }
    }

    /// Inserts posts the user just wrote, so a search they are looking at is
    /// not stale — but only when they actually match the query.
    public func insert(_ newPosts: [Post]) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        let known = Set(posts.map(\.id))
        let matching = newPosts.filter {
            !known.contains($0.id) && $0.text.lowercased().contains(needle)
        }
        guard !matching.isEmpty else { return }
        posts.insert(contentsOf: matching, at: 0)
        refreshEmptyKind()
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
            apply(id: snapshot.id) { current in
                var updated = current
                updated.metrics = snapshot.metrics
                updated.viewer = snapshot.viewer
                return updated
            }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    private func apply(id: UUID, _ transform: (Post) -> Post) {
        for index in posts.indices where posts[index].id == id {
            posts[index] = transform(posts[index])
        }
    }
}
