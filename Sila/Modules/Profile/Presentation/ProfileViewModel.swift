import Foundation
import Observation

/// Why the profile header is not on screen.
///
/// ``unavailable`` is separated from ``failed`` because the two want opposite
/// affordances: a transport failure gets a Retry, and a handle that does not
/// belong to an active account gets none. A Retry button that can never succeed
/// is worse than no button — it invites somebody to keep pressing it.
public enum ProfileLoadState: Equatable, Sendable {
    /// Nothing requested yet.
    case idle
    /// The first load is in flight.
    case loading
    /// The header is on screen.
    case loaded
    /// `404 user_not_found` — an unknown handle, or a deactivated account.
    case unavailable
    /// The request failed; the message is already user-safe.
    case failed(String)
}

/// Drives ``ProfileScreen``.
///
/// Two rules shape it.
///
/// **The follower count is never counted locally.** A tap predicts `±1` so the
/// button does not sit inert, and then the number is *replaced* by the one the
/// response carries. Follow and unfollow are idempotent server-side, so the two
/// disagree the moment a second device acts — and when they do, the server is
/// right and the prediction is a stale guess with no claim on the screen.
///
/// **The timeline is top-level posts only.** The server excludes replies, so
/// nothing here describes the list as everything the person has written. See
/// ``ProfileCopy/timelineScope``.
@MainActor
@Observable
public final class ProfileViewModel {

    /// The handle this screen is about, normalised the way the server matches it.
    public let handle: String

    /// The signed-in account's handle, or `nil` when the session does not carry
    /// one (a session cached by a build older than contract v2).
    ///
    /// Used **only** to answer "is this my own page?" before the server has
    /// said so, which is what keeps the account and sign-out routes on the
    /// Profile tab even when the profile itself fails to load. The server's
    /// `is_me` overrides it the moment it arrives.
    public let viewerHandle: String?

    /// The profile, once the server has described it.
    public private(set) var profile: Profile?
    /// Where the header is in its lifecycle.
    public private(set) var loadState: ProfileLoadState = .idle
    /// The account's top-level posts, in server order.
    public private(set) var posts: [Post] = []
    /// The cursor for the next page, or `nil` at the end.
    public private(set) var cursor: String?
    /// Whether the server says another page exists.
    public private(set) var hasMore = true
    /// `true` while the first page of posts is loading.
    public private(set) var isLoadingPosts = false
    /// `true` while another page is being appended.
    public private(set) var isLoadingMore = false
    /// `true` during pull-to-refresh.
    public private(set) var isRefreshing = false
    /// Why the timeline could not load, when the header did.
    ///
    /// Separate from ``loadState``: a profile whose header arrived and whose
    /// posts did not is still a profile worth showing.
    public private(set) var postsError: String?
    /// `true` while a follow or unfollow is in flight.
    public private(set) var isFollowPending = false
    /// `true` once the viewer has blocked this account.
    ///
    /// Held here rather than derived from a reload, because the timeline has to
    /// empty the moment the block is confirmed. Waiting for
    /// `GET /users/{handle}/posts` to start filtering would leave somebody
    /// staring at the posts they just blocked, which reads as a button that did
    /// not work — on the one screen where that doubt matters most.
    public private(set) var isBlocked = false
    /// `true` once the viewer has muted this account.
    ///
    /// Only ever a badge in the header. A muted account's page still renders in
    /// full: muting takes somebody out of the *feeds*, and blanking a profile
    /// the user deliberately opened would be the app overruling them.
    public private(set) var isMuted = false
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: ProfileServiceProtocol
    private let feed: FeedServiceProtocol
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - handle: Whose profile to show. An `@` and any casing are fine.
    ///   - viewerHandle: The signed-in account's handle, when the session has
    ///     one. Only ever used as a *provisional* answer to `is_me`.
    ///   - service: Profile backend.
    ///   - feed: Backs the engagement buttons on the timeline's cards, so a like
    ///     on a profile behaves exactly like a like in the feed.
    ///   - analytics: Event sink.
    public init(
        handle: String,
        viewerHandle: String? = nil,
        service: ProfileServiceProtocol,
        feed: FeedServiceProtocol,
        analytics: AnalyticsClient
    ) {
        self.handle = Handle.normalised(handle)
        self.viewerHandle = viewerHandle.map(Handle.normalised)
        self.service = service
        self.feed = feed
        self.analytics = analytics
    }

    // MARK: - Derived state

    /// `true` once a load has finished, successfully or not.
    public var hasLoaded: Bool {
        switch loadState {
        case .idle, .loading: return false
        case .loaded, .unavailable, .failed: return true
        }
    }

    /// `true` when the handle does not belong to an active account.
    public var isUnavailable: Bool { loadState == .unavailable }

