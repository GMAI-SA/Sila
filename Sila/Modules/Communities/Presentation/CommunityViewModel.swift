import Foundation
import Observation

/// One community: its posts, its rooms, its people, and the door.
@MainActor
@Observable
public final class CommunityViewModel {

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case posts, rooms, members, about
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .posts: return L10n.t("communities.tab.posts")
            case .rooms: return L10n.t("communities.tab.rooms")
            case .members: return L10n.t("communities.tab.members")
            case .about: return L10n.t("communities.tab.about")
            }
        }
    }

    public private(set) var community: Community?
    public private(set) var posts: [Post] = []
    public private(set) var rooms: [VoiceRoom] = []
    public private(set) var members: [CommunityMember] = []
    /// People waiting to be let in. Admins only; empty for everybody else.
    public private(set) var pending: [CommunityMember] = []
    public private(set) var isLoading = false
    public private(set) var isJoining = false
    public private(set) var loadError: String?
    public var tab: Tab = .posts
    public var toast: SLToastMessage?

    public let slug: String
    private let service: CommunitiesServiceProtocol
    private let feed: FeedServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private var postsCursor: String?

    public init(
        slug: String,
        service: CommunitiesServiceProtocol,
        feed: FeedServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil
    ) {
        self.slug = slug
        self.service = service
        self.feed = feed
        self.analytics = analytics
        self.suspension = suspension
    }

    /// True when the viewer may read what is inside.
    public var canView: Bool { community?.canView ?? false }

    /// The button under the header, or `nil` when there is nothing to press.
    public var doorTitle: String? {
        guard let community else { return nil }
        // The owner cannot leave their own community — the server says so
        // with a 409, and offering the button is a promise it will not keep.
        if community.viewerRole == .owner { return nil }
        if community.isMember { return CommunityCopy.leave }
        if community.isPending { return CommunityCopy.requested }
        return community.canJoin ? CommunityCopy.join : nil
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let found = try await service.fetchCommunity(slug: slug)
            community = found
            analytics.track(.communityOpened, properties: ["member": String(found.isMember)])
            await loadTabContents()
        } catch {
            guard suspension?.notice(error) != true else { return }
            loadError = APIError.wrapping(error).userMessage
        }
    }

    /// Reads what the current tab needs, and nothing else.
    public func loadTabContents() async {
        guard let community, community.canView else { return }
        switch tab {
        case .posts:
            await loadPosts()
        case .rooms:
            // A failed read leaves what is on screen and says so, rather than
            // wiping the tab to an empty state that reads as "there are none".
            if let found = try? await service.fetchRooms(slug: slug) { rooms = found }
            else if rooms.isEmpty { toast = .error(L10n.t("feed.error.pullToRefresh")) }
        case .members:
            if let found = try? await service.fetchMembers(slug: slug, status: "active") { members = found }
            else if members.isEmpty { toast = .error(L10n.t("feed.error.pullToRefresh")) }
            if community.isAdmin, let waiting = try? await service.fetchMembers(slug: slug, status: "pending") {
                pending = waiting
            } else if !community.isAdmin {
                pending = []
            }
        case .about:
            break
        }
    }

    private func loadPosts() async {
        do {
            let page = try await service.fetchPosts(slug: slug, cursor: nil)
            posts = page.posts
            postsCursor = page.nextCursor
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func loadMoreIfNeeded(currentPost post: Post) async {
        guard let cursor = postsCursor, posts.suffix(3).contains(where: { $0.id == post.id }) else { return }
        postsCursor = nil
        do {
            let page = try await service.fetchPosts(slug: slug, cursor: cursor)
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            postsCursor = page.nextCursor
        } catch {
            guard suspension?.notice(error) != true else { return }
            // Put the cursor back: one failed page must not end paging for
            // the life of the screen.
            postsCursor = cursor
        }
    }

    // MARK: - The door

    public func toggleMembership() async {
        guard let community, !isJoining else { return }
        isJoining = true
        defer { isJoining = false }
        do {
            if community.isMember {
                try await service.leave(slug: slug)
                self.community = try? await service.fetchCommunity(slug: slug)
                toast = .info(L10n.t("communities.left", community.name))
            } else {
                let joined = try await service.join(slug: slug)
                self.community = joined
                toast = joined.isPending
                    ? .info(L10n.t("communities.requested.toast"))
                    : .success(L10n.t("communities.joined", joined.name))
                await loadTabContents()
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    // MARK: - Running it

    public func approve(_ member: CommunityMember) async {
        do {
            try await service.approve(slug: slug, handle: member.user.handle)
            pending.removeAll { $0.id == member.id }
            // They are in now: the row must say so, and the header's count
            // must move with it.
            members.append(CommunityMember(user: member.user, role: .member, status: "active"))
            community = community.map(Self.withMemberCount(+1))
            toast = .success(L10n.t("communities.member.approved", member.user.displayName))
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func decline(_ member: CommunityMember) async {
        do {
            // Declining a request is not a ban: they may ask again, or be
            // invited later. Only "remove" keeps somebody out.
            try await service.remove(slug: slug, handle: member.user.handle, ban: false)
            pending.removeAll { $0.id == member.id }
            members.removeAll { $0.id == member.id }
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func remove(_ member: CommunityMember) async {
        do {
            try await service.remove(slug: slug, handle: member.user.handle, ban: true)
            members.removeAll { $0.id == member.id }
            toast = .info(L10n.t("communities.member.removed", member.user.displayName))
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func setRole(_ role: CommunityRole, for member: CommunityMember) async {
        do {
            try await service.setRole(slug: slug, handle: member.user.handle, role: role)
            if let index = members.firstIndex(where: { $0.id == member.id }) {
                members[index] = CommunityMember(user: member.user, role: role, status: member.status)
            }
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func invite(_ people: [UserSummary]) async {
        guard !people.isEmpty else { return }
        do {
            try await service.invite(slug: slug, handles: people.map(\.handle))
            toast = .success(L10n.plural("communities.invited", people.count))
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Whether the viewer may change this person's role. The owner only.
    public func canSetRole(for member: CommunityMember) -> Bool {
        community?.viewerRole == .owner && member.role != .owner
    }

    /// Whether the viewer may act on this person at all.
    public func canManage(_ member: CommunityMember) -> Bool {
        guard let community, community.isAdmin else { return false }
        if member.role == .owner { return false }
        if member.role == .admin { return community.viewerRole == .owner }
        return true
    }

    /// A copy of a community with its member count moved by `delta`.
    private static func withMemberCount(_ delta: Int) -> (Community) -> Community {
        { community in
            Community(
                id: community.id, slug: community.slug, name: community.name,
                description: community.description, avatarURL: community.avatarURL,
                owner: community.owner, visibility: community.visibility,
                joinPolicy: community.joinPolicy, scope: community.scope,
                scopeCountry: community.scopeCountry, scopeRegion: community.scopeRegion,
                topic: community.topic, verifiedOnly: community.verifiedOnly,
                memberCount: max(0, community.memberCount + delta), rules: community.rules,
                createdAt: community.createdAt, viewerRole: community.viewerRole,
                isMember: community.isMember, isPending: community.isPending,
                isInvited: community.isInvited, canView: community.canView,
                canJoin: community.canJoin, joinRefusal: community.joinRefusal,
                canPost: community.canPost, postRefusal: community.postRefusal,
                matchesInterests: community.matchesInterests
            )
        }
    }

    /// Merges a post changed elsewhere back into the timeline.
    public func merge(_ post: Post) {
        for index in posts.indices where posts[index].id == post.id {
            posts[index].metrics = post.metrics
            posts[index].viewer = post.viewer
        }
    }

    /// Puts a post the viewer just wrote at the top.
    public func insert(_ post: Post) {
        guard post.communityId == community?.id else { return }
        posts.insert(post, at: 0)
    }
}
