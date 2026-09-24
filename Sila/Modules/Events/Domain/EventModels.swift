import Foundation

// MARK: - Contract v23: Events as their own object

/// What kind of gathering an event is.
public enum EventKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case watchParty = "watch_party"
    case debate
    case gameNight = "game_night"
    case meetup
    case challenge
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .watchParty: return L10n.t("events.kind.watchParty")
        case .debate: return L10n.t("events.kind.debate")
        case .gameNight: return L10n.t("events.kind.gameNight")
        case .meetup: return L10n.t("events.kind.meetup")
        case .challenge: return L10n.t("events.kind.challenge")
        case .other: return L10n.t("events.kind.other")
        }
    }

    public var icon: String {
        switch self {
        case .watchParty: return "tv"
        case .debate: return "person.2.wave.2"
        case .gameNight: return "gamecontroller"
        case .meetup: return "person.3"
        case .challenge: return "flag.checkered"
        case .other: return "calendar"
        }
    }
}

/// Where it happens: a Sila room, a link, or a named place (never coordinates).
public enum EventVenueKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case room, link, place
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .room: return L10n.t("events.venue.room")
        case .link: return L10n.t("events.venue.link")
        case .place: return L10n.t("events.venue.place")
        }
    }
}

public enum EventStatus: String, Sendable, Hashable { case scheduled, live, ended, cancelled }

public enum RSVPStatus: String, CaseIterable, Identifiable, Sendable, Hashable {
    case going, interested, declined
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .going: return L10n.t("events.rsvp.going")
        case .interested: return L10n.t("events.rsvp.interested")
        case .declined: return L10n.t("events.rsvp.declined")
        }
    }
}

