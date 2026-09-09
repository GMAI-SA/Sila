import Foundation

/// A named space people join on purpose.
///
/// The one construct here where membership is mutual and visible: a follow is
/// one person reading another, a group is a private list nobody is told about,
/// a room ends when its host ends it. A community keeps its posts under a
/// shared name and the people who run it moderate before the platform does.
public struct Community: Identifiable, Hashable, Sendable, Decodable {

    public let id: UUID
    /// The address: `/c/{slug}`, the way a handle is a profile's.
    public let slug: String
    public let name: String
    public let description: String?
    public let avatarURL: URL?
    public let owner: UserSummary
    /// `public` or `private`.
    public let visibility: CommunityVisibility
    /// How somebody gets in.
    public let joinPolicy: CommunityJoinPolicy
    /// Who may **post**, the same way it governs a post or a room.
    public let scope: PostScope
    public let scopeCountry: String?
    public let scopeRegion: String?
    public let topic: String?
    /// Only verified accounts may post and open rooms here.
    public let verifiedOnly: Bool
    public let memberCount: Int
    public let rules: [String]
    public let createdAt: Date

    // What this viewer may do, resolved by the server so the client never
    // re-derives the rules and never disagrees with what the API will accept.
    public let viewerRole: CommunityRole?
    public let isMember: Bool
    public let isPending: Bool
    public let isInvited: Bool
    public let canView: Bool
    public let canJoin: Bool
    public let joinRefusal: String?
    public let canPost: Bool
    public let postRefusal: String?
    public let matchesInterests: Bool

    public init(
        id: UUID,
        slug: String,
        name: String,
        description: String? = nil,
        avatarURL: URL? = nil,
        owner: UserSummary,
        visibility: CommunityVisibility = .public,
        joinPolicy: CommunityJoinPolicy = .open,
        scope: PostScope = .international,
        scopeCountry: String? = nil,
        scopeRegion: String? = nil,
        topic: String? = nil,
        verifiedOnly: Bool = false,
        memberCount: Int = 1,
        rules: [String] = [],
        createdAt: Date = Date(),
        viewerRole: CommunityRole? = nil,
        isMember: Bool = false,
        isPending: Bool = false,
        isInvited: Bool = false,
        canView: Bool = true,
        canJoin: Bool = true,
        joinRefusal: String? = nil,
        canPost: Bool = false,
        postRefusal: String? = nil,
        matchesInterests: Bool = false
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.avatarURL = avatarURL
        self.owner = owner
        self.visibility = visibility
        self.joinPolicy = joinPolicy
        self.scope = scope
        self.scopeCountry = scopeCountry
        self.scopeRegion = scopeRegion
        self.topic = topic
        self.verifiedOnly = verifiedOnly
        self.memberCount = memberCount
        self.rules = rules
        self.createdAt = createdAt
        self.viewerRole = viewerRole
        self.isMember = isMember
        self.isPending = isPending
        self.isInvited = isInvited
        self.canView = canView
        self.canJoin = canJoin
        self.joinRefusal = joinRefusal
        self.canPost = canPost
        self.postRefusal = postRefusal
        self.matchesInterests = matchesInterests
    }

    private enum CodingKeys: String, CodingKey {
        case id, slug, name, description, owner, visibility, joinPolicy
        case scope, scopeCountry, scopeRegion, topic, verifiedOnly, memberCount, rules, createdAt
        case viewerRole, isMember, isPending, isInvited, canView, canJoin, joinRefusal
        case canPost, postRefusal, matchesInterests
        case avatarURL = "avatarUrl"
    }

