import Foundation

/// Where a request to open a room came from (round-2 security finding CA-1).
///
/// Joining a room shows the person to its host — by verified name, in the
/// listener list — so only a tap made inside the app, on something that
/// already showed the room, joins at once. A room reached any other way —
/// a universal link from Messages or a web page, a push, an invitation row,
/// the `-openLink` launch argument — stops at the room's card first, and
/// nothing reaches the server but a read until the person taps Join (or,
/// signed out, Listen).
public enum RoomOpenOrigin: Equatable, Sendable {
    /// A room card, the Live now rail, an event's Join button, a room just
    /// created, the way back after signing in from a room a guest was in.
    case inApp
    /// A link, a push, or an invitation: something the person did not see
    /// the room on before it opened.
    case outside

    /// Whether the room is joined as soon as it opens.
    public var joinsAtOnce: Bool { self == .inApp }
}

extension RoomsRoute {
    /// The route a fetched room opens on: the room itself when the person
    /// already chose it inside the app, its card with a Join button
    /// otherwise.
    public static func opening(_ room: VoiceRoom, from origin: RoomOpenOrigin) -> RoomsRoute {
        origin.joinsAtOnce ? .room(room) : .roomLink(room)
    }
}

/// What a room's card shows before anything is joined or listened to.
///
/// Built from a member's room read, from a guest's public card, or — for a
/// guest whose link names a room the public lists do not show — from the id
/// alone, in which case the card says only that a room was shared and
/// Listen asks the server, whose refusal is then said in its own words.
public struct RoomLinkPreview: Equatable, Sendable {
    public let id: UUID
    public let title: String?
    public let topic: String?
    public let status: RoomStatus
    public let hostName: String?
    public let hostHandle: String?
    public let isHostVerified: Bool
    /// Speakers and listeners, when known.
    public let peopleCount: Int?
    public let scheduledFor: Date?

    public init(room: VoiceRoom) {
        id = room.id
        title = room.title
        topic = room.topic
        status = room.status
        hostName = room.host.displayName
        hostHandle = room.host.handle
        isHostVerified = room.host.isVerified
        peopleCount = room.speakerCount + room.listenerCount
        scheduledFor = room.scheduledFor
    }

    public init(card: RoomCard) {
        id = card.id
        title = card.title
        topic = card.topic
        status = card.status
        hostName = card.host.displayName
        hostHandle = card.host.handle
        isHostVerified = card.host.isVerified
        peopleCount = card.participantCount
        scheduledFor = card.scheduledFor
    }

    /// Only the id: the room is not on the public lists.
    public init(unlisted id: UUID) {
        self.id = id
        title = nil
        topic = nil
        status = .unknown
        hostName = nil
        hostHandle = nil
        isHostVerified = false
        peopleCount = nil
        scheduledFor = nil
    }

    /// Whether the card offers Join or Listen. A room that is not live yet,
    /// or has ended, says so instead; an unlisted one lets the server answer.
    public var canEnter: Bool { status == .live || status == .unknown }
}