/// `EventOut`.
public struct SilaEvent: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public let id: UUID
    public let title: String
    public let description: String?
    public let kind: EventKind
    public let topic: String?
    public let venueKind: EventVenueKind
    public let venueURL: URL?
    public let venueName: String?
    public let venueAddress: String?
    public let roomId: UUID?
    public let startsAt: Date
    public let endsAt: Date?
    public let timezone: String?
    public let status: EventStatus
    public let isInviteOnly: Bool
    public let maxAttendees: Int?
    public let goingCount: Int
    public let interestedCount: Int
    public let isFull: Bool
    public let host: UserSummary?
    public let cohosts: [UserSummary]
    public let viewerRSVP: RSVPStatus?
    public let canEdit: Bool
    public let isHost: Bool

    public init(id: UUID = UUID(), title: String, description: String? = nil, kind: EventKind = .meetup,
                topic: String? = nil, venueKind: EventVenueKind = .room, venueURL: URL? = nil, venueName: String? = nil,
                venueAddress: String? = nil, roomId: UUID? = nil, startsAt: Date, endsAt: Date? = nil,
                timezone: String? = nil, status: EventStatus = .scheduled, isInviteOnly: Bool = false,
                maxAttendees: Int? = nil, goingCount: Int = 0, interestedCount: Int = 0, isFull: Bool = false,
                host: UserSummary? = nil, cohosts: [UserSummary] = [], viewerRSVP: RSVPStatus? = nil,
                canEdit: Bool = false, isHost: Bool = false) {
        self.id = id; self.title = title; self.description = description; self.kind = kind; self.topic = topic
        self.venueKind = venueKind; self.venueURL = venueURL; self.venueName = venueName; self.venueAddress = venueAddress
        self.roomId = roomId; self.startsAt = startsAt; self.endsAt = endsAt; self.timezone = timezone; self.status = status
        self.isInviteOnly = isInviteOnly; self.maxAttendees = maxAttendees; self.goingCount = goingCount
        self.interestedCount = interestedCount; self.isFull = isFull; self.host = host; self.cohosts = cohosts
        self.viewerRSVP = viewerRSVP; self.canEdit = canEdit; self.isHost = isHost
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, kind, topic, venueKind, venueUrl, venueName, venueAddress, roomId, startsAt, endsAt
        case timezone, status, isInviteOnly, maxAttendees, goingCount, interestedCount, isFull, host, cohosts
        case viewerRsvp, canEdit, isHost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        kind = EventKind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .other
        topic = (try? c.decodeIfPresent(String.self, forKey: .topic)) ?? nil
        venueKind = EventVenueKind(rawValue: (try? c.decode(String.self, forKey: .venueKind)) ?? "") ?? .room
        venueURL = ((try? c.decodeIfPresent(String.self, forKey: .venueUrl)) ?? nil).flatMap(URL.init(string:))
        venueName = (try? c.decodeIfPresent(String.self, forKey: .venueName)) ?? nil
        venueAddress = (try? c.decodeIfPresent(String.self, forKey: .venueAddress)) ?? nil
        roomId = (try? c.decodeIfPresent(UUID.self, forKey: .roomId)) ?? nil
        startsAt = (try? c.decode(Date.self, forKey: .startsAt)) ?? Date()
        endsAt = (try? c.decodeIfPresent(Date.self, forKey: .endsAt)) ?? nil
        timezone = (try? c.decodeIfPresent(String.self, forKey: .timezone)) ?? nil
        status = EventStatus(rawValue: (try? c.decode(String.self, forKey: .status)) ?? "") ?? .scheduled
        isInviteOnly = (try? c.decode(Bool.self, forKey: .isInviteOnly)) ?? false
        maxAttendees = (try? c.decodeIfPresent(Int.self, forKey: .maxAttendees)) ?? nil
        goingCount = (try? c.decode(Int.self, forKey: .goingCount)) ?? 0
        interestedCount = (try? c.decode(Int.self, forKey: .interestedCount)) ?? 0
        isFull = (try? c.decode(Bool.self, forKey: .isFull)) ?? false
        host = (try? c.decodeIfPresent(UserSummary.self, forKey: .host)) ?? nil
        cohosts = (try? c.decode([UserSummary].self, forKey: .cohosts)) ?? []
        viewerRSVP = ((try? c.decodeIfPresent(String.self, forKey: .viewerRsvp)) ?? nil).flatMap(RSVPStatus.init(rawValue:))
        canEdit = (try? c.decode(Bool.self, forKey: .canEdit)) ?? false
        isHost = (try? c.decode(Bool.self, forKey: .isHost)) ?? false
    }

    /// "Thu 25 Sep, 21:00" — in the reader's calendar, Western digits.
    public var whenLine: String {
        guard let endsAt else { return SLFormat.dateTime(startsAt) }
        return L10n.t("events.when.range", SLFormat.dateTime(startsAt), SLFormat.dateTime(endsAt))
    }

    /// Where, in words.
    public var whereLine: String {
        switch venueKind {
        case .room: return L10n.t("events.venue.onSila")
        case .link: return venueURL?.host ?? L10n.t("events.venue.link")
        case .place: return [venueName, venueAddress].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public var isOver: Bool { status == .ended || status == .cancelled }
}

/// `PostOut.event` — the card a shared event travels as.
public struct EventCard: Equatable, Hashable, Sendable, Decodable {
    public let id: UUID
    public let title: String
    public let kind: EventKind
    public let startsAt: Date
    public let status: EventStatus
    public let venueKind: EventVenueKind
    public let venueName: String?
    public let goingCount: Int

    public init(id: UUID, title: String, kind: EventKind = .meetup, startsAt: Date, status: EventStatus = .scheduled,
                venueKind: EventVenueKind = .room, venueName: String? = nil, goingCount: Int = 0) {
        self.id = id; self.title = title; self.kind = kind; self.startsAt = startsAt; self.status = status
        self.venueKind = venueKind; self.venueName = venueName; self.goingCount = goingCount
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, startsAt, status, venueKind, venueName, goingCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        kind = EventKind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .other
        startsAt = (try? c.decode(Date.self, forKey: .startsAt)) ?? Date()
        status = EventStatus(rawValue: (try? c.decode(String.self, forKey: .status)) ?? "") ?? .scheduled
        venueKind = EventVenueKind(rawValue: (try? c.decode(String.self, forKey: .venueKind)) ?? "") ?? .room
        venueName = (try? c.decodeIfPresent(String.self, forKey: .venueName)) ?? nil
        goingCount = (try? c.decode(Int.self, forKey: .goingCount)) ?? 0
    }
}

/// `POST /events`.
public struct CreateEventRequest: Encodable, Equatable, Sendable {
    public var title: String
    public var description: String?
    public var kind: String
    public var topic: String?
    public var venueKind: String
    public var venueUrl: String?
    public var venueName: String?
    public var venueAddress: String?
    public var startsAt: Date
    public var endsAt: Date?
    public var timezone: String
    public var scope: String
    public var scopeCountry: String?
    public var scopeRegion: String?
    public var isInviteOnly: Bool
    public var maxAttendees: Int?
    public var inviteHandles: [String]
    public var cohostHandles: [String]
}

/// `PATCH /events/{id}` — only what changed.
public struct EventUpdate: Encodable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var startsAt: Date?
    public var endsAt: Date?
    public var maxAttendees: Int?

    public init(title: String? = nil, description: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil,
                maxAttendees: Int? = nil) {
        self.title = title; self.description = description; self.startsAt = startsAt; self.endsAt = endsAt
        self.maxAttendees = maxAttendees
    }
}

