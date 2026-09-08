import Foundation
import SwiftUI

// MARK: - Status

/// Where a room is in its life.
///
/// ``unknown`` exists so a status added to the server after this build shipped
/// still renders as a row rather than failing the whole page's decode. It is
/// never treated as live: a room this client cannot describe is not one it
/// should offer a microphone in.
public enum RoomStatus: String, Sendable, Hashable, Decodable, CaseIterable {
    /// Somebody is in it now.
    case live
    /// It has a start time and has not started.
    case scheduled
    /// The host ended it. Nothing can be joined, and nothing was kept.
    case ended
    /// A status this build does not recognise.
    case unknown

    /// The three the contract names, in the order the list shows them.
    public static let known: [RoomStatus] = [.live, .scheduled, .ended]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RoomStatus(rawValue: raw) ?? .unknown
    }

    /// The `?status=` value, or `nil` for a status the server has no filter for.
    public var wireValue: String? { self == .unknown ? nil : rawValue }

    /// `true` when joining could put audio on a device.
    public var isJoinable: Bool { self == .live }
}

// MARK: - Role

/// What the **server** decided this account may do inside one room.
///
/// This is not a client-side opinion and must never be recomputed from a scope.
/// It arrives with the join response and it is the same fact the LiveKit token
/// encodes: a listener's token carries `canPublish: false`, so the media server
/// drops their audio whatever this app draws. Gating the microphone on this
/// value is therefore not belt-and-braces — it is the only way to avoid
/// rendering a control that cannot work.
///
/// An unrecognised role decodes as ``listener``, the least-privileged reading.
public enum RoomRole: String, Sendable, Hashable, Decodable, CaseIterable {
    /// Opened the room. Can speak, and can change everybody else's role.
    case host
    /// Invited to the stage. Can speak.
    case speaker
    /// Can hear everything and say nothing. **Needs no microphone.**
    case listener

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Not a `throw`, and not `.speaker`: an unknown role must fail closed.
        self = RoomRole(rawValue: raw) ?? .listener
    }

    /// Whether the token this role came with permits publishing audio.
    ///
    /// The single predicate the microphone affordance is gated on.
    public var canPublish: Bool { self != .listener }

    /// Whether this role may run the room.
    public var isHost: Bool { self == .host }

    /// Section heading in the participant list.
    public var sectionTitle: String {
        switch self {
        case .host: return L10n.t("rooms.role.section.host")
        case .speaker: return L10n.t("rooms.role.section.speakers")
        case .listener: return L10n.t("rooms.role.section.listening")
        }
    }

    /// One-word label under a participant's avatar.
    public var badgeTitle: String {
        switch self {
        case .host: return L10n.t("rooms.role.badge.host")
        case .speaker: return L10n.t("rooms.role.badge.speaker")
        case .listener: return L10n.t("rooms.role.badge.listener")
        }
    }
}

// MARK: - The room

/// One `RoomOut` — a voice room as the server describes it to this viewer.
///
/// Three fields are the whole feature and none of them are derived here.
///
/// **``canSpeak`` and ``speakRefusal`` are the server's answer**, computed per
/// request from the room's scope and this account's verified country. The client
/// renders ``speakRefusal`` verbatim and never re-derives the rule: the scope
/// vocabulary can grow server-side, and a client that guessed would eventually
/// tell somebody they may not speak in a room the server would happily let them
/// into — or worse, the reverse.
///
/// **The scope governs speaking, never listening.** There is no field for "may
/// this person enter", because everyone may. That asymmetry is the product.
///
/// **``isRemoved`` is per-room.** It is not a block, it is not account-level,
/// and no copy in this module may describe it as either.
public struct VoiceRoom: Identifiable, Equatable, Sendable, Decodable, Hashable {

    public let id: UUID
    /// What the host called it.
    public let title: String
    /// A topic id from the taxonomy, or `nil` for an untopiced room.
    public let topic: String?
    /// Who may **speak**. Everyone may listen.
    public let scope: PostScope
    /// `scope_country`, when the scope carries one.
    public let scopeCountry: String?
    /// `scope_region`, when the scope carries one.
    public let scopeRegion: String?
    /// Live, scheduled or ended.
    public let status: RoomStatus
    /// Who opened it.
    public let host: UserSummary
    /// How many people are on stage, server-counted.
    public let speakerCount: Int
    /// How many people are listening, server-counted.
    public let listenerCount: Int
    /// When a scheduled room is meant to start.
    public let scheduledFor: Date?
    /// When a live room actually started.
    public let startedAt: Date?
    public let createdAt: Date
    /// Whether **this viewer** may take the microphone. The server's answer.
    public let canSpeak: Bool
    /// Why not, in the server's own words. Rendered verbatim, never rewritten.
    public let speakRefusal: String?
    /// Whether this viewer opened the room.
    public let isHost: Bool
    /// Whether the host removed this viewer **from this room**. Not a block.
    public let isRemoved: Bool
    /// A closed room: only the host and the people they invited may enter.
    ///
    /// **The one thing about a room that governs listening.** Scope decides
    /// who speaks and never who hears; this decides who gets through the door
    /// at all, which is why it is its own flag with its own refusal rather
    /// than another scope value.
    public let isInviteOnly: Bool
    /// Whether this viewer holds an invitation. Always false for an open room —
    /// nobody is "invited" to a room anyone may enter.
    public let isInvited: Bool
    /// Whether this viewer may enter, decided server-side exactly as
    /// ``canSpeak`` is.
    public let canJoin: Bool
    /// Why not, in the server's own words. Rendered verbatim.
    public let joinRefusal: String?
    /// The other closed kind: the people the host follows may enter, and so
    /// may anyone invited by name.
    public let isFollowingOnly: Bool
    /// The group this room was opened for, when it was — the third closed
    /// kind. Only the host and the group's members ever see such a room.
    public let groupId: UUID?
    /// The host's own label for that group ("Family").
    public let groupName: String?
    /// This viewer's seat while they are in the room, or `nil` outside it.
    public let viewerRole: RoomRole?
    /// Whether this viewer's hand is up.
    public let handRaised: Bool
    /// How many hands are up — what the host's badge counts.
    public let handsCount: Int
    /// The room's topic is one this viewer said they are interested in.
    public let matchesInterests: Bool

