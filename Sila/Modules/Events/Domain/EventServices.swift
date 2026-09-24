import Foundation

/// Events (contract v23).
public protocol EventsServiceProtocol: Sendable {
    func upcoming(withinDays: Int, topic: String?) async throws -> [SilaEvent]
    func mine() async throws -> [SilaEvent]
    func event(_ id: UUID) async throws -> SilaEvent
    func create(_ request: CreateEventRequest) async throws -> SilaEvent
    func update(_ id: UUID, _ update: EventUpdate) async throws -> SilaEvent
    /// `nil` clears the answer (`none`).
    func rsvp(_ status: RSVPStatus?, eventId: UUID) async throws -> SilaEvent
    func attendees(_ id: UUID, status: RSVPStatus) async throws -> [UserSummary]
    func invite(_ handles: [String], eventId: UUID) async throws
    func cancel(_ id: UUID) async throws -> SilaEvent
    func addCohosts(_ handles: [String], eventId: UUID) async throws -> SilaEvent
    func removeCohost(_ handle: String, eventId: UUID) async throws -> SilaEvent
    func share(_ id: UUID, text: String?) async throws -> Post
}

/// A room's recap and a community's picture.
public protocol RecognitionServiceProtocol: Sendable {
    func recap(roomId: UUID) async throws -> RoomRecap
    func uploadCommunityAvatar(slug: String, jpeg: Data) async throws -> Community
}

public final class EventsService: EventsServiceProtocol, RecognitionServiceProtocol {
    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    private func path(_ id: UUID, _ rest: String = "") -> String { "/events/\(id.uuidString.lowercased())\(rest)" }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: path, accessToken: token, query: query), as: type)
    }

    private func json<B: Encodable, T: Decodable>(_ path: String, method: HTTPMethod = .post, body: B, as type: T.Type) async throws -> T {
        let token = try await tokens.accessToken()
        return try await network.send(try APIRequest.json(path, method: method, body: body, accessToken: token), as: type)
    }

    private func bare<T: Decodable>(_ path: String, method: HTTPMethod, as type: T.Type) async throws -> T {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: path, method: method, accessToken: token), as: type)
    }

    public func upcoming(withinDays: Int, topic: String?) async throws -> [SilaEvent] {
        var query = [URLQueryItem(name: "within_days", value: String(withinDays)), URLQueryItem(name: "limit", value: "30")]
        if let topic { query.append(URLQueryItem(name: "topic", value: topic)) }
        return try await get("/events/upcoming", query: query, as: EventsEnvelope.self).events
    }

    public func mine() async throws -> [SilaEvent] { try await get("/events/mine", as: EventsEnvelope.self).events }

    public func event(_ id: UUID) async throws -> SilaEvent { try await get(path(id), as: SilaEvent.self) }

    public func create(_ request: CreateEventRequest) async throws -> SilaEvent {
        let made = try await json("/events", body: request, as: SilaEvent.self)
        analytics.track(.eventCreated, properties: ["kind": request.kind])
        return made
    }

    public func update(_ id: UUID, _ update: EventUpdate) async throws -> SilaEvent {
        try await json(path(id), method: .patch, body: update, as: SilaEvent.self)
    }

    public func rsvp(_ status: RSVPStatus?, eventId: UUID) async throws -> SilaEvent {
        let event = try await json(path(eventId, "/rsvp"), method: .put, body: RSVPBody(status: status?.rawValue ?? "none"),
                                   as: SilaEvent.self)
        analytics.track(.eventRSVP, properties: ["result": status?.rawValue ?? "none"])
        return event
    }

    public func attendees(_ id: UUID, status: RSVPStatus) async throws -> [UserSummary] {
        try await get(path(id, "/attendees"), query: [URLQueryItem(name: "status", value: status.rawValue)],
                      as: AttendeesEnvelope.self).attendees
    }

    public func invite(_ handles: [String], eventId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(try APIRequest.json(path(eventId, "/invites"), body: HandlesBody(handles: handles), accessToken: token))
    }

    public func cancel(_ id: UUID) async throws -> SilaEvent { try await bare(path(id, "/cancel"), method: .post, as: SilaEvent.self) }

    public func addCohosts(_ handles: [String], eventId: UUID) async throws -> SilaEvent {
        try await json(path(eventId, "/cohosts"), body: HandlesBody(handles: handles), as: SilaEvent.self)
    }

    public func removeCohost(_ handle: String, eventId: UUID) async throws -> SilaEvent {
        try await bare(path(eventId, "/cohosts/\(Handle.pathComponent(handle))"), method: .delete, as: SilaEvent.self)
    }

    public func share(_ id: UUID, text: String?) async throws -> Post {
        try await json(path(id, "/share"), body: ShareBody(text: text), as: Post.self)
    }

    public func recap(roomId: UUID) async throws -> RoomRecap {
        try await get("/rooms/\(roomId.uuidString.lowercased())/recap", as: RoomRecap.self)
    }

    public func uploadCommunityAvatar(slug: String, jpeg: Data) async throws -> Community {
        let token = try await tokens.accessToken()
        var form = MultipartFormData()
        form.appendFile(jpeg, name: "file", filename: "avatar.jpg", mimeType: "image/jpeg")
        return try await network.send(
            APIRequest.multipart("/communities/\(slug)/avatar", method: .post, form: form, accessToken: token),
            as: Community.self
        )
    }
}