    /// Whether a Follow / Following control belongs on screen.
    ///
    /// Absent on your own profile rather than disabled — the server answers
    /// `400 self_follow`, so the control would be an affordance for nothing.
    public var showsFollowButton: Bool { profile?.showsFollowControl == true }

    /// Whether the account/settings entry points belong on screen.
    ///
    /// The server's `is_me` decides it once the header has arrived. Before
    /// that — and if the load fails outright — the handles are compared, so a
    /// Profile tab that could not reach the network is still a way into
    /// account settings rather than a dead end in front of the one screen that
    /// holds deletion and the data export.
    public var isOwnProfile: Bool {
        if let profile { return profile.isMe }
        guard let viewerHandle else { return false }
        return viewerHandle == handle
    }

    /// Label for the follow control.
    public var followButtonTitle: String {
        ProfileCopy.followTitle(
            isFollowing: profile?.isFollowing == true,
            isRequested: profile?.isRequested == true
        )
    }

    /// Accessibility hint for the follow control.
    public var followButtonHint: String {
        ProfileCopy.followHint(
            isFollowing: profile?.isFollowing == true,
            isRequested: profile?.isRequested == true,
            name: profile?.displayName ?? handle
        )
    }

    /// `true` when the timeline should be a wall rather than a list.
    ///
    /// From the server's `can_view_posts`, never inferred from `is_private`
    /// plus `is_following` here: the server also knows about ownership and
    /// about a follow approved from another device, and one rule in one place
    /// is the point.
    public var showsPrivateWall: Bool {
        profile.map { !$0.canViewPosts } ?? false
    }

    // MARK: - Follow requests

    /// People waiting to follow the viewer's private account.
    public private(set) var followRequests: [FollowRequest] = []
    /// `true` while the list is being fetched.
    public private(set) var isLoadingRequests = false
    /// `true` while one answer is in flight — one at a time, so a double tap
    /// cannot accept and decline the same person.
    public private(set) var isAnsweringRequest = false

