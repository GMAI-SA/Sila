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
        case .host: return "Host"
        case .speaker: return "Speakers"
        case .listener: return "Listening"
        }
    }

    /// One-word label under a participant's avatar.
    public var badgeTitle: String {
        switch self {
        case .host: return "Host"
        case .speaker: return "Speaker"
        case .listener: return "Listener"
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
        isRemoved: Bool = false
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
    }

    /// Explicit keys are required because ``init(from:)`` is custom, and the
    /// raw values are the *camel-cased* forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case id, title, topic, scope, scopeCountry, scopeRegion, status, host
        case speakerCount, listenerCount, scheduledFor, startedAt, createdAt
        case canSpeak, speakRefusal, isHost, isRemoved
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
    }

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
        if let topicLabel { parts.append("Topic: \(topicLabel)") }
        parts.append("Hosted by \(host.displayName)")
        switch status {
        case .live:
            parts.append("Live now. " + attendanceSummary)
        case .scheduled:
            parts.append(RoomCopy.scheduledFor(scheduledFor))
        case .ended, .unknown:
            parts.append("This room has ended.")
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

    /// Identity is the account: one person appears once, whatever their role.
    public var id: UUID { user.id }

    public init(role: RoomRole, user: UserSummary, joinedAt: Date? = nil) {
        self.role = role
        self.user = user
        self.joinedAt = joinedAt
    }

    private enum CodingKeys: String, CodingKey { case role, user, joinedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? container.decode(RoomRole.self, forKey: .role)) ?? .listener
        user = try container.decode(UserSummary.self, forKey: .user)
        joinedAt = (try? container.decodeIfPresent(Date.self, forKey: .joinedAt)) ?? nil
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

    /// The people who are only listening.
    public var audience: [RoomParticipant] {
        participants.filter { !$0.role.canPublish }
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

    /// - Parameters:
    ///   - title: What to call it. Trimmed.
    ///   - topic: A topic id from the taxonomy, or `nil`.
    ///   - scope: Who may speak.
    ///   - scheduledFor: A future start time, or `nil` to open it now.
    ///   - maxSpeakers: Stage size, or `nil` for the server's default.
    public init(
        title: String,
        topic: String? = nil,
        scope: ComposeScope,
        scheduledFor: Date? = nil,
        maxSpeakers: Int? = nil
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.topic = (topic?.isEmpty == false) ? topic : nil
        self.scope = scope.wireValue
        self.scopeCountry = scope.scopeCountry
        self.scopeRegion = scope.scopeRegion
        self.scheduledFor = scheduledFor
        self.maxSpeakers = maxSpeakers
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
    }

    /// The keys are camel-cased; the encoder converts them to `snake_case`.
    private enum CodingKeys: String, CodingKey {
        case title, topic, scope, scopeCountry, scopeRegion, scheduledFor, maxSpeakers
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
public enum RoomCopy {

    // MARK: The promise

    /// The line every room screen carries.
    ///
    /// Present on the in-room screen itself rather than behind an info button:
    /// the moment somebody needs to know a room is not recorded is the moment
    /// before they say something.
    public static let neverRecorded =
        "Rooms are never recorded. There is no replay, no transcript and no file — "
        + "when this room ends, what was said in it is gone."

    /// The short form, for a chip.
    public static let neverRecordedShort = "Not recorded"

    // MARK: Listening

    /// The heading of the listener state.
    public static let listeningTitle = "You're listening"

    /// What listening means, said without apology.
    ///
    /// It names the fact that no microphone is involved, which is the reason
    /// this app never asks a listener for permission to use one.
    public static let listeningSubtitle =
        "You can hear everything. Your microphone is not in use and Sila hasn't asked for it."

    /// Shown when the server refused speaking but sent no sentence of its own.
    public static let speakRefusalFallback =
        "You can listen to this room, but you can't speak in it."

    /// The refusal for a room that is not live yet — or not any more.
    public static func notLiveYet(_ room: VoiceRoom) -> String {
        switch room.status {
        case .scheduled:
            return "This room hasn't started. \(scheduledFor(room.scheduledFor))"
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
    /// somebody they had been punished far more broadly than they had.
    public static let removedFromRoom =
        "The host removed you from this room. That applies to this room only — "
        + "it isn't a block, nothing about your account has changed, and you can "
        + "still open or join any other room."

    /// The title above it.
    public static let removedTitle = "You were removed from this room"

    /// The toast when a host removes somebody.
    /// - Parameter name: Who was removed.
    public static func removed(_ name: String) -> String {
        "\(name) was removed from this room. They can still join other rooms."
    }

    // MARK: Ending

    /// A room that is over.
    public static let roomEnded =
        "This room has ended. Nothing was recorded, so there's nothing to catch up on."

    /// The confirmation in front of ending a room.
    public static let endRoomWarning =
        "Everybody is disconnected straight away and the room can't be reopened. "
        + "Nothing was recorded, so there is nothing to keep."

    // MARK: Attendance

    /// `"3 speaking · 41 listening"`.
    public static func attendance(speakers: Int, listeners: Int) -> String {
        let speaking = speakers == 1 ? "1 speaking" : "\(speakers) speaking"
        let listening = listeners == 1 ? "1 listening" : "\(listeners) listening"
        return "\(speaking) · \(listening)"
    }

    /// When a scheduled room starts, in words.
    public static func scheduledFor(_ date: Date?) -> String {
        guard let date else { return "No start time yet." }
        if date.timeIntervalSinceNow <= 0 { return "Due to start." }
        return "Starts \(RelativeTime.accessible(date))."
    }

    // MARK: Empty states

    public static let emptyLiveTitle = "No rooms live right now"

    public static let emptyLiveSubtitle =
        "A room is a live conversation between verified people. Anyone can listen "
        + "to any room; who may speak depends on the room's audience. "
        + "Start one and see who turns up."

    public static let emptyScheduledTitle = "Nothing scheduled"

    public static let emptySearchTitle = "No rooms matched"

    public static func emptySearchSubtitle(_ query: String) -> String {
        "Nothing live or scheduled matches “\(query)”. Titles and topics are what get searched."
    }

    public static let searchTooShortTitle = "Keep typing"

    public static let searchTooShortSubtitle =
        "Type at least \(RoomConstants.minimumQueryLength) characters to search rooms."

    // MARK: The microphone

    /// The label on the control that takes the microphone.
    public static let takeMic = "Unmute"
    /// And the one that puts it down.
    public static let dropMic = "Mute"

    /// What unmuting actually does, including the part about permission.
    ///
    /// Says the permission prompt is coming *before* it appears, because a
    /// system dialog that arrives unannounced is one people deny by reflex.
    public static let takeMicHint =
        "Turns your microphone on so the room can hear you. "
        + "iOS asks for microphone permission the first time."

    public static let dropMicHint = "Turns your microphone off. The room can no longer hear you."

    /// Shown when the person denied microphone access at the system level.
    public static let microphoneDenied =
        "Sila can't reach your microphone. Turn it on in Settings › Sila › Microphone "
        + "to speak — you can keep listening either way."

    // MARK: Host controls

    public static let inviteToMic = "Invite to speak"

    public static func invited(_ name: String) -> String {
        "\(name) can speak now."
    }

    public static let takeMicBack = "Move to listeners"

    public static func demoted(_ name: String) -> String {
        "\(name) is listening again. They were not removed."
    }

    /// What the demoted person is told. Says plainly that they are still here,
    /// because being moved off a stage and being thrown out of a room feel
    /// identical from the inside if nobody says which happened.
    public static let youWereDemoted =
        "You're listening again. You're still in the room, and you weren't removed."

    /// What the promoted person is told.
    public static let youCanSpeakNow = "You can speak now. Unmute when you're ready."

    /// The reason a host cannot demote themselves.
    public static let cannotDemoteHost =
        "You're the host. Hand the room over by ending it — there is no way to step off your own stage."

    /// The stage is full.
    public static let stageFull =
        "The stage is full. Move somebody to listeners first."

    // MARK: Creating

    public static let createTitle = "Start a room"

    /// The sentence at the top of the create sheet.
    ///
    /// States the asymmetry once, plainly, because it is the thing people get
    /// wrong: the audience picker is about *speaking*, and every room is open
    /// to every listener regardless of what is chosen there.
    public static let createExplanation =
        "Everyone on Sila can listen to your room. The audience you pick decides "
        + "who may take the microphone."

    public static let titlePlaceholder = "What is this room about?"

    public static let titleMissing = "Give the room a title so people know what they're joining."

    public static func titleTooLong(_ count: Int) -> String {
        "That title is \(count - RoomConstants.maximumTitleLength) characters over the limit."
    }

    /// The scheduling row's explanation.
    public static let scheduleExplanation =
        "Leave this off to open the room now. Scheduling it puts it on the list "
        + "with a start time; nobody can speak in it until you open it."

    // MARK: Joining

    /// The unverified refusal, which is about posting rights, not about hearing.
    public static let unverifiedCannotOpen =
        "Only verified humans can open a room. Everyone can listen to one — "
        + "finish identity verification to host."

    /// What a listener sees while the media connection is being made.
    public static let connecting = "Connecting to the room…"

    /// A connection that dropped and is coming back.
    public static let reconnecting = "Reconnecting…"

    /// What "Leave" does.
    public static let leaveHint = "Leaves the room and disconnects your audio."
}