struct EventsEnvelope: Decodable {
    let events: [SilaEvent]
    private enum CodingKeys: String, CodingKey { case events }
    init(from decoder: Decoder) throws {
        events = (try? decoder.container(keyedBy: CodingKeys.self).decode([FailableDecodable<SilaEvent>].self, forKey: .events))?
            .compactMap(\.value) ?? []
    }
}
struct AttendeesEnvelope: Decodable { let attendees: [UserSummary] }
struct RSVPBody: Encodable { let status: String }
struct HandlesBody: Encodable { let handles: [String] }
struct ShareBody: Encodable { let text: String? }

// MARK: - Recognition badges

/// A weekly badge, computed from the trailing 28 days. Drawn as a small label
/// — never next to the verification seal, never a check mark, never the word
/// "verified".
public enum RecognitionBadge: String, CaseIterable, Sendable, Hashable, Identifiable {
    case topHelper = "top_helper"
    case questionAsker = "question_asker"
    case insightfulVoice = "insightful_voice"
    case host

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topHelper: return L10n.t("badge.topHelper")
        case .questionAsker: return L10n.t("badge.questionAsker")
        case .insightfulVoice: return L10n.t("badge.insightfulVoice")
        case .host: return L10n.t("badge.host")
        }
    }

    public var icon: String {
        switch self {
        case .topHelper: return "hands.clap"
        case .questionAsker: return "questionmark.circle"
        case .insightfulVoice: return "lightbulb"
        case .host: return "mic"
        }
    }

    /// Known badges from a server list, unknown ones dropped.
    public static func parse(_ raw: [String]) -> [RecognitionBadge] { raw.compactMap(RecognitionBadge.init(rawValue:)) }
}

// MARK: - Post-room recap

public struct RoomRecap: Equatable, Sendable, Decodable {
    public struct PollResult: Equatable, Sendable, Decodable {
        public struct Option: Equatable, Sendable, Decodable { public let text: String; public let votes: Int }
        public let question: String
        public let totalVotes: Int
        public let options: [Option]
    }

    public let roomId: UUID
    public let title: String
    public let host: UserSummary?
    public let speakers: [UserSummary]
    public let durationMinutes: Int
    public let peakListeners: Int
    public let totalListeners: Int
    public let questionsAnswered: Int
    public let polls: [PollResult]

    public init(roomId: UUID, title: String, host: UserSummary? = nil, speakers: [UserSummary] = [], durationMinutes: Int = 0,
                peakListeners: Int = 0, totalListeners: Int = 0, questionsAnswered: Int = 0, polls: [PollResult] = []) {
        self.roomId = roomId; self.title = title; self.host = host; self.speakers = speakers
        self.durationMinutes = durationMinutes; self.peakListeners = peakListeners; self.totalListeners = totalListeners
        self.questionsAnswered = questionsAnswered; self.polls = polls
    }

    private enum CodingKeys: String, CodingKey {
        case roomId, title, host, speakers, durationMinutes, peakListeners, totalListeners, questionsAnswered, polls
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        host = (try? c.decodeIfPresent(UserSummary.self, forKey: .host)) ?? nil
        speakers = (try? c.decode([UserSummary].self, forKey: .speakers)) ?? []
        durationMinutes = (try? c.decode(Int.self, forKey: .durationMinutes)) ?? 0
        peakListeners = (try? c.decode(Int.self, forKey: .peakListeners)) ?? 0
        totalListeners = (try? c.decode(Int.self, forKey: .totalListeners)) ?? 0
        questionsAnswered = (try? c.decode(Int.self, forKey: .questionsAnswered)) ?? 0
        polls = (try? c.decode([PollResult].self, forKey: .polls)) ?? []
    }
}