    public init(
        id: UUID,
        title: String,
        topic: String? = nil,
        scope: PostScope = .international,
        scopeCountry: String? = nil,
        scopeRegion: String? = nil,
        status: RoomStatus = .live,
        host: UserSummary,
        speakerCount: Int = 1,
        listenerCount: Int = 0,
        scheduledFor: Date? = nil,
        startedAt: Date? = nil,
        createdAt: Date = Date(),
        canSpeak: Bool = true,
        speakRefusal: String? = nil,
        isHost: Bool = false,
        isRemoved: Bool = false,
        isInviteOnly: Bool = false,
        isInvited: Bool = false,
        canJoin: Bool = true,
        joinRefusal: String? = nil,
        isFollowingOnly: Bool = false,
        viewerRole: RoomRole? = nil,
        handRaised: Bool = false,
        handsCount: Int = 0,
        matchesInterests: Bool = false,
        groupId: UUID? = nil,
        groupName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.topic = (topic?.isEmpty == false) ? topic : nil
        self.scope = scope
        self.scopeCountry = CountryCode.normalised(scopeCountry)
        self.scopeRegion = (scopeRegion?.isEmpty == false) ? scopeRegion?.uppercased() : nil
        self.status = status
        self.host = host
        self.speakerCount = max(0, speakerCount)
        self.listenerCount = max(0, listenerCount)
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.canSpeak = canSpeak
        self.speakRefusal = (speakRefusal?.isEmpty == false) ? speakRefusal : nil
        self.isHost = isHost
        self.isRemoved = isRemoved
        self.isInviteOnly = isInviteOnly
        self.isInvited = isInvited
        self.canJoin = canJoin
        self.joinRefusal = (joinRefusal?.isEmpty == false) ? joinRefusal : nil
        self.isFollowingOnly = isFollowingOnly
        self.viewerRole = viewerRole
        self.handRaised = handRaised
        self.handsCount = max(0, handsCount)
        self.matchesInterests = matchesInterests
        self.groupId = groupId
        self.groupName = groupName
    }

