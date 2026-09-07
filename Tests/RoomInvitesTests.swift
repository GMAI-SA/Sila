import XCTest
@testable import Sila

/// Closed rooms on the client: the wire shape, the handle tidying, the guest
/// list, and the line between withdrawing an invitation and removing a person.
@MainActor
final class RoomInvitesTests: XCTestCase {

    // MARK: - Handles

    func testHandlesAreTidiedTheWayPeopleActuallyTypeThem() {
        XCTAssertEqual(RoomInviteHandles.clean("@Aziz, noura"), ["aziz", "noura"])
        XCTAssertEqual(RoomInviteHandles.clean("aziz noura\nomar"), ["aziz", "noura", "omar"])
        XCTAssertEqual(RoomInviteHandles.clean("  @AZIZ  "), ["aziz"])
        XCTAssertEqual(RoomInviteHandles.clean("aziz, aziz, @aziz"), ["aziz"], "one person, once")
        XCTAssertEqual(RoomInviteHandles.clean(""), [])
        XCTAssertEqual(RoomInviteHandles.clean("  ,  , "), [])
    }

    func testTheHandleListIsCappedAtTheServersLimit() {
        let many = (0..<80).map { "person\($0)" }.joined(separator: ",")
        XCTAssertEqual(RoomInviteHandles.clean(many).count, RoomInviteHandles.maximum)
    }

    // MARK: - The room

