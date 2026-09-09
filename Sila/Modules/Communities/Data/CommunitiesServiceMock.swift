import Foundation

/// In-memory ``CommunitiesServiceProtocol`` for previews and tests.
public actor CommunitiesServiceMock: CommunitiesServiceProtocol {

    public enum Scenario: Sendable { case populated, empty, offline }

    private var scenario: Scenario
    private var stored: [Community]
    private var members: [UUID: [CommunityMember]] = [:]
    private var posts: [UUID: [Post]] = [:]
    private var rooms: [UUID: [VoiceRoom]] = [:]
    public private(set) var recordedCalls: [String] = []

    private static let viewer = UserSummary(
        id: UUID(uuidString: "55555555-0000-4000-8000-000000000001")!,
        handle: "aziz", displayName: "Aziz", isVerified: true, countryCode: "SA"
    )
    private static let other = UserSummary(
        id: UUID(uuidString: "55555555-0000-4000-8000-000000000002")!,
        handle: "noura", displayName: "Noura", isVerified: true, countryCode: "SA"
    )

    public init(scenario: Scenario = .populated) {
        self.scenario = scenario
        switch scenario {
        case .empty, .offline:
            stored = []
        case .populated:
            stored = [
                Community(
                    id: UUID(uuidString: "66666666-0000-4000-8000-000000000001")!,
                    slug: "riyadh_runners", name: "Riyadh runners",
                    description: "We run at six, every morning.",
                    owner: Self.other, topic: "sports", memberCount: 214,
                    rules: ["Be kind", "No selling"],
                    viewerRole: nil, isMember: false, canPost: false,
                    postRefusal: "Join this community to post in it"
                ),
                Community(
                    id: UUID(uuidString: "66666666-0000-4000-8000-000000000002")!,
                    slug: "family", name: "Family",
                    owner: Self.viewer, visibility: .private, joinPolicy: .invite,
                    memberCount: 6, viewerRole: .owner, isMember: true, canJoin: false,
                    joinRefusal: "You are already in this community", canPost: true
                )
            ]
        }
    }

    public func fetchCommunities(mine: Bool, forYou: Bool, topic: String?, limit: Int) async throws -> [Community] {
        recordedCalls.append("fetchCommunities:mine=\(mine):forYou=\(forYou)")
        try failIfOffline()
        var rows = stored
        if mine { rows = rows.filter(\.isMember) }
        if let topic, !topic.isEmpty { rows = rows.filter { $0.topic == topic } }
        return Array(rows.prefix(limit))
    }

    public func fetchCommunity(slug: String) async throws -> Community {
        recordedCalls.append("fetchCommunity:\(slug)")
        try failIfOffline()
        guard let found = stored.first(where: { $0.slug == slug }) else { throw Self.notFound }
        return found
    }

    public func createCommunity(_ request: CreateCommunityRequest) async throws -> Community {
        recordedCalls.append("createCommunity:\(request.slug)")
        try failIfOffline()
        guard !stored.contains(where: { $0.slug == request.slug }) else {
            throw APIError.api(code: .slugTaken, message: "That address is already taken.", status: 409)
        }
        let community = Community(
            id: UUID(), slug: request.slug, name: request.name, description: request.description,
            owner: Self.viewer,
            visibility: CommunityVisibility(rawValue: request.visibility) ?? .public,
            joinPolicy: CommunityJoinPolicy(rawValue: request.joinPolicy) ?? .open,
            topic: request.topic, verifiedOnly: request.verifiedOnly, memberCount: 1,
            rules: request.rules, viewerRole: .owner, isMember: true, canJoin: false, canPost: true
        )
        stored.append(community)
        return community
    }

    public func updateCommunity(slug: String, update: CommunityUpdate) async throws -> Community {
        recordedCalls.append("updateCommunity:\(slug)")
        try failIfOffline()
        guard let index = stored.firstIndex(where: { $0.slug == slug }) else { throw Self.notFound }
        let old = stored[index]
        let updated = Community(
            id: old.id, slug: old.slug, name: update.name ?? old.name,
            description: update.description ?? old.description, owner: old.owner,
            visibility: old.visibility,
            joinPolicy: update.joinPolicy.flatMap(CommunityJoinPolicy.init(rawValue:)) ?? old.joinPolicy,
            topic: update.topic ?? old.topic, verifiedOnly: update.verifiedOnly ?? old.verifiedOnly,
            memberCount: old.memberCount, rules: update.rules ?? old.rules,
            viewerRole: old.viewerRole, isMember: old.isMember, canJoin: old.canJoin, canPost: old.canPost
        )
        stored[index] = updated
        return updated
    }

    public func closeCommunity(slug: String) async throws {
        recordedCalls.append("closeCommunity:\(slug)")
        try failIfOffline()
        stored.removeAll { $0.slug == slug }
    }

    public func join(slug: String) async throws -> Community {
        recordedCalls.append("join:\(slug)")
        try failIfOffline()
        guard let index = stored.firstIndex(where: { $0.slug == slug }) else { throw Self.notFound }
        let old = stored[index]
        guard old.canJoin else {
            throw APIError.api(code: .notInvited, message: old.joinRefusal ?? "", status: 403)
        }
        let pending = old.joinPolicy == .approval
        let joined = Community(
            id: old.id, slug: old.slug, name: old.name, description: old.description, owner: old.owner,
            visibility: old.visibility, joinPolicy: old.joinPolicy, topic: old.topic,
            verifiedOnly: old.verifiedOnly, memberCount: old.memberCount + (pending ? 0 : 1),
            rules: old.rules, viewerRole: pending ? nil : .member,
            isMember: !pending, isPending: pending, canJoin: false, canPost: !pending,
            postRefusal: pending ? "Waiting to be let in" : nil
        )
        stored[index] = joined
        return joined
    }

    public func leave(slug: String) async throws {
        recordedCalls.append("leave:\(slug)")
        try failIfOffline()
        guard let index = stored.firstIndex(where: { $0.slug == slug }) else { throw Self.notFound }
        let old = stored[index]
        stored[index] = Community(
            id: old.id, slug: old.slug, name: old.name, description: old.description, owner: old.owner,
            visibility: old.visibility, joinPolicy: old.joinPolicy, topic: old.topic,
            memberCount: max(0, old.memberCount - 1), rules: old.rules,
            viewerRole: nil, isMember: false, canJoin: true, canPost: false
        )
    }

    public func invite(slug: String, handles: [String]) async throws {
        recordedCalls.append("invite:\(slug):\(RoomInviteHandles.clean(handles).joined(separator: ","))")
        try failIfOffline()
    }

    public func approve(slug: String, handle: String) async throws {
        recordedCalls.append("approve:\(handle)")
        try failIfOffline()
        members[idOf(slug)]?.removeAll { $0.user.handle == Handle.normalised(handle) }
    }

    public func remove(slug: String, handle: String, ban: Bool) async throws {
        recordedCalls.append("remove:\(handle):ban=\(ban)")
        try failIfOffline()
        members[idOf(slug)]?.removeAll { $0.user.handle == Handle.normalised(handle) }
    }

    public func setRole(slug: String, handle: String, role: CommunityRole) async throws {
        recordedCalls.append("setRole:\(handle):\(role.rawValue)")
        try failIfOffline()
    }

    public func fetchPosts(slug: String, cursor: String?) async throws -> FeedPage {
        recordedCalls.append("fetchPosts:\(slug)")
        try failIfOffline()
        return FeedPage(posts: posts[idOf(slug)] ?? [], nextCursor: nil, hasMore: false)
    }

    public func fetchRooms(slug: String) async throws -> [VoiceRoom] {
        recordedCalls.append("fetchRooms:\(slug)")
        try failIfOffline()
        return rooms[idOf(slug)] ?? []
    }

    public func fetchMembers(slug: String, status: String) async throws -> [CommunityMember] {
        recordedCalls.append("fetchMembers:\(slug):\(status)")
        try failIfOffline()
        return members[idOf(slug)] ?? (status == "active"
            ? [CommunityMember(user: Self.other, role: .owner), CommunityMember(user: Self.viewer)]
            : [])
    }

    /// Seeds a community, for tests that need a specific one.
    @discardableResult
    public func seed(_ community: Community) -> Community {
        stored.append(community)
        return community
    }

    public func seedMembers(_ people: [CommunityMember], in slug: String) {
        members[idOf(slug)] = people
    }

    private func idOf(_ slug: String) -> UUID {
        stored.first { $0.slug == slug }?.id ?? UUID()
    }

    private static var notFound: APIError {
        APIError.api(code: .notFound, message: "No such community.", status: 404)
    }

    private func failIfOffline() throws {
        if scenario == .offline { throw APIError.transport("offline") }
    }
}