    /// Explicit keys are required because ``init(from:)`` is custom, and the
    /// raw values are the *camel-cased* forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case id, title, topic, scope, scopeCountry, scopeRegion, status, host
        case speakerCount, listenerCount, scheduledFor, startedAt, createdAt
        case canSpeak, speakRefusal, isHost, isRemoved
        case isInviteOnly, isInvited, canJoin, joinRefusal
        case isFollowingOnly, viewerRole, handRaised, handsCount, matchesInterests
        case groupId, groupName
    }

    /// Tolerant decoder: one malformed optional must not blank a whole list.
    ///
    /// ``host`` and ``title`` are allowed to throw because a room with neither
    /// is not a room anybody could choose to enter. Everything else survives a
    /// missing or wrong-typed field — with the two permission flags failing
    /// **closed**: an absent `can_speak` reads as "no", because a microphone
    /// offered on a guess is a microphone the media server will mute.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .id)) ?? ""
            id = UUID(uuidString: raw) ?? UUID()
        }
        let decodedTitle = (try? container.decode(String.self, forKey: .title)) ?? ""
        guard !decodedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "a room with no title is not something anybody could choose to enter"
            )
        }
        title = decodedTitle
        let rawTopic = (try? container.decodeIfPresent(String.self, forKey: .topic)) ?? nil
        topic = (rawTopic?.isEmpty == false) ? rawTopic : nil
        scope = (try? container.decode(PostScope.self, forKey: .scope)) ?? .international
        scopeCountry = CountryCode.normalised(
            (try? container.decodeIfPresent(String.self, forKey: .scopeCountry)) ?? nil
        )
        let rawRegion = (try? container.decodeIfPresent(String.self, forKey: .scopeRegion)) ?? nil
        scopeRegion = (rawRegion?.isEmpty == false) ? rawRegion?.uppercased() : nil
        status = (try? container.decode(RoomStatus.self, forKey: .status)) ?? .unknown
        host = try container.decode(UserSummary.self, forKey: .host)
        speakerCount = max(0, (try? container.decode(Int.self, forKey: .speakerCount)) ?? 0)
        listenerCount = max(0, (try? container.decode(Int.self, forKey: .listenerCount)) ?? 0)
        scheduledFor = (try? container.decodeIfPresent(Date.self, forKey: .scheduledFor)) ?? nil
        startedAt = (try? container.decodeIfPresent(Date.self, forKey: .startedAt)) ?? nil
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        // Fails closed. See the doc comment.
        canSpeak = (try? container.decode(Bool.self, forKey: .canSpeak)) ?? false
        let refusal = (try? container.decodeIfPresent(String.self, forKey: .speakRefusal)) ?? nil
        speakRefusal = (refusal?.isEmpty == false) ? refusal : nil
        isHost = (try? container.decode(Bool.self, forKey: .isHost)) ?? false
        isRemoved = (try? container.decode(Bool.self, forKey: .isRemoved)) ?? false
        isInviteOnly = (try? container.decode(Bool.self, forKey: .isInviteOnly)) ?? false
        isInvited = (try? container.decode(Bool.self, forKey: .isInvited)) ?? false
        // Fails **open**, unlike `canSpeak`. A server without this field has no
        // closed rooms, so absent means "anyone may enter" — and the join call
        // is the real gate either way. Failing closed here would hide the Join
        // button on every ordinary room the moment a field went missing.
        canJoin = (try? container.decode(Bool.self, forKey: .canJoin)) ?? true
        let joinWhy = (try? container.decodeIfPresent(String.self, forKey: .joinRefusal)) ?? nil
        joinRefusal = (joinWhy?.isEmpty == false) ? joinWhy : nil
        isFollowingOnly = (try? container.decode(Bool.self, forKey: .isFollowingOnly)) ?? false
        viewerRole = (try? container.decodeIfPresent(RoomRole.self, forKey: .viewerRole)) ?? nil
        handRaised = (try? container.decode(Bool.self, forKey: .handRaised)) ?? false
        handsCount = max(0, (try? container.decode(Int.self, forKey: .handsCount)) ?? 0)
        matchesInterests = (try? container.decode(Bool.self, forKey: .matchesInterests)) ?? false
        groupId = (try? container.decodeIfPresent(UUID.self, forKey: .groupId)) ?? nil
        let groupLabel = (try? container.decodeIfPresent(String.self, forKey: .groupName)) ?? nil
        groupName = (groupLabel?.isEmpty == false) ? groupLabel : nil
    }

    /// Any closed kind. Everything about the door keys off this.
    public var isClosed: Bool { isInviteOnly || isFollowingOnly || groupId != nil }

    /// A room opened for one of the host's groups.
    public var isGroupOnly: Bool { groupId != nil }

    // MARK: Derived

    /// The scope chip, rendered exactly as a post's is — but saying *speak*,
    /// because that is what a room's scope governs.
    public var scopePresentation: ScopePresentation {
        ScopePresentation.make(
            scope: scope,
            country: scopeCountry,
            region: scopeRegion,
            noun: "room",
            verb: "speak"
        )
    }

    /// How many people are in the room altogether.
    public var participantCount: Int { speakerCount + listenerCount }

    /// The room's topic as a readable label, or `nil` when it has none.
    ///
    /// Derived from the id the same way ``TopicOption`` does it, because the
    /// contract does not promise stable labels.
    public var topicLabel: String? {
        guard let topic, !topic.isEmpty else { return nil }
        return TopicOption.makeLabel(from: topic)
    }

    /// `true` when the viewer may enter **right now**: the server allows it,
    /// the room is live, and they were not removed.
    public var isEnterable: Bool { canJoin && status.isJoinable && !isRemoved }

    /// The sentence explaining why the door is shut, or `nil` when it is open.
    ///
    /// Removal outranks invite-only: "the host removed you" is a decision
    /// about this person and says more than "invite only" does.
    public var joinRefusalMessage: String? {
        if isRemoved { return RoomCopy.removedFromRoom }
        guard !canJoin else { return nil }
        if let joinRefusal { return joinRefusal }
        if groupId != nil { return RoomCopy.groupOnlyRefusal }
        return isFollowingOnly ? RoomCopy.followingOnlyRefusal : RoomCopy.inviteOnlyRefusal
    }

    /// `true` when the viewer may take the microphone **right now**.
    ///
    /// Requires the server's permission *and* a room that is still live: a
    /// scheduled room has nothing to speak into yet, and an ended one never
    /// will again.
    public var isSpeakable: Bool { canSpeak && status.isJoinable && !isRemoved }

    /// The sentence explaining why the microphone is not on offer, or `nil`
    /// when it is.
    ///
    /// The server's ``speakRefusal`` wins whenever it sent one — that is the
    /// authoritative sentence and it is shown **verbatim**. The fallbacks below
    /// only cover the cases where there is nothing to render.
    public var speakRefusalMessage: String? {
        if isRemoved { return RoomCopy.removedFromRoom }
        guard !canSpeak else {
            return status.isJoinable ? nil : RoomCopy.notLiveYet(self)
        }
        if let speakRefusal { return speakRefusal }
        return RoomCopy.speakRefusalFallback
    }

    /// The count line under the title, e.g. `"3 speaking · 41 listening"`.
    public var attendanceSummary: String {
        RoomCopy.attendance(speakers: speakerCount, listeners: listenerCount)
    }

    /// The whole card as one line for VoiceOver.
    public var accessibilityDescription: String {
        var parts = [title, scopePresentation.accessibilityLabel]
        if let topicLabel { parts.append(L10n.t("rooms.card.a11y.topic", topicLabel)) }
        parts.append(L10n.t("rooms.card.a11y.hostedBy", host.displayName))
        switch status {
        case .live:
            parts.append(L10n.t("rooms.card.a11y.liveNow", attendanceSummary))
        case .scheduled:
            parts.append(RoomCopy.scheduledFor(scheduledFor))
        case .ended, .unknown:
            parts.append(L10n.t("rooms.card.a11y.ended"))
        }
        if isRemoved { parts.append(RoomCopy.removedFromRoom) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Wire wrappers

/// What `GET /rooms` and `GET /search/rooms` answer: `{"rooms": [...]}`.
public struct VoiceRoomList: Equatable, Sendable, Decodable {

    public let rooms: [VoiceRoom]

    public init(rooms: [VoiceRoom]) {
        self.rooms = rooms
    }

    private enum CodingKeys: String, CodingKey { case rooms }

    /// Row by row, so a single unreadable room costs that room and not the
    /// page. A plain `[VoiceRoom]` decode is all-or-nothing: one row with no
    /// host would empty a list that has a dozen good ones in it, and the screen
    /// would say "nothing live right now" — a lie the user cannot see through.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rooms = ((try? container.decode([FailableRoom].self, forKey: .rooms)) ?? [])
            .compactMap(\.value)
    }

    public static let empty = VoiceRoomList(rooms: [])
}

/// One array element that decodes to `nil` instead of throwing.
private struct FailableRoom: Decodable {
    let value: VoiceRoom?

    init(from decoder: Decoder) throws {
        value = try? VoiceRoom(from: decoder)
    }
}

/// One row of `GET /rooms/{id}/participants`.
public struct RoomParticipant: Identifiable, Equatable, Sendable, Decodable, Hashable {

    /// What the server says this person may do. Not a guess.
    public let role: RoomRole
    /// Who they are — the *same* ``UserSummary`` the feed renders next to a
    /// post, so a checkmark cannot disagree with itself across two screens.
    public let user: UserSummary
    /// When they arrived, when the server said.
    public let joinedAt: Date?
    /// When they raised a hand, or `nil`. The timestamp is the queue.
    public let handRaisedAt: Date?

    /// Identity is the account: one person appears once, whatever their role.
    public var id: UUID { user.id }

    public init(role: RoomRole, user: UserSummary, joinedAt: Date? = nil, handRaisedAt: Date? = nil) {
        self.role = role
        self.user = user
        self.joinedAt = joinedAt
        self.handRaisedAt = handRaisedAt
    }

    /// A listener asking for the microphone.
    public var hasHandRaised: Bool { handRaisedAt != nil && role == .listener }

    private enum CodingKeys: String, CodingKey { case role, user, joinedAt, handRaisedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? container.decode(RoomRole.self, forKey: .role)) ?? .listener
        user = try container.decode(UserSummary.self, forKey: .user)
        joinedAt = (try? container.decodeIfPresent(Date.self, forKey: .joinedAt)) ?? nil
        handRaisedAt = (try? container.decodeIfPresent(Date.self, forKey: .handRaisedAt)) ?? nil
    }
}

