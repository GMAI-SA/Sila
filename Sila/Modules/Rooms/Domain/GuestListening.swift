import Foundation

// MARK: - Listening without an account (contract v31)
//
// Owner request 2026-09-28: somebody who has not registered should be able to
// open a voice room and listen. The parts that are rules rather than screens
// live here — the seat, what each refusal says and offers, when a seat is
// renewed, which data messages carry a chat line, and the pass that keeps the
// same seat — so they can be asserted without a screen.

/// A guest's seat in a room: `POST /public/rooms/{id}/listen`.
///
/// The token subscribes and does nothing else — it cannot publish audio or
/// data, and it is **hidden**, so nobody in the room is told a guest
/// connected. The pass renews the same seat instead of taking a second.
public struct GuestSeat: Equatable, Sendable, Decodable {
    /// The room's public card, with its guest fields.
    public let room: RoomCard?
    /// The media server to dial.
    public let url: String
    /// The LiveKit token. Never logged, never rendered.
    public let token: String
    /// `guest-<32 hex>`: the connection's identity on the media server.
    public let identity: String
    /// Sent back to renew the seat. Kept in memory only.
    public let guestPass: String
    /// Seconds the token may be used to connect.
    public let expiresIn: Int
    /// Always `guest`.
    public let role: String

    public init(room: RoomCard?, url: String, token: String, identity: String,
                guestPass: String, expiresIn: Int = 600, role: String = "guest") {
        self.room = room
        self.url = url
        self.token = token
        self.identity = identity
        self.guestPass = guestPass
        self.expiresIn = expiresIn
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case room, url, token, identity, guestPass, expiresIn, role
    }

    /// Deliberately strict about the two things that make it a seat: a seat
    /// without a URL or a token is no seat, and pretending otherwise would
    /// put a room on screen with silence behind it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        token = try container.decode(String.self, forKey: .token)
        room = (try? container.decodeIfPresent(RoomCard.self, forKey: .room)) ?? nil
        identity = (try? container.decode(String.self, forKey: .identity)) ?? ""
        guestPass = (try? container.decode(String.self, forKey: .guestPass)) ?? ""
        let seconds = (try? container.decode(Int.self, forKey: .expiresIn)) ?? 0
        expiresIn = seconds > 0 ? seconds : GuestListening.tokenLifetime
        role = (try? container.decode(String.self, forKey: .role)) ?? "guest"
    }
}

/// The body of a renewal: `{"guest_pass": "…"}`, or `{}` the first time.
struct GuestListenBody: Encodable {
    let guestPass: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(guestPass, forKey: .guestPass)
    }

    private enum CodingKeys: String, CodingKey { case guestPass }
}

/// What `GET /public/rooms` answers: `{"rooms": [RoomCard…]}`, row by row so
/// one unreadable card costs that card and not the list.
struct GuestRoomList: Decodable {
    let rooms: [RoomCard]

    private enum CodingKeys: String, CodingKey { case rooms }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rooms = ((try? container.decode([FailableCard].self, forKey: .rooms)) ?? []).compactMap(\.value)
    }

    private struct FailableCard: Decodable {
        let value: RoomCard?
        init(from decoder: Decoder) throws { value = try? RoomCard(from: decoder) }
    }
}

// MARK: - The service

/// The two calls a guest makes, neither with a token.
///
/// A guest calls nothing else: every other room route — the room, the join,
/// the roster, a hand, the chat, questions, polls, a like — still answers
/// `401` without an account, and the screen offers to join instead.
public protocol GuestRoomsServiceProtocol: Sendable {
    /// The rooms a guest may open, `GET /public/rooms?status=`: `.live` now,
    /// or `.scheduled`, soonest first. A room whose host turned guests off is
    /// not listed.
    func fetchRooms(status: RoomStatus, limit: Int) async throws -> [RoomCard]

    /// A seat, `POST /public/rooms/{id}/listen`: the first time with no pass,
    /// then with the pass the last answer gave, to keep the same seat.
    ///
    /// - Throws: `not_found`, `room_closed`, `guests_not_allowed`,
    ///   `room_not_live`, `room_ended`, `guests_full`, and `rate_limited` —
    ///   as a ``RetryAfterRefusal`` when the server said how long to wait.
    func listen(roomId: UUID, guestPass: String?) async throws -> GuestSeat
}

// MARK: - Refusals

/// Why a guest is not listening, and what they can do about it.
///
/// Every refusal the listen call answers has its own words — none of them is
/// "something went wrong" — plus the one the phone adds when the media server
/// cannot be reached.
public struct GuestRefusal: Equatable, Sendable {

