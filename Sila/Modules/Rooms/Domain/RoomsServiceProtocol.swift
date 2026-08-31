import Foundation

/// Everything the Rooms module can ask the backend to do.
///
/// The seam the three view models depend on; ``RoomsService`` and
/// ``RoomsServiceMock`` are interchangeable behind it, which is what lets the
/// destructive paths on this surface — ending a room, removing somebody from
/// one — be driven end to end without doing either to a live conversation.
///
/// **Nothing here is a "can I speak?" query.** The answer arrives attached to
/// the room (``VoiceRoom/canSpeak``) and to the join (``RoomJoin/role``),
/// because it is the server's to compute. A client-side predicate would be a
/// second implementation of the scope rule, and two implementations of one rule
/// is one of them being wrong.
public protocol RoomsServiceProtocol: Sendable {

    /// Opens a room, `POST /rooms`.
    ///
    /// - Throws: ``APIErrorCode/unverified`` from an unverified account,
    ///   ``APIErrorCode/invalidScope`` for a country that is not the caller's
    ///   own, ``APIErrorCode/unknownTopic`` for a topic outside the taxonomy.
    func createRoom(_ request: CreateRoomRequest) async throws -> VoiceRoom

    /// Lists rooms, `GET /rooms`.
    /// - Parameters:
    ///   - status: Narrows to live, scheduled or ended. `nil` asks for all.
    ///   - topic: A topic id, or `nil`.
    ///   - limit: Page size, clamped to ``RoomConstants/maximumLimit``.
    func fetchRooms(status: RoomStatus?, topic: String?, limit: Int) async throws -> [VoiceRoom]

    /// One room, `GET /rooms/{id}`.
    ///
    /// Re-read rather than trusted from a list: ``VoiceRoom/canSpeak`` is
    /// computed per request, and the copy attached to a list row is whatever
    /// was true when that page was fetched.
    func fetchRoom(id: UUID) async throws -> VoiceRoom

    /// Joins, `POST /rooms/{id}/join`.
    ///
    /// - Returns: The media URL, a LiveKit token, and the role that token
    ///   grants. The token **is** the enforcement: a listener's carries
    ///   `canPublish: false` and the media server drops their audio whatever
    ///   this client draws.
    /// - Throws: ``APIErrorCode/removedFromRoom`` (per-room, not a block) and
    ///   ``APIErrorCode/roomEnded``.
    func join(roomId: UUID) async throws -> RoomJoin

    /// Leaves, `POST /rooms/{id}/leave`.
    ///
    /// Always paired with a media disconnect by the caller. A leave that
    /// reached the server while the socket stayed open would show the room a
    /// participant who is not on its list; the reverse leaves a ghost on the
    /// list of somebody who has gone.
    func leave(roomId: UUID) async throws

    /// Ends the room for everybody, `POST /rooms/{id}/end`. Host only.
    func endRoom(id: UUID) async throws -> VoiceRoom

    /// Invites somebody onto the stage, `POST /rooms/{id}/speakers`. Host only.
    ///
    /// The promoted account has to **re-join** to receive a token that permits
    /// publishing; this call changes the role, not the grant already issued.
    func promote(roomId: UUID, handle: String) async throws -> VoiceRoom

    /// Moves somebody back to the audience,
    /// `DELETE /rooms/{id}/speakers/{handle}`. Host only.
    ///
    /// They stay in the room. This is not a removal, and the copy that follows
    /// it says so.
    func demote(roomId: UUID, handle: String) async throws -> VoiceRoom

    /// Removes somebody from **this room**, `POST /rooms/{id}/remove`. Host only.
    ///
    /// Per-room. It is not a block and nothing in this module may describe it
    /// as one — the person keeps their account, their posts and every other
    /// room on Sila.
    func remove(roomId: UUID, handle: String) async throws -> VoiceRoom

    /// Who is in the room, `GET /rooms/{id}/participants`.
    func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList

    /// Searches room titles and topics, `GET /search/rooms`.
    /// - Returns: An empty array — with no request made — for a query shorter
    ///   than ``RoomConstants/minimumQueryLength``.
    func searchRooms(query: String, limit: Int) async throws -> [VoiceRoom]
}

extension RoomsServiceProtocol {

    /// Lists rooms with the contract's defaults.
    public func fetchRooms(status: RoomStatus? = nil, topic: String? = nil) async throws -> [VoiceRoom] {
        try await fetchRooms(status: status, topic: topic, limit: RoomConstants.defaultLimit)
    }

    /// Searches rooms with the contract's default limit.
    public func searchRooms(query: String) async throws -> [VoiceRoom] {
        try await searchRooms(query: query, limit: RoomConstants.searchLimit)
    }
}