/// What `GET /rooms/{id}/participants` answers.
public struct RoomParticipantList: Equatable, Sendable, Decodable {

    public let participants: [RoomParticipant]

    public init(participants: [RoomParticipant]) {
        self.participants = participants
    }

    private enum CodingKeys: String, CodingKey { case participants }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        participants = ((try? container.decode([FailableParticipant].self, forKey: .participants)) ?? [])
            .compactMap(\.value)
    }

    public static let empty = RoomParticipantList(participants: [])

    /// The people who may speak, host first.
    public var stage: [RoomParticipant] {
        participants.filter { $0.role.canPublish }
            .sorted { lhs, rhs in
                if lhs.role.isHost != rhs.role.isHost { return lhs.role.isHost }
                return lhs.user.displayName.localizedCaseInsensitiveCompare(rhs.user.displayName) == .orderedAscending
            }
    }

    /// The people who are only listening — hands first, oldest hand first,
    /// then by arrival.
    public var audience: [RoomParticipant] {
        participants.filter { !$0.role.canPublish }
            .sorted { lhs, rhs in
                switch (lhs.handRaisedAt, rhs.handRaisedAt) {
                case let (l?, r?): return l < r
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return (lhs.joinedAt ?? .distantPast) < (rhs.joinedAt ?? .distantPast)
                }
            }
    }

    /// The queue the host decides from: listeners with a hand up, oldest first.
    public var hands: [RoomParticipant] { audience.filter(\.hasHandRaised) }

    /// The seat the roster gives one account, if it lists them.
    public func role(of userId: UUID) -> RoomRole? {
        participants.first { $0.user.id == userId }?.role
    }
}

private struct FailableParticipant: Decodable {
    let value: RoomParticipant?

    init(from decoder: Decoder) throws {
        value = try? RoomParticipant(from: decoder)
    }
}

/// What `POST /rooms/{id}/join` answers.
///
/// The ``token`` is the enforcement. It encodes `canPublish` from ``role``, and
/// the media server honours the token rather than anything this app believes —
/// which is why a promotion is followed by a **re-join** rather than by
/// flipping a boolean: the grant travels with the role, in a new token.
public struct RoomJoin: Equatable, Hashable, Sendable, Decodable {

    /// The room as it stands at the moment of joining.
    public let room: VoiceRoom
    /// The media server's websocket URL, e.g. `wss://sila.gmai.sa/rtc`.
    public let url: String
    /// The LiveKit access token. Never logged, never rendered.
    public let token: String
    /// What this token permits.
    public let role: RoomRole

    public init(room: VoiceRoom, url: String, token: String, role: RoomRole) {
        self.room = room
        self.url = url
        self.token = token
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case room, url, token, role }

    /// Deliberately **not** tolerant. A join with no token or no URL is not a
    /// join, and pretending otherwise would put a room screen on the display
    /// with silence behind it and no explanation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        room = try container.decode(VoiceRoom.self, forKey: .room)
        url = try container.decode(String.self, forKey: .url)
        token = try container.decode(String.self, forKey: .token)
        role = (try? container.decode(RoomRole.self, forKey: .role)) ?? .listener
    }

    /// Whether this token permits publishing audio.
    public var canPublish: Bool { role.canPublish }
}

// MARK: - Creating

