import Foundation

/// The production ``RoomsServiceProtocol``.
///
/// Talks to `/rooms` and `/search/rooms` through the injected ``NetworkClient``.
/// Like every other service it holds no session state: the bearer token is
/// fetched per call from ``AccessTokenProviding``.
///
/// **Nothing here logs a token.** The join response carries a LiveKit
/// credential that grants publishing rights for the length of a conversation,
/// and the analytics line below deliberately records the *role* rather than
/// anything that could be replayed.
public final class RoomsService: RoomsServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - network: HTTP transport.
    ///   - tokens: Supplies the bearer token.
    ///   - analytics: Event sink.
    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    // MARK: - Reading

    public func fetchRooms(status: RoomStatus?, topic: String?, limit: Int) async throws -> [VoiceRoom] {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(clamped(limit)))]
        // `status` is only sent when it narrows something. An unrecognised
        // status has no wire value and is treated as "no filter" rather than
        // being spelled out as a word the server would 422 on.
        if let value = status?.wireValue {
            query.append(URLQueryItem(name: "status", value: value))
        }
        if let topic, !topic.isEmpty {
            query.append(URLQueryItem(name: "topic", value: topic))
        }
        let rooms = try await network.send(
            APIRequest(path: "/rooms", accessToken: token, query: query),
            as: VoiceRoomList.self
        ).rooms
        analytics.track(.roomsLoaded, properties: [
            "count": String(rooms.count),
            "status": status?.wireValue ?? "all",
            "topic": topic ?? "any"
        ])
        return rooms
    }

    public func fetchRoom(id: UUID) async throws -> VoiceRoom {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/rooms/\(path(id))", accessToken: token),
            as: VoiceRoom.self
        )
    }

    public func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/rooms/\(path(roomId))/participants", accessToken: token),
            as: RoomParticipantList.self
        )
    }

    public func searchRooms(query: String, limit: Int) async throws -> [VoiceRoom] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server answers a short query with nothing. Spending a round trip
        // to be told that would make every second keystroke a wasted request.
        guard RoomConstants.isSearchable(trimmed) else { return [] }

        let token = try await tokens.accessToken()
        let rooms = try await network.send(
            APIRequest(
                path: "/search/rooms",
                accessToken: token,
                query: [
                    URLQueryItem(name: "q", value: trimmed),
                    URLQueryItem(name: "limit", value: String(clamped(limit)))
                ]
            ),
            as: VoiceRoomList.self
        ).rooms
        analytics.track(.roomsSearched, properties: ["results": String(rooms.count)])
        return rooms
    }

    // MARK: - Creating

    public func createRoom(_ request: CreateRoomRequest) async throws -> VoiceRoom {
        let token = try await tokens.accessToken()
        let room = try await network.send(
            try APIRequest.json("/rooms", method: .post, body: request, accessToken: token),
            as: VoiceRoom.self
        )
        analytics.track(.roomCreated, properties: [
            "scope": room.scope.rawValue,
            "topic": room.topic ?? "none",
            "status": room.status.rawValue
        ])
        return room
    }

    // MARK: - Joining and leaving

    public func join(roomId: UUID) async throws -> RoomJoin {
        let token = try await tokens.accessToken()
        let join = try await network.send(
            APIRequest(path: "/rooms/\(path(roomId))/join", method: .post, accessToken: token),
            as: RoomJoin.self
        )
        // The role, never the token. What matters operationally is the ratio of
        // listeners to speakers; a credential in a log is a credential.
        analytics.track(.roomJoined, properties: [
            "role": join.role.rawValue,
            "can_speak": String(join.room.canSpeak)
        ])
        return join
    }

    public func leave(roomId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(path: "/rooms/\(path(roomId))/leave", method: .post, accessToken: token)
        )
        analytics.track(.roomLeft)
    }

    // MARK: - Host controls

    public func endRoom(id: UUID) async throws -> VoiceRoom {
        let token = try await tokens.accessToken()
        let room = try await network.send(
            APIRequest(path: "/rooms/\(path(id))/end", method: .post, accessToken: token),
            as: VoiceRoom.self
        )
        analytics.track(.roomEnded, properties: ["status": room.status.rawValue])
        return room
    }

    public func promote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        let token = try await tokens.accessToken()
        let room = try await network.send(
            try APIRequest.json(
                "/rooms/\(path(roomId))/speakers",
                method: .post,
                body: RoomHandleRequest(handle: Handle.normalised(handle)),
                accessToken: token
            ),
            as: VoiceRoom.self
        )
        analytics.track(.roomSpeakerPromoted)
        return room
    }

    public func demote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        let token = try await tokens.accessToken()
        let room = try await network.send(
            APIRequest(
                path: "/rooms/\(path(roomId))/speakers/\(Handle.pathComponent(handle))",
                method: .delete,
                accessToken: token
            ),
            as: VoiceRoom.self
        )
        analytics.track(.roomSpeakerDemoted)
        return room
    }

    public func remove(roomId: UUID, handle: String) async throws -> VoiceRoom {
        let token = try await tokens.accessToken()
        let room = try await network.send(
            try APIRequest.json(
                "/rooms/\(path(roomId))/remove",
                method: .post,
                body: RoomHandleRequest(handle: Handle.normalised(handle)),
                accessToken: token
            ),
            as: VoiceRoom.self
        )
        // Recorded as what it is. A removal is per-room; nothing about the
        // account changed, and the event name must not suggest otherwise.
        analytics.track(.roomParticipantRemoved)
        return room
    }

    // MARK: - Plumbing

    /// UUIDs go on the wire lower-cased. Postgres does not care; a server that
    /// string-matched would.
    private func path(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func clamped(_ limit: Int) -> Int {
        min(max(limit, 1), RoomConstants.maximumLimit)
    }
}
