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

    /// The list never joins. A live, open room is simply handed to the room
    /// screen, which joins under a connecting header.
    func testALiveRoomOpensWithoutARoundTrip() async throws {
        let service = RoomsServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first)

        XCTAssertTrue(viewModel.open(room))

        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("join"), "the list joined; that is the room screen's job")
        XCTAssertNil(viewModel.toast)
    }

    /// A room the viewer cannot speak in is still **enterable** — scope
    /// governs the microphone, never the door.
    func testARoomTheViewerCannotSpeakInStillOpens() async throws {
        let viewModel = makeViewModel(.listenerOnly)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first)
        XCTAssertFalse(room.canSpeak)
        XCTAssertTrue(viewModel.open(room))
    }

    /// **A removal produces its own message, and it is not a block's.**
    func testBeingRemovedFromARoomSaysSoAndNeverSaysBlocked() async throws {
        let viewModel = makeViewModel(.removed)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.live.first { $0.isRemoved })

        XCTAssertFalse(viewModel.open(room), "a removed viewer was let in")
        let toast = try XCTUnwrap(viewModel.toast)
        XCTAssertEqual(toast.text, RoomCopy.removedFromRoom)
        XCTAssertTrue(toast.text.contains("isn't a block"))
        XCTAssertNotEqual(
            toast.text,
            APIError.api(code: .blocked, message: "", status: 403).userMessage
        )
    }

    /// A closed door the server already described stays shut on the card,
    /// with the server's own sentence, and costs no round trip.
    func testAClosedRoomTheViewerMayNotEnterDoesNotOpen() async throws {
        let service = RoomsServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)
        let shut = VoiceRoom(
            id: UUID(), title: "A closed conversation", host: FeedServiceMock.yuki,
            isInviteOnly: true, canJoin: false, joinRefusal: "This room is invite only"
        )
        XCTAssertFalse(viewModel.open(shut))
        XCTAssertEqual(viewModel.toast?.text, "This room is invite only")
        let following = VoiceRoom(
            id: UUID(), title: "My circle", host: FeedServiceMock.yuki,
            canJoin: false, isFollowingOnly: true
        )
        XCTAssertFalse(viewModel.open(following))
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.followingOnlyRefusal)
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("join"))
    }

    /// A scheduled room is not joinable, and saying so costs no round trip.
    func testAScheduledRoomIsNotJoined() async throws {
        let service = RoomsServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        let room = try XCTUnwrap(viewModel.scheduled.first)

        XCTAssertFalse(viewModel.open(room))
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("join"), "a scheduled room was sent to the join endpoint")
        XCTAssertNotNil(viewModel.toast)
    }

    /// An ended room says so.
    func testAnEndedRoomSaysSo() async throws {
        let viewModel = makeViewModel()
        let ended = VoiceRoom(id: UUID(), title: "Over", status: .ended, host: FeedServiceMock.yuki)
        XCTAssertFalse(viewModel.open(ended))
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.roomEnded)
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