/// Who gets through the door. Scope decides who may *speak*; this decides who
/// may *hear*, which is why it is its own choice and not another scope value.
public enum RoomAccess: String, CaseIterable, Identifiable, Sendable, Equatable {
    /// Anyone. The default, and the reason scope only ever governed speaking.
    case open
    /// The people the host follows, plus anyone invited by name.
    case following
    /// Only the people the host names.
    case inviteOnly
    /// The people in one of the host's groups, plus anyone invited by name.
    case group

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .open: return L10n.t("rooms.access.open.title")
        case .following: return L10n.t("rooms.access.following.title")
        case .inviteOnly: return L10n.t("rooms.access.inviteOnly.title")
        case .group: return L10n.t("rooms.access.group.title")
        }
    }

    public var explanation: String {
        switch self {
        case .open: return L10n.t("rooms.create.open.explanation")
        case .following: return L10n.t("rooms.access.following.explanation")
        case .inviteOnly: return L10n.t("rooms.create.inviteOnly.explanation")
        case .group: return L10n.t("rooms.access.group.explanation")
        }
    }

    public var icon: String {
        switch self {
        case .open: return "globe"
        case .following: return "person.2.fill"
        case .inviteOnly: return "lock.fill"
        case .group: return "person.3.fill"
        }
    }

    /// Whether a guest list applies — both closed kinds take invitations.
    public var isClosed: Bool { self != .open }

    /// The access a room was opened with.
    public static func of(_ room: VoiceRoom) -> RoomAccess {
        if room.groupId != nil { return .group }
        if room.isInviteOnly { return .inviteOnly }
        if room.isFollowingOnly { return .following }
        return .open
    }
}

/// The body of `POST /rooms`.
///
/// Built from a ``ComposeScope`` rather than three loose strings, so the room
/// picker and the post composer cannot drift apart about what "country" means.
public struct CreateRoomRequest: Encodable, Equatable, Sendable {

    public let title: String
    public let topic: String?
    public let scope: String
    public let scopeCountry: String?
    public let scopeRegion: String?
    public let scheduledFor: Date?
    public let maxSpeakers: Int?
    /// Whether only invited people may enter.
    public let isInviteOnly: Bool
    /// Whether the people the host follows may enter (plus invitees).
    public let isFollowingOnly: Bool
    /// Handles invited as the room opens, so a closed room is one call.
    /// Always empty for an open room.
    public let inviteHandles: [String]
    /// One of the host's groups, for a room opened to its members.
    public let groupId: UUID?

    /// - Parameters:
    ///   - title: What to call it. Trimmed.
    ///   - topic: A topic id from the taxonomy, or `nil`.
    ///   - scope: Who may speak.
    ///   - scheduledFor: A future start time, or `nil` to open it now.
    ///   - maxSpeakers: Stage size, or `nil` for the server's default.
    ///   - isInviteOnly: Close the room to everybody but its guests.
    ///   - isFollowingOnly: Close the room to everybody but the people the
    ///     host follows, and its guests.
    ///   - inviteHandles: Who to invite. Dropped for an open room, because
    ///     the server refuses invitations to one rather than quietly
    ///     ignoring them.
    public init(
        title: String,
        topic: String? = nil,
        scope: ComposeScope,
        scheduledFor: Date? = nil,
        maxSpeakers: Int? = nil,
        isInviteOnly: Bool = false,
        isFollowingOnly: Bool = false,
        inviteHandles: [String] = [],
        groupId: UUID? = nil
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.topic = (topic?.isEmpty == false) ? topic : nil
        self.scope = scope.wireValue
        self.scopeCountry = scope.scopeCountry
        self.scopeRegion = scope.scopeRegion
        self.scheduledFor = scheduledFor
        self.maxSpeakers = maxSpeakers
        // One door: a group room is neither of the other two closed kinds.
        self.groupId = groupId
        self.isInviteOnly = isInviteOnly && groupId == nil
        self.isFollowingOnly = isFollowingOnly && !isInviteOnly && groupId == nil
        let closed = isInviteOnly || isFollowingOnly || groupId != nil
        self.inviteHandles = closed ? RoomInviteHandles.clean(inviteHandles) : []
    }

    /// The same, from an access choice.
    public init(
        title: String,
        topic: String? = nil,
        scope: ComposeScope,
        scheduledFor: Date? = nil,
        maxSpeakers: Int? = nil,
        access: RoomAccess,
        inviteHandles: [String] = [],
        groupId: UUID? = nil
    ) {
        self.init(
            title: title, topic: topic, scope: scope, scheduledFor: scheduledFor, maxSpeakers: maxSpeakers,
            isInviteOnly: access == .inviteOnly, isFollowingOnly: access == .following,
            inviteHandles: inviteHandles,
            groupId: access == .group ? groupId : nil
        )
    }

    /// Optional fields are omitted rather than sent as `null`: the contract
    /// treats an absent `scheduled_for` as "start now", and a `null` is a
    /// different sentence for a server to have to interpret.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(topic, forKey: .topic)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(scopeCountry, forKey: .scopeCountry)
        try container.encodeIfPresent(scopeRegion, forKey: .scopeRegion)
        try container.encodeIfPresent(scheduledFor, forKey: .scheduledFor)
        try container.encodeIfPresent(maxSpeakers, forKey: .maxSpeakers)
        // Sent only when true, because absence has always meant "open".
        if isInviteOnly {
            try container.encode(true, forKey: .isInviteOnly)
        }
        if isFollowingOnly {
            try container.encode(true, forKey: .isFollowingOnly)
        }
        try container.encodeIfPresent(groupId, forKey: .groupId)
        if (isInviteOnly || isFollowingOnly || groupId != nil) && !inviteHandles.isEmpty {
            try container.encode(inviteHandles, forKey: .inviteHandles)
        }
    }

    /// The keys are camel-cased; the encoder converts them to `snake_case`.
    private enum CodingKeys: String, CodingKey {
        case title, topic, scope, scopeCountry, scopeRegion, scheduledFor, maxSpeakers
        case isInviteOnly, isFollowingOnly, inviteHandles, groupId
    }
}

