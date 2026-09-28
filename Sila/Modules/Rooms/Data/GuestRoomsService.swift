import Foundation

/// The production ``GuestRoomsServiceProtocol``: two public routes, no token.
///
/// Built beside ``PublicFeedService`` and for the same person — somebody who
/// has not joined. Nothing here holds or sends a credential: the requests
/// carry no `Authorization` header at all, and the seat's token is handed to
/// the media engine and nowhere else (never logged, never tracked).
public final class GuestRoomsService: GuestRoomsServiceProtocol {

    private let network: NetworkClient
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, analytics: AnalyticsClient) {
        self.network = network
        self.analytics = analytics
    }

    public func fetchRooms(status: RoomStatus, limit: Int) async throws -> [RoomCard] {
        // Only the two the route knows; anything else asks for what is live.
        let wire = status == .scheduled ? "scheduled" : "live"
        let rooms = try await network.send(
            APIRequest(
                path: "/public/rooms",
                query: [
                    URLQueryItem(name: "status", value: wire),
                    URLQueryItem(name: "limit", value: String(min(max(limit, 1), GuestListening.maximumListLimit)))
                ]
            ),
            as: GuestRoomList.self
        ).rooms
        analytics.track(.roomsLoaded, properties: ["count": String(rooms.count), "status": wire, "is_guest": "true"])
        return rooms
    }

    public func listen(roomId: UUID, guestPass: String?) async throws -> GuestSeat {
        let pass = guestPass?.isEmpty == false ? guestPass : nil
        return try await network.sendNotingRetryAfter(
            try APIRequest.json(
                "/public/rooms/\(roomId.uuidString.lowercased())/listen",
                method: .post,
                body: GuestListenBody(guestPass: pass)
            ),
            as: GuestSeat.self
        )
    }
}