    func testAClosedRoomDecodesItsOwnFlags() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "title": "A closed conversation",
          "topic": null, "scope": "international", "scope_country": null, "scope_region": null,
          "status": "live",
          "host": {"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c50", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
          "speaker_count": 1, "listener_count": 0, "scheduled_for": null, "started_at": null,
          "created_at": "2026-09-08T09:00:00Z",
          "can_speak": true, "speak_refusal": null, "is_host": false, "is_removed": false,
          "is_invite_only": true, "is_invited": false, "can_join": false,
          "join_refusal": "This room is invite only"
        }
        """
        let room = try JSONCoding.decoder.decode(VoiceRoom.self, from: Data(json.utf8))
        XCTAssertTrue(room.isInviteOnly)
        XCTAssertFalse(room.isInvited)
        XCTAssertFalse(room.canJoin)
        XCTAssertFalse(room.isEnterable)
        XCTAssertEqual(room.joinRefusalMessage, "This room is invite only")
    }

    func testAServerWithoutTheFieldsLeavesTheDoorOpen() throws {
        // Failing closed here would hide Join on every ordinary room.
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "title": "An open conversation",
          "topic": null, "scope": "international", "scope_country": null, "scope_region": null,
          "status": "live",
          "host": {"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c50", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
          "speaker_count": 1, "listener_count": 0, "scheduled_for": null, "started_at": null,
          "created_at": "2026-09-08T09:00:00Z",
          "can_speak": true, "speak_refusal": null, "is_host": false, "is_removed": false
        }
        """
        let room = try JSONCoding.decoder.decode(VoiceRoom.self, from: Data(json.utf8))
        XCTAssertFalse(room.isInviteOnly)
        XCTAssertTrue(room.canJoin)
        XCTAssertTrue(room.isEnterable)
        XCTAssertNil(room.joinRefusalMessage)
    }

    func testRemovalOutranksInviteOnly() {
        let room = VoiceRoom(
            id: UUID(), title: "A closed conversation", status: .live,
            host: FeedServiceMock.aziz, isRemoved: true,
            isInviteOnly: true, canJoin: false, joinRefusal: "This room is invite only"
        )
        XCTAssertEqual(room.joinRefusalMessage, RoomCopy.removedFromRoom)
    }

    // MARK: - Creating

    func testCreatingAClosedRoomSendsTheFlagAndTheGuests() throws {
        let request = CreateRoomRequest(
            title: "A closed conversation",
            scope: .international,
            isInviteOnly: true,
            inviteHandles: ["@Aziz", "noura"]
        )
        let body = String(decoding: try JSONCoding.encoder.encode(request), as: UTF8.self)
        XCTAssertTrue(body.contains("\"is_invite_only\":true"))
        XCTAssertTrue(body.contains("aziz"))
        XCTAssertTrue(body.contains("noura"))
    }

    func testAnOpenRoomSendsNeitherFlagNorGuests() throws {
        // The server refuses invitations to an open room, so sending them
        // would be an error rather than a courtesy.
        let request = CreateRoomRequest(
            title: "An open conversation",
            scope: .international,
            inviteHandles: ["aziz"]
        )
        XCTAssertTrue(request.inviteHandles.isEmpty)
        let body = String(decoding: try JSONCoding.encoder.encode(request), as: UTF8.self)
        XCTAssertFalse(body.contains("is_invite_only"))
        XCTAssertFalse(body.contains("invite_handles"))
    }

    // MARK: - The guest list

    func testTheGuestListDecodesTheServersShape() throws {
        let json = """
        {"room_id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
         "invited": [{"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c51", "handle": "noura",
                      "display_name": "Noura", "is_verified": true}]}
        """
        let list = try JSONCoding.decoder.decode(RoomInviteList.self, from: Data(json.utf8))
        XCTAssertEqual(list.invited.map(\.handle), ["noura"])
    }

    func testInvitingAddsToTheListAndClearsTheField() async {
        let service = RoomsServiceMock()
        let room = await service.seedInviteOnlyRoom()
        let viewModel = RoomInvitesViewModel(roomId: room.id, service: service, analytics: RecordingAnalyticsClient())

        await viewModel.load()
        XCTAssertTrue(viewModel.invited.isEmpty)

        viewModel.handlesText = "@Noura, omar"
        XCTAssertEqual(viewModel.handles, ["noura", "omar"])
        XCTAssertTrue(viewModel.canAdd)
        await viewModel.add()

        XCTAssertEqual(viewModel.invited.map(\.handle), ["noura", "omar"])
        XCTAssertEqual(viewModel.handlesText, "", "the field is spent")
        XCTAssertNotNil(viewModel.toast)
    }

    func testAHandleNobodyHoldsLeavesTheFieldAloneToBeCorrected() async {
        let service = RoomsServiceMock()
        let room = await service.seedInviteOnlyRoom()
        let viewModel = RoomInvitesViewModel(roomId: room.id, service: service, analytics: RecordingAnalyticsClient())

        viewModel.handlesText = "noura, nobody"
        await viewModel.add()

        XCTAssertTrue(viewModel.invited.isEmpty, "the server wrote nothing")
        XCTAssertEqual(viewModel.handlesText, "noura, nobody", "the host has to see what to fix")
        XCTAssertNotNil(viewModel.toast)
    }

    func testWithdrawingRemovesOneGuest() async {
        let service = RoomsServiceMock()
        let room = await service.seedInviteOnlyRoom()
        let viewModel = RoomInvitesViewModel(roomId: room.id, service: service, analytics: RecordingAnalyticsClient())

        viewModel.handlesText = "noura, omar"
        await viewModel.add()
        await viewModel.revoke("noura")

        XCTAssertEqual(viewModel.invited.map(\.handle), ["omar"])
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.contains("revoke:noura"))
        XCTAssertFalse(calls.contains { $0.hasPrefix("remove:") }, "withdrawing is not removing")
    }

    func testAnEmptyFieldSendsNothing() async {
        let service = RoomsServiceMock()
        let room = await service.seedInviteOnlyRoom()
        let viewModel = RoomInvitesViewModel(roomId: room.id, service: service, analytics: RecordingAnalyticsClient())

        viewModel.handlesText = "  ,  "
        XCTAssertFalse(viewModel.canAdd)
        await viewModel.add()
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains { $0.hasPrefix("invite:") })
    }

    // MARK: - Privacy

    func testInviteEventsCarryCountsAndNeverHandles() async {
        let analytics = RecordingAnalyticsClient()
        let service = RoomsServiceMock()
        let room = await service.seedInviteOnlyRoom()
        let viewModel = RoomInvitesViewModel(roomId: room.id, service: service, analytics: analytics)
        viewModel.handlesText = "noura, omar"
        await viewModel.add()

        for entry in analytics.recorded {
            for (_, value) in entry.properties {
                XCTAssertFalse(value.contains("noura"), "\(entry.event) leaked a handle")
                XCTAssertFalse(value.contains("omar"), "\(entry.event) leaked a handle")
            }
        }
    }
}
