import XCTest
@testable import Sila

/// The member's side of contract v31: "Guests can listen · N guests
/// listening" on a room, and the host's and co-hosts' switch — in the live
/// room's settings (`PATCH /rooms/{id}`) and in the create-room sheet.
final class RoomGuestsSwitchTests: XCTestCase {

    // MARK: - Creating a room

    func testCreatingARoomSaysWhetherGuestsMayListen() throws {
        var request = CreateRoomRequest(title: "Morning", scope: .international)
        var json = try body(request)
        XCTAssertNil(json["allow_guests"], "nothing said leaves the server's default")

        request.allowGuests = false
        json = try body(request)
        XCTAssertEqual(json["allow_guests"] as? Bool, false)

        // What the sheet always set now travels too: the question, the kind,
        // the community.
        request.starterQuestion = "Best coffee?"
        request.kind = "ama"
        json = try body(request)
        XCTAssertEqual(json["starter_question"] as? String, "Best coffee?")
        XCTAssertEqual(json["kind"] as? String, "ama")
    }

    @MainActor
    func testTheCreateSheetOffersTheSwitchForAnOpenRoomOnly() async throws {
        let rooms = RoomsServiceMock(scenario: .populated)
        let viewModel = CreateRoomViewModel(
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            service: rooms,
            preferences: PreferencesServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            engagement: RoomEngagementServiceMock()
        )
        XCTAssertTrue(viewModel.allowGuests, "on by default, as the server's own default is")
        XCTAssertTrue(viewModel.offersGuestsSwitch)

        viewModel.access = .inviteOnly
        XCTAssertFalse(viewModel.offersGuestsSwitch, "a closed room has no guests to allow")
        viewModel.access = .open
        viewModel.isScheduled = true
        viewModel.repeatsWeekly = true
        XCTAssertFalse(viewModel.offersGuestsSwitch, "a weekly series has no switch of its own")
        viewModel.repeatsWeekly = false
        viewModel.isScheduled = false

        viewModel.title = "Open to guests"
        viewModel.allowGuests = false
        let closedToGuests = try await XCTUnwrapAsync(await viewModel.create())
        XCTAssertFalse(closedToGuests.allowGuests)

        viewModel.title = "Guests welcome"
        viewModel.allowGuests = true
        let open = try await XCTUnwrapAsync(await viewModel.create())
        XCTAssertTrue(open.allowGuests)

        viewModel.title = "Invited only"
        viewModel.access = .inviteOnly
        let closed = try await XCTUnwrapAsync(await viewModel.create())
        XCTAssertFalse(closed.allowGuests, "a closed room was opened to guests")
    }

    // MARK: - The switch

    func testTheSwitchIsAPatchOfTheRoom() async throws {
        let network = StubNetworkClient(responses: [#"{"id": "00000000-0000-4000-8000-000000000701", "title": "Live", "status": "live", "host": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz"}, "allow_guests": false}"#])
        let service = RoomsService(network: network, tokens: StaticAccessTokenProvider(token: "access-1"), analytics: RecordingAnalyticsClient())
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000701")!

        let room = try await service.setAllowGuests(false, roomId: id)

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.method, .patch)
        XCTAssertEqual(request.path, "/rooms/00000000-0000-4000-8000-000000000701")
        XCTAssertEqual(request.accessToken, "access-1")
        let sent = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["allow_guests"] as? Bool, false)
        XCTAssertEqual(sent?.count, 1, "the switch changed something besides itself")
        XCTAssertFalse(room.allowGuests)
    }