    public enum Code: String, CaseIterable, Sendable {
        /// No such room, or its host left or was suspended.
        case notFound = "not_found"
        /// Invite-only, following-only, a group's or a community's.
        case roomClosed = "room_closed"
        /// The host turned guests off, the host is private, or the platform
        /// switch is off.
        case guestsNotAllowed = "guests_not_allowed"
        /// Scheduled, not started.
        case roomNotLive = "room_not_live"
        case roomEnded = "room_ended"
        /// Every guest seat is taken.
        case guestsFull = "guests_full"
        /// This connection asked too often; `Retry-After` says for how long.
        case rateLimited = "rate_limited"
        /// The media server could not be reached, or the network failed.
        case connectFailed = "connect_failed"
    }

    public let code: Code
    /// Seconds before asking again is worth it, when the server said.
    public let retryAfter: Int?

    public init(_ code: Code, retryAfter: Int? = nil) {
        self.code = code
        self.retryAfter = code == .rateLimited ? retryAfter.flatMap { $0 > 0 ? $0 : nil } : nil
    }

    /// What the listen call (or the connection) threw, as a refusal. A code
    /// this build does not know reads as the connection failing — asking
    /// again is the one thing a guest can do about it.
    public init(error: Error) {
        if let refusal = error as? RetryAfterRefusal {
            if refusal.error.code == .rateLimited || Self.status(refusal.error) == 429 {
                self.init(.rateLimited, retryAfter: refusal.seconds)
            } else {
                self.init(error: refusal.error)
            }
            return
        }
        let api = APIError.wrapping(error)
        switch api.code {
        case .rateLimited: self.init(.rateLimited)
        case .notFound: self.init(.notFound)
        case .roomClosed: self.init(.roomClosed)
        case .guestsNotAllowed: self.init(.guestsNotAllowed)
        case .roomNotLive: self.init(.roomNotLive)
        case .roomEnded: self.init(.roomEnded)
        case .guestsFull: self.init(.guestsFull)
        default:
            switch Self.status(api) {
            case 429: self.init(.rateLimited)
            case 404: self.init(.notFound)
            default: self.init(.connectFailed)
            }
        }
    }

    private static func status(_ error: APIError) -> Int? {
        switch error {
        case let .api(_, _, status), let .http(status, _): return status
        default: return nil
        }
    }

    /// Joining or signing in is offered: a member could do what a guest
    /// cannot — enter a closed room, listen where guests may not, take no
    /// guest seat, be reminded, hear the next one.
    public var offersJoin: Bool {
        switch code {
        case .roomClosed, .guestsNotAllowed, .roomNotLive, .roomEnded, .guestsFull: return true
        case .notFound, .rateLimited, .connectFailed: return false
        }
    }

    /// Asking again may work: a seat frees up, the room starts, the limit
    /// clears, the line comes back.
    public var canRetry: Bool {
        switch code {
        case .roomNotLive, .guestsFull, .rateLimited, .connectFailed: return true
        case .notFound, .roomClosed, .guestsNotAllowed, .roomEnded: return false
        }
    }

    public var icon: String {
        switch code {
        case .notFound: return "questionmark.folder"
        case .roomClosed: return "lock.fill"
        case .guestsNotAllowed: return "ear.trianglebadge.exclamationmark"
        case .roomNotLive: return "calendar.badge.clock"
        case .roomEnded: return "stop.circle"
        case .guestsFull: return "person.3.fill"
        case .rateLimited: return "hourglass"
        case .connectFailed: return "wifi.exclamationmark"
        }
    }

    /// Spelled out per code rather than interpolated from the raw value: a
    /// key the catalogue check cannot see is a key nobody notices missing.
    public var title: String {
        switch code {
        case .notFound: return L10n.t("guest.room.refusal.notFound.title")
        case .roomClosed: return L10n.t("guest.room.refusal.roomClosed.title")
        case .guestsNotAllowed: return L10n.t("guest.room.refusal.guestsNotAllowed.title")
        case .roomNotLive: return L10n.t("guest.room.refusal.roomNotLive.title")
        case .roomEnded: return L10n.t("guest.room.refusal.roomEnded.title")
        case .guestsFull: return L10n.t("guest.room.refusal.guestsFull.title")
        case .rateLimited: return L10n.t("guest.room.refusal.rateLimited.title")
        case .connectFailed: return L10n.t("guest.room.refusal.connectFailed.title")
        }
    }

