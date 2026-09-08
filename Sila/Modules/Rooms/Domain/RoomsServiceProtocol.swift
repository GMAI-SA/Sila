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

    /// Hands somebody the microphone, `POST /rooms/{id}/speakers`. Host only.
    ///
    /// The answer to a raised hand, or an invitation out of the blue. The
    /// server tells the media server at once, so the person's audio never
    /// drops; the next token they are issued carries the seat too.
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

    /// Who has been invited to a closed room, `GET /rooms/{id}/invites`.
    /// Host only — the guest list is the host's, and nobody else's business.
    func fetchInvites(roomId: UUID) async throws -> RoomInviteList

    /// Invites people by handle, `POST /rooms/{id}/invites`. Host only.
    ///
    /// - Returns: Everybody now holding an invitation, not just the additions.
    /// - Throws: ``APIErrorCode/userNotFound`` when a handle belongs to
    ///   nobody — the server writes nothing in that case, so a mistyped handle
    ///   is a refusal rather than a guest who never arrives;
    ///   ``APIErrorCode/notInviteOnly`` for an open room; ``APIErrorCode/blocked``.
    func invite(roomId: UUID, handles: [String]) async throws -> RoomInviteList

    /// Withdraws one invitation, `DELETE /rooms/{id}/invites/{handle}`.
    ///
    /// Stops a future join. Somebody already in the room stays until they
    /// leave — ejecting them is ``remove(roomId:handle:)``, which is a
    /// different decision and reads as one.
    func revokeInvite(roomId: UUID, handle: String) async throws -> RoomInviteList

    /// Who is in the room, `GET /rooms/{id}/participants`.
    func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList

    // MARK: Hands

    /// Asks for the microphone, `POST /rooms/{id}/hand`. A request, never a
    /// right: the host decides.
    /// - Throws: ``APIErrorCode/alreadySpeaking`` from the stage,
    ///   ``APIErrorCode/scopeNotAllowed`` when the room's rule could never let
    ///   this person speak, ``APIErrorCode/notInRoom`` before joining.
    func raiseHand(roomId: UUID) async throws -> VoiceRoom

    /// Never mind, `DELETE /rooms/{id}/hand`. Idempotent.
    func lowerHand(roomId: UUID) async throws -> VoiceRoom

    /// The host lowers somebody's hand without calling on them,
    /// `DELETE /rooms/{id}/hands/{handle}`. Not a removal, not a mark.
    func dismissHand(roomId: UUID, handle: String) async throws -> VoiceRoom

    /// Mutes a speaker's microphone now, `POST /rooms/{id}/mute`. Host only.
    /// Soft — they keep the seat; ``demote(roomId:handle:)`` is the hard stop.
    func mute(roomId: UUID, handle: String) async throws

    /// Undoes a removal, `POST /rooms/{id}/readmit`. Host only.
    func readmit(roomId: UUID, handle: String) async throws -> VoiceRoom

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