/// In-memory events for previews, journeys and tests.
public final class EventsServiceMock: EventsServiceProtocol, RecognitionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var events: [UUID: SilaEvent] = [:]
    public private(set) var invited: [String] = []
    public var failing = false

    public init(seeded: Bool = true) {
        if seeded {
            let sample = SilaEvent(title: "Derby watch party", description: "Riyadh derby, together.", kind: .watchParty,
                                   topic: "sports", startsAt: Date().addingTimeInterval(2 * 86_400), goingCount: 14,
                                   interestedCount: 30, host: FeedServiceMock.noor)
            events[sample.id] = sample
        }
    }

    private func check() throws {
        if failing { throw APIError.transport("The Internet connection appears to be offline.") }
    }

    public func upcoming(withinDays: Int, topic: String?) async throws -> [SilaEvent] {
        try check()
        let limit = Date().addingTimeInterval(TimeInterval(withinDays) * 86_400)
        return lock.withLock { events.values.filter { $0.startsAt <= limit && !$0.isOver }.sorted { $0.startsAt < $1.startsAt } }
    }

    public func mine() async throws -> [SilaEvent] {
        try check()
        return lock.withLock { events.values.filter { $0.isHost || $0.viewerRSVP == .going || $0.viewerRSVP == .interested } }
    }

    public func event(_ id: UUID) async throws -> SilaEvent {
        try check()
        return try lock.withLock {
            guard let event = events[id] else { throw APIError.api(code: .notFound, message: "No such event", status: 404) }
            return event
        }
    }

    public func create(_ request: CreateEventRequest) async throws -> SilaEvent {
        try check()
        guard request.startsAt > Date() else { throw APIError.api(code: .invalidTime, message: "In the past", status: 400) }
        let made = SilaEvent(title: request.title, description: request.description, kind: EventKind(rawValue: request.kind) ?? .other,
                             venueKind: EventVenueKind(rawValue: request.venueKind) ?? .room,
                             venueURL: request.venueUrl.flatMap(URL.init(string:)), venueName: request.venueName,
                             venueAddress: request.venueAddress, startsAt: request.startsAt, endsAt: request.endsAt,
                             timezone: request.timezone, isInviteOnly: request.isInviteOnly, maxAttendees: request.maxAttendees,
                             host: FeedServiceMock.aziz, canEdit: true, isHost: true)
        lock.withLock { events[made.id] = made }
        return made
    }

    public func update(_ id: UUID, _ update: EventUpdate) async throws -> SilaEvent {
        let current = try await event(id)
        return replace(current, title: update.title, startsAt: update.startsAt)
    }

    public func rsvp(_ status: RSVPStatus?, eventId: UUID) async throws -> SilaEvent {
        let current = try await event(eventId)
        if status == .going, current.isFull, current.viewerRSVP != .going {
            throw APIError.api(code: .eventFull, message: "Full", status: 409)
        }
        var going = current.goingCount - (current.viewerRSVP == .going ? 1 : 0)
        var interested = current.interestedCount - (current.viewerRSVP == .interested ? 1 : 0)
        if status == .going { going += 1 }
        if status == .interested { interested += 1 }
        let next = SilaEvent(id: current.id, title: current.title, description: current.description, kind: current.kind,
                             topic: current.topic, venueKind: current.venueKind, venueURL: current.venueURL,
                             venueName: current.venueName, venueAddress: current.venueAddress, roomId: current.roomId,
                             startsAt: current.startsAt, endsAt: current.endsAt, timezone: current.timezone,
                             status: current.status, isInviteOnly: current.isInviteOnly, maxAttendees: current.maxAttendees,
                             goingCount: going, interestedCount: interested,
                             isFull: current.maxAttendees.map { going >= $0 } ?? false, host: current.host,
                             cohosts: current.cohosts, viewerRSVP: status, canEdit: current.canEdit, isHost: current.isHost)
        lock.withLock { events[next.id] = next }
        return next
    }

    public func attendees(_ id: UUID, status: RSVPStatus) async throws -> [UserSummary] {
        try check()
        return status == .going ? [FeedServiceMock.yuki, FeedServiceMock.maria] : [FeedServiceMock.noor]
    }

    public func invite(_ handles: [String], eventId: UUID) async throws {
        try check()
        lock.withLock { invited += handles }
    }

    public func cancel(_ id: UUID) async throws -> SilaEvent {
        let current = try await event(id)
        return replace(current, status: .cancelled)
    }

    public func addCohosts(_ handles: [String], eventId: UUID) async throws -> SilaEvent {
        let current = try await event(eventId)
        let added = handles.prefix(max(0, 3 - current.cohosts.count)).map {
            UserSummary(id: UUID(), handle: $0, displayName: $0, isVerified: true)
        }
        return replace(current, cohosts: current.cohosts + added)
    }

    public func removeCohost(_ handle: String, eventId: UUID) async throws -> SilaEvent {
        let current = try await event(eventId)
        return replace(current, cohosts: current.cohosts.filter { $0.handle != handle })
    }

    public func share(_ id: UUID, text: String?) async throws -> Post {
        let current = try await event(id)
        if current.isInviteOnly { throw APIError.api(code: .eventNotShareable, message: "Closed", status: 403) }
        return Post(id: UUID(), author: FeedServiceMock.aziz, text: text ?? "", createdAt: Date())
    }

    public func recap(roomId: UUID) async throws -> RoomRecap {
        try check()
        return RoomRecap(roomId: roomId, title: "What verification actually changes", host: FeedServiceMock.yuki,
                         speakers: [FeedServiceMock.yuki, FeedServiceMock.maria], durationMinutes: 48, peakListeners: 61,
                         totalListeners: 140, questionsAnswered: 7)
    }

    public func uploadCommunityAvatar(slug: String, jpeg: Data) async throws -> Community {
        throw APIError.transport("Not in the mock")
    }

    private func replace(_ e: SilaEvent, title: String? = nil, startsAt: Date? = nil, status: EventStatus? = nil,
                         cohosts: [UserSummary]? = nil) -> SilaEvent {
        let next = SilaEvent(id: e.id, title: title ?? e.title, description: e.description, kind: e.kind, topic: e.topic,
                             venueKind: e.venueKind, venueURL: e.venueURL, venueName: e.venueName, venueAddress: e.venueAddress,
                             roomId: e.roomId, startsAt: startsAt ?? e.startsAt, endsAt: e.endsAt, timezone: e.timezone,
                             status: status ?? e.status, isInviteOnly: e.isInviteOnly, maxAttendees: e.maxAttendees,
                             goingCount: e.goingCount, interestedCount: e.interestedCount, isFull: e.isFull, host: e.host,
                             cohosts: cohosts ?? e.cohosts, viewerRSVP: e.viewerRSVP, canEdit: e.canEdit, isHost: e.isHost)
        lock.withLock { events[next.id] = next }
        return next
    }
}