/// The `{"handle": "…"}` body shared by the three host-only stage calls.
struct RoomHandleRequest: Encodable, Equatable, Sendable {
    let handle: String
}

// MARK: - Constants

/// Numbers and limits the rooms surface runs on.
public enum RoomConstants {

    /// Page size for `GET /rooms`.
    public static let defaultLimit = 30
    /// The server's ceiling. Anything above answers 422.
    public static let maximumLimit = 50
    /// Page size for `GET /search/rooms`.
    public static let searchLimit = 20
    /// Shortest query the room search will send.
    public static let minimumQueryLength = 2
    /// Seconds to wait after a keystroke before searching.
    public static let searchDebounce: TimeInterval = 0.35
    /// Longest room title the field accepts.
    public static let maximumTitleLength = 120
    /// How often a live room re-reads its participant list.
    public static let participantPollInterval: TimeInterval = 8
    /// Stage sizes the create sheet offers.
    public static let speakerLimits = [4, 8, 12, 20]
    /// The stage size a new room opens with.
    public static let defaultSpeakerLimit = 8

    /// `true` when a query is long enough to be worth a request.
    public static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQueryLength
    }
}

// MARK: - Copy

/// Every sentence the rooms surface says.
///
/// Pure functions, kept out of the views so the four rules that matter can be
/// asserted directly rather than eyeballed in a screenshot:
///
/// 1. A room is **never recorded**, and the UI says so where somebody can read
///    it before they speak — not in a settings screen nobody opens.
/// 2. Being removed from a room is **not a block**, and no sentence here may
///    imply that it is, or that it followed the person anywhere else.
/// 3. Listening needs **no microphone**, so nothing here asks for one or
///    apologises for its absence.
/// 4. A refusal to speak is the **server's sentence**, shown verbatim. The
///    fallbacks below exist only for when the server sent none.
/// Tidying for the handles a host types into the invite field.
///
/// A handle is `[a-z0-9_]{3,20}`; people type `@aziz`, `Aziz`, or paste a
/// comma-separated list. Those all mean the same person, and the server
/// answers `user_not_found` for anything that does not — so this normalises
/// what was typed and never invents a handle that was not.
public enum RoomInviteHandles {

    /// The most handles one call may carry. The server's own cap.
    public static let maximum = 50

    /// Splits on commas, spaces and newlines; drops a leading `@`;
    /// lower-cases; de-duplicates, keeping the order they were typed.
    public static func clean(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            for piece in entry.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }) {
                let handle = piece.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                    .lowercased()
                guard !handle.isEmpty, !seen.contains(handle) else { continue }
                seen.insert(handle)
                out.append(handle)
                if out.count == maximum { return out }
            }
        }
        return out
    }

    /// The same, from one typed string.
    public static func clean(_ raw: String) -> [String] { clean([raw]) }
}

/// The body of `POST /rooms/{id}/invites`.
struct RoomInviteBody: Encodable {
    let handles: [String]
}

/// What the invite endpoints answer: `{"room_id": …, "invited": [...]}`.
public struct RoomInviteList: Equatable, Sendable, Decodable {

    public let roomId: UUID?
    /// Everybody holding an invitation, oldest first.
    public let invited: [UserSummary]

    public init(roomId: UUID? = nil, invited: [UserSummary]) {
        self.roomId = roomId
        self.invited = invited
    }

    private enum CodingKeys: String, CodingKey { case roomId, invited }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomId = (try? container.decodeIfPresent(UUID.self, forKey: .roomId)) ?? nil
        invited = (try? container.decode([UserSummary].self, forKey: .invited)) ?? []
    }
}

public enum RoomCopy {

    // MARK: Closed rooms

    /// The fallback refusal, for when the server sent none.
    public static var inviteOnlyRefusal: String { L10n.t("rooms.inviteOnly.refusal") }

    /// The chip on a closed room's card.
    public static var inviteOnlyBadge: String { L10n.t("rooms.inviteOnly.badge") }

    /// The fallback refusal for a following-only room, for when the server sent none.
    public static var followingOnlyRefusal: String { L10n.t("rooms.followingOnly.refusal") }

    /// The chip on a following-only room's card.
    public static var followingOnlyBadge: String { L10n.t("rooms.followingOnly.badge") }

    /// The fallback refusal for a group room, for when the server sent none.
    public static var groupOnlyRefusal: String { L10n.t("rooms.groupOnly.refusal") }

    /// The chip on a group room's card: the host's own label for the group.
    public static func groupBadge(_ name: String?) -> String {
        name.map { L10n.t("rooms.groupOnly.badge", $0) } ?? L10n.t("rooms.access.group.title")
    }

    // MARK: Hands

