import Foundation

/// Scripted ``GuestRoomsServiceProtocol`` for tests, previews and the
/// `-mockGuestRooms` launch argument.
///
/// It behaves like the server where that matters: a scheduled room answers
/// `room_not_live`, an unknown one `not_found`, and a pass it issued renews
/// the **same** identity instead of taking a second seat. The refusal
/// scenarios list rooms as usual and refuse every seat with their code, so a
/// journey can walk each refusal from a real tap.
///
/// The rooms are ``RoomsServiceMock``'s cast, as a guest sees them.
public actor GuestRoomsServiceMock: GuestRoomsServiceProtocol {

    public enum MockScenario: String, CaseIterable, Sendable {
        /// Three live rooms (two with guests listening) and two scheduled.
        case populated
        /// Nothing open to guests.
        case empty
        /// Every call fails on the network.
        case offline
        /// Seats are handed out; the media connection is what fails (the
        /// container builds a failing engine for it).
        case connectFailed = "connect_failed"
        case notFound = "not_found"
        case roomClosed = "room_closed"
        case guestsNotAllowed = "guests_not_allowed"
        case roomEnded = "room_ended"
        case guestsFull = "guests_full"
        case rateLimited = "rate_limited"
    }

    public private(set) var scenario: MockScenario
    private let latency: Double
    private var live: [RoomCard]
    private var scheduled: [RoomCard]
    /// Identities by the pass that names them, as the server keeps them.
    private var seats: [String: String] = [:]
    /// Every call, for assertions: `"rooms:live"`, `"listen:<id>:<pass|none>"`.
    public private(set) var recordedCalls: [String] = []
    /// The pass each listen call carried, in order (`nil` for none).
    public private(set) var passesSent: [String?] = []
    /// What the next listen answers `expires_in`.
    public var expiresIn = GuestListening.tokenLifetime
    /// Seconds a `rate_limited` refusal says to wait.
    public var retryAfter = 45

    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
        if scenario == .empty {
            live = []
            scheduled = []
        } else {
            live = Self.liveCards
            scheduled = Self.scheduledCards
        }
    }

    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    /// Answers every later listen for this room with `code` (a refusal that
    /// comes after the first seat: the room ended, guests were turned off).
    public func refuseLater(_ code: APIErrorCode?) {
        laterRefusal = code
    }
    private var laterRefusal: APIErrorCode?

    // MARK: - Reading

    public func fetchRooms(status: RoomStatus, limit: Int) async throws -> [RoomCard] {
        recordedCalls.append("rooms:\(status == .scheduled ? "scheduled" : "live")")
        try await delay()
        if scenario == .offline { throw APIError.transport("The Internet connection appears to be offline.") }
        let rows = status == .scheduled ? scheduled : live
        return Array(rows.prefix(max(1, limit)))
    }

    // MARK: - A seat

    public func listen(roomId: UUID, guestPass: String?) async throws -> GuestSeat {
        recordedCalls.append("listen:\(roomId.uuidString.lowercased()):\(guestPass ?? "none")")
        passesSent.append(guestPass)
        try await delay()
        if let code = laterRefusal { throw Self.refusal(code) }
        switch scenario {
        case .offline:
            throw APIError.transport("The Internet connection appears to be offline.")
        case .notFound:
            throw Self.refusal(.notFound)
        case .roomClosed:
            throw Self.refusal(.roomClosed)
        case .guestsNotAllowed:
            throw Self.refusal(.guestsNotAllowed)
        case .roomEnded:
            throw Self.refusal(.roomEnded)
        case .guestsFull:
            throw Self.refusal(.guestsFull)
        case .rateLimited:
            throw RetryAfterRefusal(
                error: .api(code: .rateLimited, message: "Too many attempts — try again in \(retryAfter) seconds", status: 429),
                seconds: retryAfter
            )
        case .populated, .empty, .connectFailed:
            break
        }
        if scheduled.contains(where: { $0.id == roomId }) { throw Self.refusal(.roomNotLive) }
        guard let card = live.first(where: { $0.id == roomId }) else { throw Self.refusal(.notFound) }

        // A pass it issued keeps its identity; anything else is a new seat.
        let identity = guestPass.flatMap { seats[$0] } ?? "guest-" + Self.hex32()
        let pass = "pass.\(roomId.uuidString.prefix(8).lowercased()).\(identity.suffix(8))"
        seats[pass] = identity
        return GuestSeat(
            room: card,
            url: "wss://sila.gmai.sa/rtc",
            token: "mock.guest.\(identity.suffix(8))",
            identity: identity,
            guestPass: pass,
            expiresIn: expiresIn
        )
    }

    // MARK: - Internals

    private static func refusal(_ code: APIErrorCode) -> APIError {
        let status: Int
        switch code {
        case .notFound: status = 404
        case .roomClosed, .guestsNotAllowed: status = 403
        default: status = 409
        }
        return .api(code: code, message: code.rawValue, status: status)
    }

    private static func hex32() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    // MARK: - The cast

    /// Guests listening on each live room, by position: the first two have
    /// some, the third none (and says only that guests can listen).
    private static let guestCounts = [12, 3, 0]

    static let liveCards: [RoomCard] = RoomsServiceMock.cast
        .filter { $0.status == .live }
        .enumerated()
        .map { index, room in card(room, guests: guestCounts[min(index, guestCounts.count - 1)]) }

    static let scheduledCards: [RoomCard] = RoomsServiceMock.cast
        .filter { $0.status == .scheduled }
        .map { card($0, guests: 0) }

    private static func card(_ room: VoiceRoom, guests: Int) -> RoomCard {
        var card = RoomCard(
            id: room.id,
            title: room.title,
            topic: room.topic,
            status: room.status,
            scope: room.scope,
            scopeCountry: room.scopeCountry,
            scopeRegion: room.scopeRegion,
            host: room.host,
            participantCount: room.speakerCount + room.listenerCount,
            scheduledFor: room.scheduledFor,
            startedAt: room.startedAt,
            metrics: RoomMetrics(likes: 14, shares: 2, views: 180, listeners: room.listenerCount)
        )
        card.starterQuestion = room.starterQuestion
        card.allowGuests = true
        card.guestCount = guests
        return card
    }
}
