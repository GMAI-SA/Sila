import Foundation

/// The card a signed-out person sees for a shared room link, before
/// listening (round-2 security finding CA-1).
///
/// The guest API has no single-room read, so the room is looked up on the
/// public lists — live, then coming up — which ask the server nothing about
/// this person and take no seat. A room on neither list (guests turned off,
/// invite-only, gone) still gets a card: Listen then asks for a seat, and
/// the screen says the server's refusal in its own words.
///
/// This model never asks for a seat: ``GuestRoomsServiceProtocol/listen``
/// is the room screen's, reached only through the card's Listen button.
@MainActor
@Observable
public final class GuestRoomLinkViewModel {

    public let roomId: UUID
    /// `nil` until the lists have answered.
    public private(set) var preview: RoomLinkPreview?

    private let service: GuestRoomsServiceProtocol
    @ObservationIgnored private var hasLoaded = false

    public init(roomId: UUID, card: RoomCard? = nil, service: GuestRoomsServiceProtocol) {
        self.roomId = roomId
        self.service = service
        if let card, card.id == roomId { preview = RoomLinkPreview(card: card) }
    }

    /// Looks the room up once. A failed read is the same as an unlisted room.
    public func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard preview == nil else { return }
        for status in [RoomStatus.live, .scheduled] {
            if let cards = try? await service.fetchRooms(status: status, limit: GuestRoomLinkViewModel.lookupLimit),
               let card = cards.first(where: { $0.id == roomId }) {
                preview = RoomLinkPreview(card: card)
                return
            }
        }
        preview = RoomLinkPreview(unlisted: roomId)
    }

    static let lookupLimit = 50
}