    public static var raiseHand: String { L10n.t("rooms.hand.raise") }
    public static var lowerHand: String { L10n.t("rooms.hand.lower") }
    public static var raiseHandHint: String { L10n.t("rooms.hand.raise.hint") }
    public static var lowerHandHint: String { L10n.t("rooms.hand.lower.hint") }
    /// What the person is told once their hand is up: the host decides.
    public static var handRaised: String { L10n.t("rooms.hand.raised") }
    public static var handLowered: String { L10n.t("rooms.hand.lowered") }
    public static var handsHeader: String { L10n.t("rooms.live.hands.header") }
    public static var handsEmpty: String { L10n.t("rooms.live.hands.empty") }
    public static var approveHand: String { L10n.t("rooms.host.approveHand") }
    public static var dismissHand: String { L10n.t("rooms.host.dismissHand") }
    public static func handDismissed(_ name: String) -> String { L10n.t("rooms.host.handDismissedToast", name) }

    // MARK: Muting

    public static var muteSpeaker: String { L10n.t("rooms.host.mute") }
    public static func muted(_ name: String) -> String { L10n.t("rooms.host.mutedToast", name) }
    /// What a speaker is told when the host muted them. Says they keep the
    /// seat, because a mute and a demotion feel identical until somebody says.
    public static var youWereMuted: String { L10n.t("rooms.youWereMuted") }

    // MARK: Readmitting

    public static func readmit(_ name: String) -> String { L10n.t("rooms.host.readmit", name) }
    public static func readmitted(_ name: String) -> String { L10n.t("rooms.host.readmittedToast", name) }

    // MARK: Joining

    /// The header while the room is being joined and the media connected.
    public static var joining: String { L10n.t("rooms.join.joining") }

    /// The line under the access picker: the door governs hearing, the scope
    /// above it governs speaking, and the two must not be confused.
    public static func everyoneCanListenNote(_ access: RoomAccess) -> String {
        access == .open ? L10n.t("rooms.create.everyoneCanListen") : L10n.t("rooms.create.closed.note")
    }
    /// The heading over a door that did not open.
    public static var cannotEnterTitle: String { L10n.t("rooms.join.cannotEnter.title") }

    // MARK: The promise

    /// The line every room screen carries.
    ///
    /// Present on the in-room screen itself rather than behind an info button:
    /// the moment somebody needs to know a room is not recorded is the moment
    /// before they say something.
    ///
    /// Computed rather than stored: a `static let` is evaluated once, on first
    /// touch, and would freeze whichever language happened to be active then.
    /// Every member of this enum is computed for that reason.
    public static var neverRecorded: String { L10n.t("rooms.copy.neverRecorded") }

    /// The short form, for a chip.
    public static var neverRecordedShort: String { L10n.t("rooms.copy.neverRecordedShort") }

    // MARK: Listening

    /// The heading of the listener state.
    public static var listeningTitle: String { L10n.t("rooms.listening.title") }

    /// What listening means, said without apology.
    ///
    /// It names the fact that no microphone is involved, which is the reason
    /// this app never asks a listener for permission to use one.
    public static var listeningSubtitle: String { L10n.t("rooms.listening.subtitle") }

    /// Shown when the server refused speaking but sent no sentence of its own.
    public static var speakRefusalFallback: String { L10n.t("rooms.speak.refusalFallback") }

    /// The refusal for a room that is not live yet — or not any more.
    public static func notLiveYet(_ room: VoiceRoom) -> String {
        switch room.status {
        case .scheduled:
            return L10n.t("rooms.notLiveYet.scheduled", scheduledFor(room.scheduledFor))
        case .ended, .unknown:
            return roomEnded
        case .live:
            return ""
        }
    }

    // MARK: Removal — *not* a block

    /// What being removed means. **Deliberately not the word "block".**
    ///
    /// A removal is one host's decision about one room. It does not hide
    /// anybody's posts, it does not sever a follow, and it does not travel to
    /// the next room — all of which a block does. Calling it a block would tell
    /// somebody they had been punished far more broadly than they had. The
    /// Arabic says إخراج / أخرجك from *this room* and never حظر.
    public static var removedFromRoom: String { L10n.t("rooms.removed.body") }

    /// The title above it.
    public static var removedTitle: String { L10n.t("rooms.removed.title") }

    /// The toast when a host removes somebody.
    /// - Parameter name: Who was removed.
    public static func removed(_ name: String) -> String {
        L10n.t("rooms.removed.toast", name)
    }

    // MARK: Ending

    /// A room that is over.
    public static var roomEnded: String { L10n.t("rooms.ended.body") }

    /// The confirmation in front of ending a room.
    public static var endRoomWarning: String { L10n.t("rooms.end.warning") }

    // MARK: Attendance

    /// `"3 speaking · 41 listening"`.
    ///
    /// Both halves are plurals rather than an `== 1` ternary: Arabic has six
    /// categories and a ternary gets four of them wrong. The `·` separator is
    /// the same in both languages.
    public static func attendance(speakers: Int, listeners: Int) -> String {
        let speaking = L10n.plural("rooms.attendance.speaking", speakers)
        let listening = L10n.plural("rooms.attendance.listening", listeners)
        return "\(speaking) · \(listening)"
    }

    /// When a scheduled room starts, in words.
    public static func scheduledFor(_ date: Date?) -> String {
        guard let date else { return L10n.t("rooms.scheduled.noStartTime") }
        if date.timeIntervalSinceNow <= 0 { return L10n.t("rooms.scheduled.dueToStart") }
        return L10n.t("rooms.scheduled.starts", RelativeTime.accessible(date))
    }

    // MARK: Empty states

    public static var emptyLiveTitle: String { L10n.t("rooms.empty.live.title") }

    public static var emptyLiveSubtitle: String { L10n.t("rooms.empty.live.subtitle") }

    public static var emptyScheduledTitle: String { L10n.t("rooms.empty.scheduled.title") }

    public static var emptySearchTitle: String { L10n.t("rooms.empty.search.title") }