    /// Tolerant: one malformed optional must not blank a whole list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        slug = (try? container.decode(String.self, forKey: .slug)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? slug
        let about = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        description = (about?.isEmpty == false) ? about : nil
        avatarURL = AppConfig.mediaURL((try? container.decodeIfPresent(String.self, forKey: .avatarURL)) ?? nil)
        owner = try container.decode(UserSummary.self, forKey: .owner)
        visibility = (try? container.decode(CommunityVisibility.self, forKey: .visibility)) ?? .public
        joinPolicy = (try? container.decode(CommunityJoinPolicy.self, forKey: .joinPolicy)) ?? .open
        scope = (try? container.decode(PostScope.self, forKey: .scope)) ?? .international
        scopeCountry = CountryCode.normalised((try? container.decodeIfPresent(String.self, forKey: .scopeCountry)) ?? nil)
        scopeRegion = (try? container.decodeIfPresent(String.self, forKey: .scopeRegion)) ?? nil
        topic = (try? container.decodeIfPresent(String.self, forKey: .topic)) ?? nil
        verifiedOnly = (try? container.decode(Bool.self, forKey: .verifiedOnly)) ?? false
        memberCount = max(0, (try? container.decode(Int.self, forKey: .memberCount)) ?? 0)
        rules = ((try? container.decode([String].self, forKey: .rules)) ?? []).filter { !$0.isEmpty }
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        viewerRole = (try? container.decodeIfPresent(CommunityRole.self, forKey: .viewerRole)) ?? nil
        isMember = (try? container.decode(Bool.self, forKey: .isMember)) ?? false
        isPending = (try? container.decode(Bool.self, forKey: .isPending)) ?? false
        isInvited = (try? container.decode(Bool.self, forKey: .isInvited)) ?? false
        // Fails **open**, like a room's: a server without this field has no
        // private communities, and the read itself is the real gate.
        canView = (try? container.decode(Bool.self, forKey: .canView)) ?? true
        canJoin = (try? container.decode(Bool.self, forKey: .canJoin)) ?? true
        let shut = (try? container.decodeIfPresent(String.self, forKey: .joinRefusal)) ?? nil
        joinRefusal = (shut?.isEmpty == false) ? shut : nil
        canPost = (try? container.decode(Bool.self, forKey: .canPost)) ?? false
        let quiet = (try? container.decodeIfPresent(String.self, forKey: .postRefusal)) ?? nil
        postRefusal = (quiet?.isEmpty == false) ? quiet : nil
        matchesInterests = (try? container.decode(Bool.self, forKey: .matchesInterests)) ?? false
    }

    /// The address as it is written and shared.
    public var address: String { "/c/\(slug)" }

    /// Whether this viewer runs the place.
    public var isAdmin: Bool { viewerRole == .owner || viewerRole == .admin }

    /// The scope chip, rendered exactly as a post's is.
    ///
    /// `.thread` rather than a case of its own: a community's scope governs
    /// who may write in it, which is the same sentence a thread's scope says
    /// — "only verified accounts in Saudi Arabia can reply" and "…can post"
    /// are one idea, and a second vocabulary for it would be two ways to say
    /// the same thing in two languages.
    public var scopePresentation: ScopePresentation {
        ScopePresentation.make(scope: scope, country: scopeCountry, region: scopeRegion, subject: .thread)
    }

    /// The one line under the name: how many people, and what kind of door.
    public var summary: String {
        var parts = [L10n.plural("communities.members.count", memberCount)]
        if visibility == .private { parts.append(CommunityCopy.privateBadge) }
        else if joinPolicy != .open { parts.append(joinPolicy.badge) }
        return parts.joined(separator: " · ")
    }
}

public enum CommunityVisibility: String, Codable, Sendable, CaseIterable, Identifiable {
    case `public`, `private`
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .public: return L10n.t("communities.visibility.public.title")
        case .private: return L10n.t("communities.visibility.private.title")
        }
    }
    public var explanation: String {
        switch self {
        case .public: return L10n.t("communities.visibility.public.explanation")
        case .private: return L10n.t("communities.visibility.private.explanation")
        }
    }
    public var icon: String { self == .public ? "globe" : "lock.fill" }
}

public enum CommunityJoinPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case open, approval, invite
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .open: return L10n.t("communities.join.open.title")
        case .approval: return L10n.t("communities.join.approval.title")
        case .invite: return L10n.t("communities.join.invite.title")
        }
    }
    public var explanation: String {
        switch self {
        case .open: return L10n.t("communities.join.open.explanation")
        case .approval: return L10n.t("communities.join.approval.explanation")
        case .invite: return L10n.t("communities.join.invite.explanation")
        }
    }
    public var icon: String {
        switch self {
        case .open: return "door.left.hand.open"
        case .approval: return "hand.raised"
        case .invite: return "envelope"
        }
    }
    public var badge: String {
        switch self {
        case .open: return L10n.t("communities.join.open.title")
        case .approval: return L10n.t("communities.badge.approval")
        case .invite: return L10n.t("communities.badge.invite")
        }
    }
}

public enum CommunityRole: String, Codable, Sendable {
    case owner, admin, member
    public var title: String {
        switch self {
        case .owner: return L10n.t("communities.role.owner")
        case .admin: return L10n.t("communities.role.admin")
        case .member: return L10n.t("communities.role.member")
        }
    }
    public var isAdmin: Bool { self != .member }
}

