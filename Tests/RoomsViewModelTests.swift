import XCTest
@testable import Sila

/// ``RoomsViewModel``: the two lists, the search, and what happens at the door.
@MainActor
final class RoomsViewModelTests: XCTestCase {

    private func makeViewModel(
        _ scenario: RoomsServiceMock.MockScenario = .populated,
        service: RoomsServiceProtocol? = nil
    ) -> RoomsViewModel {
        RoomsViewModel(
            service: service ?? RoomsServiceMock(scenario: scenario),
            analytics: RecordingAnalyticsClient(),
            debounce: 0
        )
    }

    // MARK: - Loading

    func testLoadingSplitsLiveFromScheduled() async {
        let viewModel = makeViewModel()
        await viewModel.load()

        XCTAssertEqual(viewModel.live.count, 3)
        XCTAssertEqual(viewModel.scheduled.count, 2)
        XCTAssertTrue(viewModel.live.allSatisfy { $0.status == .live })
        XCTAssertTrue(viewModel.scheduled.allSatisfy { $0.status == .scheduled })
        XCTAssertNil(viewModel.loadError)
    }

    /// Soonest first, so the thing about to happen is at the top.
    func testScheduledRoomsAreSortedBySoonest() async {
        let viewModel = makeViewModel()
        await viewModel.load()

        let times = viewModel.scheduled.compactMap(\.scheduledFor)
        XCTAssertEqual(times, times.sorted())
    }

    /// **The list is never filtered by who may speak.** Every room is open to
    /// every listener, and hiding the ones somebody cannot speak in would turn
    /// a speaking rule into a visibility rule.
    func testRoomsTheViewerCannotSpeakInAreStillListed() async {
        let viewModel = makeViewModel(.listenerOnly)
        await viewModel.load()

        XCTAssertEqual(viewModel.live.count, 3, "rooms were hidden for being unspeakable")
        XCTAssertTrue(viewModel.live.allSatisfy { !$0.canSpeak })
        XCTAssertTrue(
            viewModel.live.allSatisfy { $0.speakRefusalMessage != nil },
            "an unspeakable room had nothing to say for itself"
        )
    }

    func testLoadIsIdempotentButReloadIsNot() async {
        let service = RoomsServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await viewModel.load()
        // One reload, two calls: live and scheduled are separate predicates,
        // and splitting a mixed page on the client would show "the scheduled
        // ones out of the thirty I happen to have".
        let afterLoads = await service.recordedCalls
        XCTAssertEqual(
            afterLoads.filter { $0.hasPrefix("fetchRooms") }.count, 2,
            "the second load refetched over somebody's place in the list"
        )

        await viewModel.reload(isRefresh: true)
        let afterReload = await service.recordedCalls
        XCTAssertEqual(afterReload.filter { $0.hasPrefix("fetchRooms") }.count, 4)
    }

    func testAFailureLeavesAnErrorAndNoRows() async {
        let viewModel = makeViewModel(.offline)
        await viewModel.load()

        XCTAssertTrue(viewModel.live.isEmpty)
        XCTAssertNotNil(viewModel.loadError)
        guard case .failed = viewModel.emptyKind else {
            return XCTFail("a transport failure did not read as failed")
        }
    }

    func testAnEmptyServerReadsAsNoRoomsRatherThanAnError() async {
        let viewModel = makeViewModel(.empty)
        await viewModel.load()

        XCTAssertEqual(viewModel.emptyKind, .noRooms)
        XCTAssertNil(viewModel.loadError)
    }

    // MARK: - Search

    func testSearchingReplacesTheListsWithResults() async {
        let viewModel = makeViewModel()
        await viewModel.load()

        viewModel.updateQuery("Riyadh", immediately: true)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertTrue(viewModel.isSearchActive)
        XCTAssertEqual(viewModel.visibleLive.count, 1)
        XCTAssertTrue(viewModel.visibleScheduled.isEmpty, "search showed a section it does not have")
    }

    func testAOneCharacterQueryIsNamedRatherThanCalledNoResults() async {
        let viewModel = makeViewModel()
        await viewModel.load()

        viewModel.updateQuery("R")

        XCTAssertEqual(viewModel.emptyKind, .queryTooShort)
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testClearingSearchRestoresBothLists() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.updateQuery("Riyadh", immediately: true)
        try? await Task.sleep(nanoseconds: 60_000_000)

        viewModel.clearSearch()

        XCTAssertFalse(viewModel.isSearchActive)
        XCTAssertEqual(viewModel.visibleLive.count, 3)
        XCTAssertEqual(viewModel.visibleScheduled.count, 2)
    }

    // MARK: - The door