    /// The query sits inside the quote marks, so `String(format:)` can isolate
    /// an Arabic query typed into an English UI (and the reverse) without the
    /// closing quote sliding to the wrong end of the sentence.
    public static func emptySearchSubtitle(_ query: String) -> String {
        L10n.t("rooms.empty.search.subtitle", query)
    }

    public static var searchTooShortTitle: String { L10n.t("rooms.search.tooShort.title") }

    /// Counts characters, so it is a plural — and computed, so a language
    /// change at runtime reaches it.
    public static var searchTooShortSubtitle: String {
        L10n.plural("rooms.search.tooShort.subtitle", RoomConstants.minimumQueryLength)
    }

    // MARK: The microphone

    /// The label on the control that takes the microphone.
    public static var takeMic: String { L10n.t("rooms.mic.take") }
    /// And the one that puts it down.
    public static var dropMic: String { L10n.t("rooms.mic.drop") }

    /// What unmuting actually does, including the part about permission.
    ///
    /// Says the permission prompt is coming *before* it appears, because a
    /// system dialog that arrives unannounced is one people deny by reflex.
    public static var takeMicHint: String { L10n.t("rooms.mic.takeHint") }

    public static var dropMicHint: String { L10n.t("rooms.mic.dropHint") }

    /// Shown when the person denied microphone access at the system level.
    ///
    /// The Settings path is spelled the way iOS itself spells it in each
    /// language; the `›` separators are neutral characters and mirror on their
    /// own inside a right-to-left paragraph.
    public static var microphoneDenied: String { L10n.t("rooms.mic.denied") }

    // MARK: Host controls

    public static var inviteToMic: String { L10n.t("rooms.host.inviteToMic") }

    public static func invited(_ name: String) -> String {
        L10n.t("rooms.host.invitedToast", name)
    }

    public static var takeMicBack: String { L10n.t("rooms.host.takeMicBack") }

    public static func demoted(_ name: String) -> String {
        L10n.t("rooms.host.demotedToast", name)
    }

    /// What the demoted person is told. Says plainly that they are still here,
    /// because being moved off a stage and being thrown out of a room feel
    /// identical from the inside if nobody says which happened.
    public static var youWereDemoted: String { L10n.t("rooms.youWereDemoted") }

    /// What the promoted person is told.
    public static var youCanSpeakNow: String { L10n.t("rooms.youCanSpeakNow") }

    /// The reason a host cannot demote themselves.
    public static var cannotDemoteHost: String { L10n.t("rooms.host.cannotDemoteHost") }

    /// The stage is full.
    public static var stageFull: String { L10n.t("rooms.host.stageFull") }

    // MARK: Creating

    public static var createTitle: String { L10n.t("rooms.create.title") }

    /// The sentence at the top of the create sheet.
    ///
    /// States the asymmetry once, plainly, because it is the thing people get
    /// wrong: the audience picker is about *speaking*, and every room is open
    /// to every listener regardless of what is chosen there.
    public static var createExplanation: String { L10n.t("rooms.create.explanation") }

    public static var titlePlaceholder: String { L10n.t("rooms.create.titlePlaceholder") }

    public static var titleMissing: String { L10n.t("rooms.create.titleMissing") }

    /// - Parameter count: The length of the title that was typed. The sentence
    ///   counts the *overshoot*, which is what the plural agrees with.
    public static func titleTooLong(_ count: Int) -> String {
        L10n.plural("rooms.create.titleTooLong", count - RoomConstants.maximumTitleLength)
    }

    /// The scheduling row's explanation.
    public static var scheduleExplanation: String { L10n.t("rooms.create.scheduleExplanation") }

    // MARK: Joining

    /// The unverified refusal, which is about posting rights, not about hearing.
    public static var unverifiedCannotOpen: String { L10n.t("rooms.join.unverifiedCannotOpen") }

    /// What a listener sees while the media connection is being made.
    public static var connecting: String { L10n.t("rooms.connection.connecting") }

    /// A connection that dropped and is coming back.
    public static var reconnecting: String { L10n.t("rooms.connection.reconnecting") }

    /// What "Leave" does.
    public static var leaveHint: String { L10n.t("rooms.leave.hint") }
}

// MARK: - Groups

/// A private list of people the viewer keeps — "Family", "Work".
///
/// The owner's alone: members are never told, nobody else can read it, and
/// its one use so far is a room's door (``RoomAccess/group``).
public struct UserGroup: Identifiable, Hashable, Sendable, Decodable {

    public let id: UUID
    public let name: String
    public let memberCount: Int
    /// Everybody in it, oldest first.
    public let members: [UserSummary]

    public init(id: UUID, name: String, memberCount: Int? = nil, members: [UserSummary] = []) {
        self.id = id
        self.name = name
        self.memberCount = memberCount ?? members.count
        self.members = members
    }

    private enum CodingKeys: String, CodingKey { case id, name, memberCount, members }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let people = (try? container.decode([UserSummary].self, forKey: .members)) ?? []
        members = people
        memberCount = max(people.count, (try? container.decode(Int.self, forKey: .memberCount)) ?? 0)
    }
}

/// `GET /me/groups` answers `{"groups": [...]}`.
struct UserGroupList: Decodable {
    let groups: [UserGroup]

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let rows = try? single.decode([UserGroup].self) {
            groups = rows
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = (try? container.decode([UserGroup].self, forKey: .groups)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case groups }
}

struct GroupCreateBody: Encodable {
    let name: String
    let handles: [String]
}

struct GroupRenameBody: Encodable {
    let name: String
}

