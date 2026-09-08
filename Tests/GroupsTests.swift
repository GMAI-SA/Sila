import XCTest
@testable import Sila

/// Groups: the wire contract, the room's third door, and the editor.
final class GroupsTests: XCTestCase {

    private static let person = """
    {"id": "22222222-0000-4000-8000-000000000002", "handle": "yuki", "display_name": "Yuki", "is_verified": true}
    """
    private static let group = """
    {"id": "33333333-0000-4000-8000-000000000003", "name": "Family", "member_count": 1,
     "members": [\(person)], "created_at": "2026-09-09T08:00:00Z"}
    """
    private static let groupId = UUID(uuidString: "33333333-0000-4000-8000-000000000003")!

    private func service(_ network: StubNetworkClient) -> RoomsService {
        RoomsService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
    }

    // MARK: - Wire

    func testGroupsAreReadFromTheEnvelope() async throws {
        let network = StubNetworkClient(responses: [#"{"groups": [\#(Self.group)]}"#])
        let groups = try await service(network).fetchGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Family")
        XCTAssertEqual(groups.first?.memberCount, 1)
        XCTAssertEqual(groups.first?.members.first?.handle, "yuki")
        XCTAssertEqual(network.lastRequest?.path, "/me/groups")
    }

    func testCreateSendsATidiedNameAndHandles() async throws {
        let network = StubNetworkClient(responses: [Self.group])
        _ = try await service(network).createGroup(name: "  Family ", handles: ["@Yuki", "amy,"])
        let body = try XCTUnwrap(network.lastRequest?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "Family")
        XCTAssertEqual(json["handles"] as? [String], ["yuki", "amy"])
        XCTAssertEqual(network.lastRequest?.path, "/me/groups")
        XCTAssertEqual(network.lastRequest?.method, .post)
    }

    func testMembersAndDeletionUseTheirPaths() async throws {
        let network = StubNetworkClient(responses: [Self.group, Self.group, ""])
        let svc = service(network)
        _ = try await svc.addGroupMembers(id: Self.groupId, handles: ["@Amy"])
        _ = try await svc.removeGroupMember(id: Self.groupId, handle: "@Amy")
        try await svc.deleteGroup(id: Self.groupId)
        let id = Self.groupId.uuidString.lowercased()
        XCTAssertEqual(network.requests[0].path, "/me/groups/\(id)/members")
        XCTAssertEqual(network.requests[0].method, .post)
        XCTAssertEqual(network.requests[1].path, "/me/groups/\(id)/members/amy")
        XCTAssertEqual(network.requests[1].method, .delete)
        XCTAssertEqual(network.requests[2].path, "/me/groups/\(id)")
        XCTAssertEqual(network.requests[2].method, .delete)
    }

    // MARK: - The room's door

    func testARoomForAGroupDecodesAndReadsAsClosed() throws {
        let json = """
        {"id": "11111111-0000-4000-8000-000000000001", "title": "Family call", "scope": "international",
         "status": "live", "host": \(Self.person), "speaker_count": 1, "listener_count": 0,
         "created_at": "2026-09-09T08:00:00Z", "can_speak": true, "is_host": true,
         "group_id": "33333333-0000-4000-8000-000000000003", "group_name": "Family"}
        """
        let room = try JSONCoding.decoder.decode(VoiceRoom.self, from: Data(json.utf8))
        XCTAssertEqual(room.groupId, Self.groupId)
        XCTAssertEqual(room.groupName, "Family")
        XCTAssertTrue(room.isClosed)
        XCTAssertTrue(room.isGroupOnly)
        XCTAssertFalse(room.isInviteOnly)
        XCTAssertEqual(RoomAccess.of(room), .group)
    }

    func testCreateRequestSendsOneDoor() throws {
        let request = CreateRoomRequest(
            title: "Family call", scope: .international, access: .group,
            inviteHandles: ["@amy"], groupId: Self.groupId
        )
        XCTAssertFalse(request.isInviteOnly)
        XCTAssertFalse(request.isFollowingOnly)
        XCTAssertEqual(request.groupId, Self.groupId)
        XCTAssertEqual(request.inviteHandles, ["amy"])
        let body = try JSONCoding.encoder.encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["group_id"] as? String, Self.groupId.uuidString.lowercased())
        XCTAssertNil(json["is_invite_only"])
        XCTAssertEqual(json["invite_handles"] as? [String], ["amy"])

        // Picking another door drops the group even if one was named.
        let open = CreateRoomRequest(title: "Open", scope: .international, access: .open, groupId: Self.groupId)
        XCTAssertNil(open.groupId)
    }

    @MainActor
    func testCreatingARoomForAGroupNeedsAGroupPicked() async {
        let mock = RoomsServiceMock()
        let viewModel = CreateRoomViewModel(
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            service: mock,
            preferences: PreferencesServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        viewModel.title = "Family call"
        viewModel.access = .group
        XCTAssertFalse(viewModel.canCreate)

        await mock.seedGroup(name: "Family", handles: ["yuki"])
        await viewModel.loadGroups()
        // One group is picked for them.
        XCTAssertNotNil(viewModel.selectedGroup)
        XCTAssertTrue(viewModel.canCreate)
    }

    // MARK: - The editor

    @MainActor
    func testTheEditorMakesAGroupThenAddsAndRemovesPeople() async {
        let mock = RoomsServiceMock()
        let viewModel = GroupsViewModel(service: mock, analytics: RecordingAnalyticsClient())
        await viewModel.load()
        XCTAssertTrue(viewModel.groups.isEmpty)

        viewModel.nameText = " Family "
        viewModel.handlesText = "@yuki"
        await viewModel.create()
        XCTAssertEqual(viewModel.groups.map(\.name), ["Family"])
        XCTAssertEqual(viewModel.groups.first?.members.map(\.handle), ["yuki"])
        XCTAssertEqual(viewModel.editingId, viewModel.groups.first?.id)

        viewModel.handlesText = "amy, nobody"
        await viewModel.addMembers()
        // Refused as a whole: the good handle was not added on the side.
        XCTAssertEqual(viewModel.groups.first?.members.count, 1)
        XCTAssertEqual(viewModel.handlesText, "amy, nobody")

        viewModel.handlesText = "amy"
        await viewModel.addMembers()
        XCTAssertEqual(viewModel.groups.first?.members.map(\.handle), ["yuki", "amy"])

        let group = viewModel.groups[0]
        await viewModel.removeMember("yuki", from: group)
        XCTAssertEqual(viewModel.groups.first?.members.map(\.handle), ["amy"])

        viewModel.requestDeletion(viewModel.groups[0])
        await viewModel.confirmDeletion()
        XCTAssertTrue(viewModel.groups.isEmpty)
    }
}