    func testJoiningALiveRoomHandsBackAToken() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first)

        let join = await viewModel.open(room)

        let unwrapped = try XCTUnwrap(join)
        XCTAssertEqual(unwrapped.url, "wss://sila.gmai.sa/rtc")
        XCTAssertFalse(unwrapped.token.isEmpty)
    }

    /// A room the viewer cannot speak in is still **joinable**, and the token
    /// that comes back is a listener's.
    func testARoomTheViewerCannotSpeakInIsStillJoinableAsAListener() async throws {
        let viewModel = makeViewModel(.listenerOnly)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first)

        let opened = await viewModel.open(room)

        let join = try XCTUnwrap(opened)
        XCTAssertEqual(join.role, .listener)
        XCTAssertFalse(join.canPublish, "a listener's token claimed publishing rights")
    }

    /// **`removed_from_room` produces its own message, and it is not a block's.**
    func testBeingRemovedFromARoomSaysSoAndNeverSaysBlocked() async throws {
        let viewModel = makeViewModel(.removed)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first { $0.isRemoved })

        let join = await viewModel.open(room)

        XCTAssertNil(join, "a removed viewer was let in")
        let toast = try XCTUnwrap(viewModel.toast)
        XCTAssertEqual(toast.text, RoomCopy.removedFromRoom)
        XCTAssertTrue(toast.text.contains("isn't a block"))
        XCTAssertNotEqual(
            toast.text,
            APIError.api(code: .blocked, message: "", status: 403).userMessage
        )
    }

    /// A scheduled room is not joinable, and saying so costs no round trip.
    func testAScheduledRoomIsNotJoined() async throws {
        let service = RoomsServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.scheduled.first)

        let join = await viewModel.open(room)

        XCTAssertNil(join)
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("join"), "a scheduled room was sent to the join endpoint")
        XCTAssertNotNil(viewModel.toast)
    }

    /// **`room_ended` on join.** The row goes, because it is stale by
    /// definition and leaving it invites a second identical failure.
    func testAnEndedRoomSaysSoAndLeavesTheList() async throws {
        let service = EndedRoomService()
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first)

        let join = await viewModel.open(room)

        XCTAssertNil(join)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.roomEnded)
        XCTAssertFalse(
            viewModel.live.contains { $0.id == room.id },
            "an ended room stayed on the list"
        )
    }

    // MARK: - Insertion

    func testAFreshlyCreatedRoomLandsInTheSectionItsStatusSays() async {
        let viewModel = makeViewModel(.empty)
        await viewModel.load()

        let liveRoom = VoiceRoom(id: UUID(), title: "Now", status: .live, host: FeedServiceMock.aziz, isHost: true)
        let laterRoom = VoiceRoom(
            id: UUID(), title: "Later", status: .scheduled, host: FeedServiceMock.aziz,
            scheduledFor: Date().addingTimeInterval(3_600), isHost: true
        )
        viewModel.insert(liveRoom)
        viewModel.insert(laterRoom)

        XCTAssertEqual(viewModel.live.map(\.title), ["Now"])
        XCTAssertEqual(viewModel.scheduled.map(\.title), ["Later"])
    }
}

/// A service whose rooms have all ended by the time somebody knocks.
private actor EndedRoomService: RoomsServiceProtocol {

    private let backing = RoomsServiceMock(scenario: .populated)

    func createRoom(_ request: CreateRoomRequest) async throws -> VoiceRoom {
        try await backing.createRoom(request)
    }

    func fetchRooms(status: RoomStatus?, topic: String?, limit: Int) async throws -> [VoiceRoom] {
        try await backing.fetchRooms(status: status, topic: topic, limit: limit)
    }

    func fetchRoom(id: UUID) async throws -> VoiceRoom {
        try await backing.fetchRoom(id: id)
    }

    func join(roomId: UUID) async throws -> RoomJoin {
        throw APIError.api(code: .roomEnded, message: "Room ended", status: 409)
    }

    func leave(roomId: UUID) async throws {}

    func endRoom(id: UUID) async throws -> VoiceRoom { try await backing.endRoom(id: id) }

    func promote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        try await backing.promote(roomId: roomId, handle: handle)
    }

    func demote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        try await backing.demote(roomId: roomId, handle: handle)
    }

    func remove(roomId: UUID, handle: String) async throws -> VoiceRoom {
        try await backing.remove(roomId: roomId, handle: handle)
    }

    func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList {
        try await backing.fetchParticipants(roomId: roomId)
    }

    func searchRooms(query: String, limit: Int) async throws -> [VoiceRoom] {
        try await backing.searchRooms(query: query, limit: limit)
    }
}