    /// Fetches the waiting list. Own profile only; elsewhere it is a no-op.
    public func loadFollowRequests() async {
        guard isOwnProfile, !isLoadingRequests else { return }
        isLoadingRequests = true
        defer { isLoadingRequests = false }
        do {
            followRequests = try await service.fetchFollowRequests()
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Accepts or declines one request, then reloads the header so the
    /// follower count is the server's.
    public func answer(_ request: FollowRequest, accept: Bool) async {
        guard !isAnsweringRequest else { return }
        isAnsweringRequest = true
        defer { isAnsweringRequest = false }
        do {
            try await service.answerFollowRequest(handle: request.user.handle, accept: accept)
            followRequests.removeAll { $0.id == request.id }
            if accept {
                // A follower gained is a count changed; the server's number
                // replaces the one on screen rather than being incremented.
                await reload(isRefresh: true)
            }
        } catch {
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .notFound {
                // Answered from another device, or withdrawn. Gone either way.
                followRequests.removeAll { $0.id == request.id }
                return
            }
            toast = .error(wrapped.userMessage)
        }
    }

    /// `true` when the timeline has nothing to show and nothing went wrong.
    public var isTimelineEmpty: Bool {
        posts.isEmpty && postsError == nil && !isLoadingPosts && hasLoaded
    }

    // MARK: - Loading

    /// Loads the profile and its first page. Safe on every appearance — it does
    /// nothing once loaded.
    public func load() async {
        guard !hasLoaded, loadState != .loading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry and pull-to-refresh path.
    public func reload(isRefresh: Bool = false) async {
        if isRefresh {
            isRefreshing = true
        } else {
            loadState = .loading
        }
        isLoadingPosts = true
        postsError = nil
        defer {
            isRefreshing = false
            isLoadingPosts = false
        }

        // Both calls hit the same handle, so they are issued together; the
        // header does not need the timeline to arrive before it can render.
        async let header = service.fetchProfile(handle: handle)
        async let firstPage = service.fetchPosts(
            handle: handle,
            cursor: nil,
            limit: FeedConstants.defaultPageSize
        )

        do {
            let loaded = try await header
            profile = loaded
            loadState = .loaded
            analytics.track(.profileOpened, properties: [
                "is_me": String(loaded.isMe),
                "is_following": String(loaded.isFollowing)
            ])
        } catch {
            // The timeline request is still in flight and must be consumed, or
            // it is cancelled mid-decode and its failure is reported nowhere.
            _ = try? await firstPage
            adopt(loadFailure: error)
            return
        }

        do {
            let page = try await firstPage
            posts = page.posts
            cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
        } catch {
            if isUserNotFound(error) {
                // The header succeeded a moment ago, so the account was
                // deactivated between the two calls. The dead end wins.
                adopt(loadFailure: error)
                return
            }
            posts = []
            cursor = nil
            hasMore = false
            postsError = APIError.wrapping(error).userMessage
        }
    }

    /// Appends the next page, if there is one and nothing is already in flight.
    public func loadMore() async {
        guard hasMore, let cursor, !isLoadingMore, !isLoadingPosts, !isRefreshing else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await service.fetchPosts(
                handle: handle,
                cursor: cursor,
                limit: FeedConstants.defaultPageSize
            )
            // De-duplicate: a post written between two requests can otherwise
            // arrive on both pages and break the ForEach's id uniqueness.
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            self.cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
        } catch {
            // Stop the pager rather than hammering a failing endpoint on every
            // scroll; pull-to-refresh is the way back.
            hasMore = false
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Called by the list as rows appear. Triggers ``loadMore()`` when `post` is
    /// within ``FeedConstants/prefetchThreshold`` rows of the end.
    public func loadMoreIfNeeded(currentPost post: Post) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        guard index >= posts.count - FeedConstants.prefetchThreshold else { return }
        await loadMore()
    }

    // MARK: - Following

    /// Follows or unfollows, then adopts whatever the server says is true.
    ///
    /// The prediction exists only so the button changes under the finger. What
    /// stays on screen is ``FollowResult``'s count — because both verbs are
    /// idempotent, and a `+1` computed here is wrong the moment the same account
    /// was followed from somewhere else.
    public func toggleFollow() async {
        guard let snapshot = profile, snapshot.showsFollowControl, !isFollowPending else { return }
        // Following, or waiting to: either way the next tap undoes it.
        let desired = !(snapshot.isFollowing || snapshot.isRequested)

        isFollowPending = true
        profile = snapshot.predicting(following: desired)
        defer { isFollowPending = false }

        do {
            let result = try await service.setFollowing(desired, handle: snapshot.handle)
            // Reconciled against the *snapshot*, so the authoritative count
            // lands on the real state rather than on top of the prediction.
            profile = snapshot.reconciled(with: result)
            if result.following, !snapshot.canViewPosts {
                // Let in on the spot — the account went public, or was never
                // private after all. The timeline the wall stood in for is
                // fetched now rather than on the next visit.
                await reload(isRefresh: true)
            }
        } catch {
            profile = snapshot
            let wrapped = APIError.wrapping(error)
            analytics.track(.followFailed, properties: [
                "code": wrapped.code?.rawValue ?? "transport",
                "desired": String(desired)
            ])
            if isUserNotFound(error) {
                // The account went away while its profile was open.
                loadState = .unavailable
                profile = nil
                posts = []
                return
            }
            toast = .error(wrapped.userMessage)
        }
    }

    // MARK: - Engagement (optimistic)

    /// Toggles the like on one of this account's posts.
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

    // MARK: - Safety

    /// Reacts to a block, mute or unblock taken anywhere in the app.
    ///
    /// Only changes that are about **this** account do anything, so a block
    /// taken on a card inside a quoted post does not blank the page of the
    /// person whose profile it is.
    /// - Parameter change: What just happened.
    public func apply(_ change: SafetyChange) {
        guard Handle.normalised(change.target.handle) == handle else { return }
        switch change {
        case .blocked:
            isBlocked = true
            isMuted = false
            // The posts go now, not after a refetch. The server will filter them
            // out of the next request anyway; the point is that the screen must
            // not still be showing them while it waits.
            posts = []
            cursor = nil
            hasMore = false
            postsError = nil
            // A block severs the follow in both directions, so the header's
            // button must stop claiming otherwise even before a reload.
            if let profile, profile.isFollowing {
                self.profile = profile.predicting(following: false)
            }
        case .unblocked:
            isBlocked = false
        case .muted:
            isMuted = true
        case .unmuted:
            isMuted = false
        }
    }

    /// Reloads after an unblock, so the timeline comes back without the user
    /// having to leave the screen and return to it.
    public func reloadAfterUnblock() async {
        isBlocked = false
        loadState = .idle
        await reload()
    }

    /// Merges a post changed elsewhere (the detail screen) back into the timeline.
    public func merge(_ post: Post) {
        apply(id: post.id) { current in
            var updated = current
            updated.metrics = post.metrics
            updated.viewer = post.viewer
            return updated
        }
    }

    // MARK: - Helpers

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
            // Roll back to exactly what was on screen before the tap.
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

    private func adopt(loadFailure error: Error) {
        profile = nil
        posts = []
        cursor = nil
        hasMore = false
        postsError = nil
        if isUserNotFound(error) {
            loadState = .unavailable
            analytics.track(.profileUnavailable, properties: ["handle": handle])
        } else {
            loadState = .failed(APIError.wrapping(error).userMessage)
        }
    }

    private func isUserNotFound(_ error: Error) -> Bool {
        (error as? APIError)?.code == .userNotFound
    }
}