    public var detail: String {
        switch code {
        case .notFound: return L10n.t("guest.room.refusal.notFound.detail")
        case .roomClosed: return L10n.t("guest.room.refusal.roomClosed.detail")
        case .guestsNotAllowed: return L10n.t("guest.room.refusal.guestsNotAllowed.detail")
        case .roomNotLive: return L10n.t("guest.room.refusal.roomNotLive.detail")
        case .roomEnded: return L10n.t("guest.room.refusal.roomEnded.detail")
        case .guestsFull: return L10n.t("guest.room.refusal.guestsFull.detail")
        case .rateLimited: return L10n.t("guest.room.refusal.rateLimited.detail")
        case .connectFailed: return L10n.t("guest.room.refusal.connectFailed.detail")
        }
    }

    /// "Try again in 40 seconds" / "…in 3 minutes", for a wait still to run.
    public static func tryAgainIn(seconds: Int) -> String {
        let wait = max(1, seconds)
        if wait < 120 { return L10n.plural("guest.room.tryAgainIn.seconds", wait) }
        return L10n.plural("guest.room.tryAgainIn.minutes", Int((Double(wait) / 60).rounded(.up)))
    }
}

// MARK: - Timing

/// The clock a guest's seat runs on.
public enum GuestListening {
    /// What the server gives a token, when an answer does not say.
    public static let tokenLifetime = 600
    /// Renew this long before the token stops being good for connecting.
    public static let renewLead = 60
    /// …and never sooner than this after the last ask: every call counts
    /// against the address's limit (30 in ten minutes).
    public static let minimumRenewDelay = 30
    /// A renewal that failed on the network, or lost a seat race, is tried
    /// again this much later; the connection is still up meanwhile.
    public static let renewRetryDelay: TimeInterval = 30
    /// Reconnections allowed within a minute before the screen asks the
    /// guest to try again themselves.
    public static let reconnectsPerMinute = 2
    /// Lines of chat a guest's room keeps.
    public static let chatLimit = 200
    /// The most rooms `GET /public/rooms` answers at once; more is a `422`.
    public static let maximumListLimit = 30

    /// Seconds from an answer to its renewal: a minute before `expiresIn`,
    /// and not sooner than thirty seconds.
    public static func renewDelay(expiresIn: Int) -> TimeInterval {
        let seconds = expiresIn > 0 ? expiresIn : tokenLifetime
        return TimeInterval(max(minimumRenewDelay, seconds - renewLead))
    }

    /// Whether a dropped connection may be asked for again now, given when
    /// the last ones were: at most ``reconnectsPerMinute`` a minute.
    public static func mayReconnect(now: Date, previous: [Date]) -> Bool {
        previous.filter { now.timeIntervalSince($0) < 60 }.count < reconnectsPerMinute
    }
}

/// The pass each room's seat was given, for the app's life (contract v31
/// §Clients: keep it in memory): coming back to a room, or reconnecting to
/// it, renews the same seat instead of taking a second. Never stored — a
/// relaunch is a new guest.
@MainActor
public final class GuestPassBook {
    private var passes: [UUID: String] = [:]

    public init() {}

    public func pass(for room: UUID) -> String? { passes[room] }

    public func keep(_ pass: String, for room: UUID) {
        guard !pass.isEmpty else { return }
        passes[room] = pass
    }

    /// Everything, on joining: a member needs no guest seat.
    public func forgetAll() { passes = [:] }
}

// MARK: - Chat, as a guest reads it

/// A line of room chat as a guest sees it: only what arrived while they
/// listened, never the history (that is a member's route).
public struct GuestChatLine: Identifiable, Equatable, Sendable {
    /// The server's id for a kept line; a local one for a line on the wire only.
    public let id: String
    public let name: String
    public let text: String

    public init(id: String, name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }

    /// A chat line from a data message, or `nil`. Two shapes reach a guest:
    /// the server's fan-out of a kept line (`{type: chat, message: {…}}`)
    /// and a client's line to the whole room (`{type: chat, text, name}`).
    /// A line to the host alone is addressed to the host and never arrives;
    /// one marked `toHost` is dropped anyway, as is a hidden one.
    public static func from(_ message: RoomDataMessage, localId: () -> String = { UUID().uuidString }) -> GuestChatLine? {
        guard message.type == "chat" else { return nil }
        if let kept = message.message {
            let text = kept.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !kept.hidden else { return nil }
            let name = kept.author.map { $0.displayName.isEmpty ? $0.atHandle : $0.displayName } ?? ""
            return GuestChatLine(id: kept.id.uuidString.lowercased(), name: name, text: text)
        }
        guard !message.toHost else { return nil }
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = message.name ?? message.handle.map { "@\($0)" } ?? ""
        return GuestChatLine(id: localId(), name: name, text: text)
    }
}

/// A card is listed by its room.
extension RoomCard: Identifiable {}