    @MainActor
    func testTheHostTurnsGuestsOffAndTheRoomSaysSo() async throws {
        let service = RoomsServiceMock(scenario: .hosting)
        let hosted = try await XCTUnwrapAsync(try await service.fetchRooms(status: .live).first)
        XCTAssertTrue(hosted.allowGuests)
        XCTAssertEqual(hosted.guestCount, 12)
        L10n.withLanguage("en") {
            XCTAssertEqual(RoomCopy.guestsLine(hosted), "Guests can listen · 12 guests listening")
        }

        let viewModel = LiveRoomViewModel(
            room: hosted, viewerHandle: "aziz", service: service, engine: VoiceEngineMock(),
            analytics: RecordingAnalyticsClient(), pollInterval: 0
        )
        XCTAssertTrue(viewModel.canManageRoom)
        XCTAssertTrue(viewModel.allowsGuests)

        await viewModel.setAllowGuests(false)
        XCTAssertFalse(viewModel.room.allowGuests)
        XCTAssertEqual(viewModel.room.guestCount, 0, "turning guests off takes them out")
        XCTAssertNil(viewModel.guestsError)
        L10n.withLanguage("en") {
            XCTAssertNil(viewModel.guestsLine)
        }
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.contains("allowGuests:false"))

        await viewModel.setAllowGuests(true)
        XCTAssertTrue(viewModel.room.allowGuests)
    }

    @MainActor
    func testAClosedRoomCannotBeOpenedToGuestsAndSaysWhy() async throws {
        let service = RoomsServiceMock(scenario: .populated)
        let closed = await service.seedInviteOnlyRoom()
        XCTAssertFalse(closed.allowGuests)
        let viewModel = LiveRoomViewModel(
            room: closed, viewerHandle: "aziz", service: service, engine: VoiceEngineMock(),
            analytics: RecordingAnalyticsClient(), pollInterval: 0
        )
        XCTAssertNotNil(viewModel.guestsBlockedReason)

        await viewModel.setAllowGuests(true)
        XCTAssertFalse(viewModel.room.allowGuests)
        L10n.withLanguage("en") {
            XCTAssertEqual(viewModel.guestsError, L10n.t("rooms.guests.allow.closed"))
        }
    }

    @MainActor
    func testOnlyTheHostAndCoHostsSeeTheSwitch() async throws {
        let service = RoomsServiceMock(scenario: .populated)
        let room = try await XCTUnwrapAsync(try await service.fetchRooms(status: .live).first)
        let listener = LiveRoomViewModel(
            room: room, viewerHandle: "aziz", service: service, engine: VoiceEngineMock(),
            analytics: RecordingAnalyticsClient(), pollInterval: 0
        )
        XCTAssertFalse(listener.canManageRoom)
        await listener.setAllowGuests(false)
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("allowGuests:false"), "a listener changed the room")
    }

    func testTheServersRefusalsAreSaidInWords() {
        L10n.withLanguage("en") {
            XCTAssertEqual(APIError.api(code: .privateHost, message: "", status: 409).userMessage,
                           "The host's account is private, so guests can't listen.")
            XCTAssertEqual(APIError.api(code: .roomClosed, message: "", status: 409).userMessage,
                           "Only an open room can have guests. This room is limited to the people its host chose.")
        }
        L10n.withLanguage("ar") {
            XCTAssertEqual(APIError.api(code: .guestsFull, message: "", status: 409).userMessage,
                           "لم يبقَ مقعد للزوار في هذه الغرفة")
        }
        XCTAssertEqual(APIErrorCode(serverCode: "guests_not_allowed"), .guestsNotAllowed)
        XCTAssertEqual(APIErrorCode(serverCode: "private_host"), .privateHost)
    }

    // MARK: - Links

    func testASharedRoomLinkIsARoom() {
        let link = DeepLink.parse(URL(string: "https://sila.gmai.sa/rooms/00000000-0000-4000-8000-000000000701")!)
        XCTAssertEqual(link, .room(id: UUID(uuidString: "00000000-0000-4000-8000-000000000701")!))
    }

    // MARK: - Helpers

    private func body(_ request: CreateRoomRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(request)) as? [String: Any])
    }
}

/// `XCTUnwrap` for an expression that has to be awaited first.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
