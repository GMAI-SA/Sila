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
    public var toast: SLToastMessage?

    /// The subjects pinned in the strip above the timeline. Empty means
    /// everything.
    ///
    /// Several are allowed, and they mean *any* of them: somebody who taps
    /// Sports and Finance is asking for two conversations, not for the rare
    /// post about both. It is deliberately one list rather than one per tab —
    /// it is a statement about what somebody wants to read, not about which
    /// tab they happen to be standing on, so it applies to all four.
    public private(set) var pinnedSubjects: [String] = []
    /// The strip's vocabulary — the taxonomy minus hidden subjects, chosen
    /// interests first. Empty until it loads, which simply hides the strip.
    public private(set) var subjects: [TopicOption] = []

    private let service: FeedServiceProtocol
    private let analytics: AnalyticsClient
    private let subjectSource: SubjectCatalogProviding?
    private let storage: StorageClient?
    private let subjectDebounce: UInt64
    /// Bumped whenever the pinned subject changes. A page that comes back
    /// carrying an older epoch belongs to a subject nobody is looking at any
    /// more, and is dropped rather than shown under the new one.
    private var subjectEpoch: Int = 0
    private var hasLoadedSubjects = false

    /// How long a tap down the strip waits before asking the server, in
    /// nanoseconds. A run of taps is one decision, not four.
    public static let defaultSubjectDebounce: UInt64 = 250_000_000

    /// - Parameters:
    ///   - service: Feed backend.
    ///   - analytics: Event sink.
    ///   - initialTab: Tab to open on. Defaults to ``FeedTab/forYou``.
    ///   - subjects: Where the strip's vocabulary comes from. `nil` — the
    ///     default — leaves the strip out entirely, which is what every screen
    ///     that shows a feed without one already had.
    ///   - storage: Remembers the pinned subject between launches. `nil`
    ///     forgets it when the app closes.
    ///   - subjectDebounce: Overridable so tests do not wait.
    public init(
        service: FeedServiceProtocol,
        analytics: AnalyticsClient,
        initialTab: FeedTab = .forYou,
        subjects: SubjectCatalogProviding? = nil,
        storage: StorageClient? = nil,
        subjectDebounce: UInt64 = HomeViewModel.defaultSubjectDebounce
    ) {
        self.service = service
        self.analytics = analytics
        self.subjectSource = subjects
        self.storage = storage
        self.subjectDebounce = subjectDebounce
        self.selectedTab = initialTab
        for tab in FeedTab.allCases {
            states[tab] = FeedTabState()
        }
        // Read before the first fetch, so a feed that opens on pinned
        // subjects is narrowed from its very first page rather than flashing
        // the unfiltered timeline first. The stored value was a single id
        // before it was a list, and an old one still reads correctly.
        if let many = storage?.value(for: .pinnedSubject, as: [String].self) {
            self.pinnedSubjects = many.filter { !$0.isEmpty }
        } else if let one = storage?.value(for: .pinnedSubject, as: String.self),
                  !one.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.pinnedSubjects = [one]
        }
    }

    // MARK: - Subjects

    /// Loads the strip's vocabulary once.
    ///
    /// Failure is silent on purpose: the strip is an addition to the timeline,
    /// not the timeline, and a banner about a vocabulary nobody asked for
    /// would interrupt reading to report something that changed nothing.
    public func loadSubjectsIfNeeded() async {
        guard let subjectSource, !hasLoadedSubjects else { return }
        hasLoadedSubjects = true
        do {
            subjects = try await subjectSource.loadSubjects().strip
        } catch {
            hasLoadedSubjects = false
            return
        }
        // A subject that has since been hidden — or that the server has
        // retired — cannot stay pinned: the timeline would be narrowed by
        // something the strip does not even show.
        let offered = Set(subjects.map(\.id))
        let kept = pinnedSubjects.filter { offered.contains($0) }
        if kept != pinnedSubjects {
            pinnedSubjects = kept
            rememberPinnedSubject()
            await reloadForSubjectChange()
        }
    }

    /// Adds a subject to the pinned set, or takes it out again.
    ///
    /// Every tab is thrown away and the visible one is re-read, because the
    /// server applies the subjects; what is already in memory was chosen
    /// under the previous set, and keeping it would show a filter that
    /// visibly did nothing.
    /// - Parameter subject: The chip that was tapped. `nil` clears them all.
    public func pin(_ subject: String?) async {
        guard let subject, !subject.isEmpty else {
            guard !pinnedSubjects.isEmpty else { return }
            pinnedSubjects = []
            rememberPinnedSubject()
            analytics.track(.feedSubjectPinned, properties: ["subject": "none", "tab": selectedTab.rawValue])
            await reloadForSubjectChange()
            return
        }

        if let index = pinnedSubjects.firstIndex(of: subject) {
            pinnedSubjects.remove(at: index)
        } else {
            guard pinnedSubjects.count < HomeViewModel.maximumPinnedSubjects else {
                // Past a point the strip has stopped being a choice. Said
                // rather than silently ignored, which reads as a dead chip.
                toast = .warning(L10n.t("feed.subject.tooMany", HomeViewModel.maximumPinnedSubjects))
                return
            }
            pinnedSubjects.append(subject)
        }
        rememberPinnedSubject()
        analytics.track(.feedSubjectPinned, properties: [
            "subject": pinnedSubjects.isEmpty ? "none" : pinnedSubjects.joined(separator: ","),
            "tab": selectedTab.rawValue
        ])
        await reloadForSubjectChange()
    }

    /// How many subjects may be pinned at once. The server's own limit.
    public static let maximumPinnedSubjects = 10

    /// The pinned subjects' names in the reader's language, for the empty
    /// state. Falls back to the ids, which are at least recognisable.
    public var pinnedSubjectLabel: String? {
        guard !pinnedSubjects.isEmpty else { return nil }
        let names = pinnedSubjects.map { id in
            subjects.first { $0.id == id }?.label ?? TopicOption.makeLabel(from: id)
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    /// Re-reads the vocabulary and the feeds it affects.
    ///
    /// Called after the preferences screen saves: hiding a subject there has
    /// to take it out of the strip here, and un-pin it if it was pinned.
    public func subjectsChanged() async {
        hasLoadedSubjects = false
        await loadSubjectsIfNeeded()
        await invalidateInternationalFeed()
    }

    private func reloadForSubjectChange() async {
        subjectEpoch &+= 1
        let epoch = subjectEpoch
        for tab in FeedTab.allCases { clear(tab) }

        if subjectDebounce > 0 {
            try? await Task.sleep(nanoseconds: subjectDebounce)
            guard epoch == subjectEpoch else { return }
        }
        await loadFirstPage(selectedTab, isRefresh: false)
    }

    private func rememberPinnedSubject() {
        guard let storage else { return }
        if pinnedSubjects.isEmpty {
            storage.remove(.pinnedSubject)
        } else {
            storage.set(pinnedSubjects, for: .pinnedSubject)
        }
    }

    /// Empties one tab so its next appearance re-reads it.
    private func clear(_ tab: FeedTab) {
        var state = self.state(for: tab)
        state.posts = []
        state.cursor = nil
        state.hasMore = true
        state.hasLoaded = false
        state.emptyKind = nil
        state.isLoading = false
        state.isLoadingMore = false
        state.isRefreshing = false
        states[tab] = state
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

        let epoch = subjectEpoch
        do {
            let page = try await service.fetchFeed(
                tab,
                topics: pinnedSubjects,
                cursor: cursor,
                limit: FeedConstants.defaultPageSize
            )
            // The subject changed while this page was in flight; it is a page
            // of a timeline that no longer exists.
            guard epoch == subjectEpoch else { return }
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
            guard epoch == subjectEpoch else { return }
            var updated = state(for: tab)
            updated.isLoadingMore = false
            if APIError.wrapping(error).isCancellation {
                // The row that asked for the page scrolled away, taking its
                // task with it. Nothing failed: the next row asks again.
                states[tab] = updated
                return
            }
            // Stop the pager rather than hammering a failing endpoint on every
            // scroll; pull-to-refresh is the way back.
            updated.hasMore = false
            states[tab] = updated
            toast = .error(for: error)
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

        let epoch = subjectEpoch
        let topics = pinnedSubjects
        do {
            let page = try await service.fetchFeed(
                tab,
                topics: topics,
                cursor: nil,
                limit: FeedConstants.defaultPageSize
            )
            guard epoch == subjectEpoch else { return }
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
            guard epoch == subjectEpoch else { return }
            var updated = state(for: tab)
            updated.isLoading = false
            updated.isRefreshing = false
            if !topics.isEmpty, isSubjectRefusal(error) {
                // One of the subjects was hidden or retired somewhere else —
                // another device, or the preferences screen. The server does
                // not say which, so all of them are dropped, said once, and
                // the whole timeline comes back.
                states[tab] = updated
                pinnedSubjects = []
                rememberPinnedSubject()
                toast = .warning(userMessage(for: error))
                await reloadForSubjectChange()
                return
            }
            if APIError.wrapping(error).isCancellation {
                // Abandoned, not failed. `hasLoaded` stays as it was, so a
                // first load that never finished is asked for again on the
                // next appearance, and a refresh that was cut short leaves
                // the page it was refreshing alone.
                states[tab] = updated
                return
            }
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
                toast = .error(for: error)
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
            toast = .error(for: error)
        }
    }

    /// Drops a post the viewer deleted from every tab, now.
    public func remove(postId: UUID) {
        for tab in FeedTab.allCases {
            guard var tabState = states[tab], tabState.posts.contains(where: { $0.id == postId }) else { continue }
            tabState.posts.removeAll { $0.id == postId }
            if tabState.posts.isEmpty, tabState.hasLoaded { tabState.emptyKind = .noPosts }
            states[tab] = tabState
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

    /// Throws away the International feed's loaded page and reloads it if it is
    /// on screen.
    ///
    /// Called after the preferences screen saves a change the server accepted.
    /// `GET /feed/international` applies the stored preferences server-side, so
    /// everything already in memory was selected under the *old* rules —
    /// keeping it would show a filter that visibly did nothing. The other three
    /// feeds are untouched because the backend does not filter them by topic.
    public func invalidateInternationalFeed() async {
        clear(.international)

        // If the user is looking at it, refetch now; otherwise the cleared
        // `hasLoaded` makes the next visit load it.
        if selectedTab == .international {
            await loadFirstPage(.international, isRefresh: false)
        }
    }

    /// Removes everything written by one account, from every tab, now.
    ///
    /// Called after a block. The server will stop serving these posts on the
    /// next request anyway — the point is that they must not still be on screen
    /// while that request is in flight. A block whose effect only appears after
    /// a manual pull-to-refresh reads as a button that did not work, which on
    /// this particular button is not a small failure.
    ///
    /// Quoted posts are cleared too, so a blocked account cannot keep speaking
    /// from inside somebody else's quote card.
    /// - Parameter handle: The blocked account's handle, any casing.
    /// - Returns: How many posts were taken out.
    @discardableResult
    public func removeAuthor(_ handle: String) -> Int {
        let target = Handle.normalised(handle)
        guard !target.isEmpty else { return 0 }
        var removed = 0

        for tab in FeedTab.allCases {
            guard var tabState = states[tab] else { continue }
            let before = tabState.posts.count
            tabState.posts.removeAll { Handle.normalised($0.author.handle) == target }
            removed += before - tabState.posts.count

            // A post that merely *quotes* the blocked account stays — it is
            // somebody else's post — but the quote card inside it goes.
            tabState.posts = tabState.posts.map { post in
                guard let quoted = post.quotedPost,
                      Handle.normalised(quoted.author.handle) == target
                else { return post }
                return post.strippingQuote()
            }

            if before != tabState.posts.count || tabState.posts.isEmpty {
                tabState.emptyKind = tabState.posts.isEmpty && tabState.hasLoaded ? .noPosts : tabState.emptyKind
            }
            states[tab] = tabState
        }
        return removed
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

    /// Whether the server refused the pinned subject itself.
    private func isSubjectRefusal(_ error: Error) -> Bool {
        guard let code = (error as? APIError)?.code else { return false }
        return code == .topicMuted || code == .unknownTopic
    }

    private func isNoCountry(_ error: Error) -> Bool {
        (error as? APIError)?.code == .noCountry
    }

    private func userMessage(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? L10n.t("feed.error.pullToRefresh")
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