/// One person in a community.
public struct CommunityMember: Identifiable, Hashable, Sendable, Decodable {
    public let user: UserSummary
    public let role: CommunityRole
    public let status: String
    public var id: UUID { user.id }

    public init(user: UserSummary, role: CommunityRole = .member, status: String = "active") {
        self.user = user
        self.role = role
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case user, role, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(UserSummary.self, forKey: .user)
        role = (try? container.decode(CommunityRole.self, forKey: .role)) ?? .member
        status = (try? container.decode(String.self, forKey: .status)) ?? "active"
    }
}

/// `GET /communities` answers `{"communities": [...]}`.
struct CommunityList: Decodable {
    let communities: [Community]

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let rows = try? single.decode([Community].self) {
            communities = rows
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        communities = (try? container.decode([Community].self, forKey: .communities)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case communities }
}

/// `GET /communities/{slug}/members` answers `{"members": [...]}`.
struct CommunityMemberList: Decodable {
    let members: [CommunityMember]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? container.decode([CommunityMember].self, forKey: .members)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case members }
}

/// `GET /communities/{slug}/rooms` answers `{"rooms": [...]}`.
struct CommunityRoomList: Decodable {
    let rooms: [VoiceRoom]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rooms = (try? container.decode([VoiceRoom].self, forKey: .rooms)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case rooms }
}

/// The body of `POST /communities`.
public struct CreateCommunityRequest: Encodable, Equatable, Sendable {
    public let slug: String
    public let name: String
    public let description: String?
    public let visibility: String
    public let joinPolicy: String
    public let scope: String
    public let scopeCountry: String?
    public let scopeRegion: String?
    public let topic: String?
    public let verifiedOnly: Bool
    public let rules: [String]

    public init(
        slug: String,
        name: String,
        description: String? = nil,
        visibility: CommunityVisibility = .public,
        joinPolicy: CommunityJoinPolicy = .open,
        scope: ComposeScope = .international,
        topic: String? = nil,
        verifiedOnly: Bool = false,
        rules: [String] = []
    ) {
        self.slug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = (about?.isEmpty == false) ? about : nil
        self.visibility = visibility.rawValue
        self.joinPolicy = joinPolicy.rawValue
        self.scope = scope.wireValue
        self.scopeCountry = scope.scopeCountry
        self.scopeRegion = scope.scopeRegion
        self.topic = (topic?.isEmpty == false) ? topic : nil
        self.verifiedOnly = verifiedOnly
        self.rules = rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Optional fields are omitted rather than sent as `null`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(joinPolicy, forKey: .joinPolicy)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(scopeCountry, forKey: .scopeCountry)
        try container.encodeIfPresent(scopeRegion, forKey: .scopeRegion)
        try container.encodeIfPresent(topic, forKey: .topic)
        if verifiedOnly { try container.encode(true, forKey: .verifiedOnly) }
        if !rules.isEmpty { try container.encode(rules, forKey: .rules) }
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name, description, visibility, joinPolicy
        case scope, scopeCountry, scopeRegion, topic, verifiedOnly, rules
    }
}

/// What an admin may change about a community.
///
/// Every field is optional and the encoder omits the nils, so a call changes
/// what it names and leaves the rest alone.
public struct CommunityUpdate: Encodable, Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var joinPolicy: String?
    public var topic: String?
    public var verifiedOnly: Bool?
    public var rules: [String]?

    public init(
        name: String? = nil,
        description: String? = nil,
        joinPolicy: CommunityJoinPolicy? = nil,
        topic: String? = nil,
        verifiedOnly: Bool? = nil,
        rules: [String]? = nil
    ) {
        self.name = name
        self.description = description
        self.joinPolicy = joinPolicy?.rawValue
        self.topic = topic
        self.verifiedOnly = verifiedOnly
        self.rules = rules
    }
}

struct CommunityRoleBody: Encodable { let role: String }

/// The words a community screen uses.
public enum CommunityCopy {
    public static var title: String { L10n.t("communities.title") }
    public static var privateBadge: String { L10n.t("communities.badge.private") }
    public static var join: String { L10n.t("communities.join") }
    public static var requested: String { L10n.t("communities.requested") }
    public static var leave: String { L10n.t("communities.leave") }
    public static var notKept: String { L10n.t("communities.rules.heading") }
    /// Why the door did not open, in the server's words where it sent any.
    public static func joinRefusal(_ community: Community) -> String {
        community.joinRefusal ?? L10n.t("communities.join.refused")
    }
}
