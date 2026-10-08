import XCTest
@testable import Sila

/// A room opened from outside the app stops at its card (round-2 security
/// finding CA-1): a universal link, a push or an invitation row never joins
/// a room, or takes a guest's seat in one, until the person taps Join or
/// Listen. Joining shows the person to the host by verified name.
@MainActor
final class RoomLinkTests: XCTestCase {

    private static let liveId = UUID(uuidString: "00000000-0000-4000-8000-000000000702")!
    private static let scheduledId = UUID(uuidString: "00000000-0000-4000-8000-000000000704")!
    private static let unlistedId = UUID(uuidString: "00000000-0000-4000-8000-000000000999")!

    private func room(_ id: UUID) throws -> VoiceRoom {
        try XCTUnwrap(RoomsServiceMock.cast.first { $0.id == id })
    }

    // MARK: - Where a room opens

    func testARoomFromALinkOrAPushOpensOnItsCardNotInTheRoom() throws {
        let room = try room(Self.liveId)
        XCTAssertEqual(RoomsRoute.opening(room, from: .outside), .roomLink(room))
        XCTAssertNotEqual(RoomsRoute.opening(room, from: .outside), .room(room),
                          "a link must never push the room screen, which joins on appear")
    }

    func testARoomChosenInsideTheAppIsJoinedAtOnce() throws {
        let room = try room(Self.liveId)
        XCTAssertEqual(RoomsRoute.opening(room, from: .inApp), .room(room))
        XCTAssertTrue(RoomOpenOrigin.inApp.joinsAtOnce)
        XCTAssertFalse(RoomOpenOrigin.outside.joinsAtOnce)
    }

    func testEveryRoomLinkTheAppReadsIsARoomTheCardGuards() throws {
        for raw in [
            "https://sila.gmai.sa/rooms/00000000-0000-4000-8000-000000000702",
            "https://SILA.gmai.sa/rooms/00000000-0000-4000-8000-000000000702/",
        ] {
            XCTAssertEqual(DeepLink.parse(try XCTUnwrap(URL(string: raw))), .room(id: Self.liveId), raw)
        }
        // No custom scheme and no other host can name a room at all.
        for raw in [
            "sila://rooms/00000000-0000-4000-8000-000000000702",
            "http://sila.gmai.sa/rooms/00000000-0000-4000-8000-000000000702",
            "https://sila.gmai.sa.evil.example/rooms/00000000-0000-4000-8000-000000000702",
        ] {
            XCTAssertNil(DeepLink.parse(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    // MARK: - The card

    func testTheCardShowsTheRoomAndItsHost() throws {
        let room = try room(Self.liveId)
        let preview = RoomLinkPreview(room: room)
        XCTAssertEqual(preview.id, room.id)
        XCTAssertEqual(preview.title, room.title)
        XCTAssertEqual(preview.hostName, room.host.displayName)
        XCTAssertEqual(preview.peopleCount, room.speakerCount + room.listenerCount)
        XCTAssertTrue(preview.canEnter)
    }

    func testARoomThatIsNotLiveOffersNoJoin() throws {
        XCTAssertFalse(RoomLinkPreview(room: try room(Self.scheduledId)).canEnter)
    }

    // MARK: - A guest's card

    func testAGuestsLinkLooksTheRoomUpWithoutTakingASeat() async throws {
        let service = GuestRoomsServiceMock()
        let link = GuestRoomLinkViewModel(roomId: Self.liveId, service: service)
        XCTAssertNil(link.preview)
        await link.load()

        XCTAssertEqual(link.preview?.id, Self.liveId)
        XCTAssertEqual(link.preview?.status, .live)
        XCTAssertNotNil(link.preview?.title)
        XCTAssertTrue(link.preview?.canEnter ?? false)
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains { $0.hasPrefix("listen:") }, "opening a link took a seat: \(calls)")
    }

    func testAGuestsLinkToAComingRoomFindsItOnTheComingList() async throws {
        let service = GuestRoomsServiceMock()
        let link = GuestRoomLinkViewModel(roomId: Self.scheduledId, service: service)
        await link.load()
        XCTAssertEqual(link.preview?.status, .scheduled)
        XCTAssertFalse(link.preview?.canEnter ?? true)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["rooms:live", "rooms:scheduled"])
    }

    func testAnUnlistedRoomStillGetsACardAndNoSeat() async throws {
        let service = GuestRoomsServiceMock()
        let link = GuestRoomLinkViewModel(roomId: Self.unlistedId, service: service)
        await link.load()
        XCTAssertEqual(link.preview, RoomLinkPreview(unlisted: Self.unlistedId))
        XCTAssertTrue(link.preview?.canEnter ?? false, "Listen lets the server say why")
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains { $0.hasPrefix("listen:") })
    }

    func testAnOfflineLookupIsAnUnlistedCardNotASeat() async throws {
        let service = GuestRoomsServiceMock(scenario: .offline)
        let link = GuestRoomLinkViewModel(roomId: Self.liveId, service: service)
        await link.load()
        XCTAssertEqual(link.preview, RoomLinkPreview(unlisted: Self.liveId))
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains { $0.hasPrefix("listen:") })
    }

    func testACardFromTheTapIsUsedWithoutAsking() async throws {
        let service = GuestRoomsServiceMock()
        let card = try XCTUnwrap(GuestRoomsServiceMock.liveCards.first)
        let link = GuestRoomLinkViewModel(roomId: card.id, card: card, service: service)
        await link.load()
        XCTAssertEqual(link.preview, RoomLinkPreview(card: card))
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
    }
}
