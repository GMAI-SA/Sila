import XCTest
@testable import Sila

/// ``LiveRoomViewModel``: the microphone gate, the host controls, and the two
/// halves of leaving.
///
/// These are the tests the feature exists to keep honest. A listener's token
/// carries `canPublish: false` and the media server drops their audio no matter
/// what the UI does — so the UI must never offer the control, and the engine
/// must refuse it if it somehow does.
@MainActor
final class LiveRoomViewModelTests: XCTestCase {

    private static let roomId = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!

    private func room(
        canSpeak: Bool,
        isHost: Bool = false,
        status: RoomStatus = .live,
        isRemoved: Bool = false,
        refusal: String? = nil
    ) -> VoiceRoom {
        VoiceRoom(
            id: Self.roomId,
            title: "What verification actually changes",
            topic: "technology",
            status: status,
            host: isHost ? FeedServiceMock.aziz : FeedServiceMock.yuki,
            speakerCount: 2,
            listenerCount: 9,
            startedAt: Date().addingTimeInterval(-600),
            canSpeak: canSpeak,
            speakRefusal: refusal,
            isHost: isHost,
            isRemoved: isRemoved
        )
    }

    private func join(_ room: VoiceRoom, role: RoomRole) -> RoomJoin {
        RoomJoin(room: room, url: "wss://sila.gmai.sa/rtc", token: "token.\(role.rawValue)", role: role)
    }

    /// Builds a view model over a service that actually serves the room the
    /// join names — anything else and the first refresh would 404 the room out
    /// from under every assertion.
    private func makeViewModel(
        room: VoiceRoom,
        role: RoomRole,
        engine: VoiceEngineMock? = nil,
        viewerHandle: String = "aziz"
    ) -> (LiveRoomViewModel, VoiceEngineMock, ScriptedRoomService) {
        let engine = engine ?? VoiceEngineMock()
        let service = ScriptedRoomService(room: room, viewerRole: role)
        let viewModel = LiveRoomViewModel(
            join: join(room, role: role),
            viewerHandle: viewerHandle,
            service: service,
            engine: engine,
            analytics: RecordingAnalyticsClient(),
            // Polling off: `refresh()` is driven by hand so the assertions are
            // about what changed, not about when a timer happened to fire.
            pollInterval: 0
        )
        return (viewModel, engine, service)
    }

    // MARK: - The microphone gate

    /// **The assertion the whole feature turns on.** A listener's role means no
    /// microphone affordance, and the engine refuses the call if one is made.
    func testAListenersTokenIsRejectedForPublishing() async throws {
        let listenerRoom = room(
            canSpeak: false,
            refusal: "Only 🇸🇦 Saudi Arabia-verified accounts can speak in this room. You can still listen."
        )
        let (viewModel, engine, _) = makeViewModel(room: listenerRoom, role: .listener)
        await viewModel.start()

        // The affordance is not drawn…
        XCTAssertFalse(viewModel.canUseMicrophone, "a listener was offered a microphone")
        XCTAssertTrue(viewModel.isListening)

        // …and the engine was told what the token permits.
        XCTAssertFalse(engine.connectedCanPublish)
        XCTAssertTrue(engine.recordedCalls.contains("connect:listener"))

        // …and if the control were somehow reached, it does nothing.
        await viewModel.toggleMicrophone()
        XCTAssertFalse(viewModel.isMicrophoneEnabled)
        XCTAssertFalse(
            engine.recordedCalls.contains("mic:on"),
            "the view model asked a listener's connection to publish"
        )

        // The engine itself is the second line: even called directly it refuses,
        // which is what the media server would do with this token anyway.
        do {
            try await engine.setMicrophoneEnabled(true)
            XCTFail("a listener's connection accepted a publish")
        } catch let error as VoiceEngineError {
            XCTAssertEqual(error, .notPermittedToPublish)
        }
    }

    /// The mirror image: a speaker's role does draw the control, and using it
    /// publishes.
    func testASpeakersTokenPublishes() async throws {
        let (viewModel, engine, _) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()

        XCTAssertTrue(viewModel.canUseMicrophone)
        XCTAssertFalse(viewModel.isListening)
        XCTAssertNil(viewModel.speakRefusal)
        XCTAssertTrue(engine.connectedCanPublish)

        await viewModel.toggleMicrophone()

        XCTAssertTrue(viewModel.isMicrophoneEnabled)
        XCTAssertTrue(engine.recordedCalls.contains("mic:on"))

        await viewModel.toggleMicrophone()
        XCTAssertFalse(viewModel.isMicrophoneEnabled)
        XCTAssertTrue(engine.recordedCalls.contains("mic:off"))
    }

    /// **`role` wins over `can_speak` when the two disagree.** The token is
    /// what the media server enforces; a room object claiming otherwise cannot
    /// conjure publishing rights.
    func testTheRoleWinsOverCanSpeakWhenTheTwoDisagree() async {
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()

        XCTAssertFalse(
            viewModel.canUseMicrophone,
            "the mic was offered on a token that cannot publish"
        )
    }

    /// A room that is not live offers no microphone even to somebody the server
    /// says may speak — there is nothing to speak into.
    func testAnEndedRoomOffersNoMicrophone() async {
        let (viewModel, _, _) = makeViewModel(
            room: room(canSpeak: true, status: .ended), role: .speaker
        )
        XCTAssertFalse(viewModel.canUseMicrophone)
    }

    /// **Microphone permission is asked only when somebody takes the
    /// microphone.** Entering a room must never prompt: a listener needs no
    /// device.
    func testEnteringARoomNeverAsksForTheMicrophone() async {
        let engine = VoiceEngineMock(isPermissionGranted: false)
        let (viewModel, _, _) = makeViewModel(
            room: room(canSpeak: false), role: .listener, engine: engine
        )

        await viewModel.start()

        XCTAssertEqual(engine.recordedCalls, ["connect:listener"])
        XCTAssertFalse(
            engine.recordedCalls.contains { $0.hasPrefix("mic:") },
            "entering a room touched the microphone"
        )
    }

    /// A denied prompt is a warning about the microphone, not an error about
    /// the room — the person is still hearing everything.
    func testDeniedMicrophonePermissionKeepsTheRoomAndExplainsItself() async throws {
        let engine = VoiceEngineMock(isPermissionGranted: false)
        let (viewModel, _, _) = makeViewModel(
            room: room(canSpeak: true), role: .speaker, engine: engine
        )
        await viewModel.start()

        await viewModel.toggleMicrophone()

        XCTAssertFalse(viewModel.isMicrophoneEnabled)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.microphoneDenied)
        XCTAssertEqual(viewModel.toast?.kind, .warning)
        XCTAssertEqual(viewModel.connection, .connected, "a denied prompt disconnected the room")
    }

    /// The refusal on screen is the **server's sentence**, unedited.
    func testTheListenerSeesTheServersRefusalVerbatim() async {
        let sentence = "Only accounts verified in the GCC region can speak in this room. You can still listen."
        let (viewModel, _, _) = makeViewModel(
            room: room(canSpeak: false, refusal: sentence), role: .listener
        )
        await viewModel.start()

        XCTAssertEqual(viewModel.speakRefusal, sentence)
    }

    /// When the server sent no sentence there is still one, and it says the
    /// same thing: listening is fine, speaking is not.
    func testAMissingRefusalStillExplainsItself() async {
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: false), role: .listener)
        await viewModel.start()

        XCTAssertEqual(viewModel.speakRefusal, RoomCopy.speakRefusalFallback)
        XCTAssertTrue(viewModel.speakRefusal?.lowercased().contains("listen") == true)
    }

    // MARK: - Host controls

    /// **Host-only controls are absent for a non-host** — not disabled, absent.
    /// A greyed-out "Remove" teaches somebody the room has a hierarchy they can
    /// reach into, which it does not.
    func testANonHostGetsNoHostMenuForAnybody() async {
        let (viewModel, _, _) = makeViewModel(
            room: room(canSpeak: true, isHost: false), role: .speaker
        )
        await viewModel.start()

        XCTAssertFalse(viewModel.isHost)
        XCTAssertFalse(viewModel.participants.participants.isEmpty, "no roster to test against")
        for participant in viewModel.participants.participants {
            XCTAssertNil(
                viewModel.hostActions(for: participant),
                "a non-host was offered controls over \(participant.user.handle)"
            )
        }
    }

    func testAHostGetsAMenuForEverybodyExceptThemselves() async throws {
        let hosted = room(canSpeak: true, isHost: true)
        let (viewModel, _, _) = makeViewModel(room: hosted, role: .host)
        await viewModel.start()

        XCTAssertTrue(viewModel.isHost)
        let others = viewModel.participants.participants.filter { $0.user.handle != "aziz" }
        XCTAssertFalse(others.isEmpty)
        for participant in others {
            XCTAssertNotNil(viewModel.hostActions(for: participant))
        }
        let own = try XCTUnwrap(
            viewModel.participants.participants.first { $0.user.handle == "aziz" }
        )
        XCTAssertNil(viewModel.hostActions(for: own), "the host was offered a menu about themselves")
    }

    /// The menu's entries follow the person's role: you invite listeners up,
    /// move speakers down, and never demote the host.
    func testTheHostMenuOffersOnlyWhatAppliesToThatPerson() {
        let listener = RoomHostActions(
            target: SafetyTarget(user: FeedServiceMock.maria), role: .listener, isBusy: false
        )
        XCTAssertTrue(listener.canPromote)
        XCTAssertFalse(listener.canDemote)
        XCTAssertTrue(listener.canRemove)

        let speaker = RoomHostActions(
            target: SafetyTarget(user: FeedServiceMock.maria), role: .speaker, isBusy: false
        )
        XCTAssertFalse(speaker.canPromote)
        XCTAssertTrue(speaker.canDemote)
        XCTAssertTrue(speaker.canRemove)

        let host = RoomHostActions(
            target: SafetyTarget(user: FeedServiceMock.yuki), role: .host, isBusy: false
        )
        XCTAssertFalse(host.canDemote, "the host was offered a way off their own stage")
        XCTAssertFalse(host.canRemove, "the host was offered a way to remove themselves")
    }

    /// Removing somebody is described as a room-scoped act, and the sentence
    /// says they can go elsewhere. It is never called a block.
    func testRemovingSomebodySaysItAppliesToThisRoomOnly() async throws {
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()

        let target = try XCTUnwrap(
            viewModel.participants.participants.first { $0.user.handle == "maria" }
        )
        let actions = try XCTUnwrap(viewModel.hostActions(for: target))
        await viewModel.remove(actions)

        let toast = try XCTUnwrap(viewModel.toast)
        XCTAssertTrue(toast.text.contains("other rooms"))
        XCTAssertFalse(toast.text.lowercased().contains("block"))
    }

    /// Ending a room is behind a confirmation, and asking is not doing.
    func testAskingToEndARoomEndsNothing() async {
        let (viewModel, _, service) = makeViewModel(
            room: room(canSpeak: true, isHost: true), role: .host
        )
        await viewModel.start()

        viewModel.requestEnd()

        XCTAssertTrue(viewModel.isConfirmingEnd)
        let ends = await service.calls.filter { $0 == "end" }
        XCTAssertTrue(ends.isEmpty, "the confirmation ended the room by itself")
    }

    /// Ending it does end it, and the host leaves properly like anybody else.
    func testEndingARoomAlsoLeavesIt() async {
        let (viewModel, engine, service) = makeViewModel(
            room: room(canSpeak: true, isHost: true), role: .host
        )
        await viewModel.start()

        await viewModel.endRoom()

        let ends = await service.calls.filter { $0 == "end" }
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(engine.disconnectCount, 1)
        XCTAssertTrue(viewModel.hasLeft)
    }

    // MARK: - Promotion re-joins

    /// **A promotion must produce a new token.** The one in hand was minted for
    /// the old role; flipping a boolean would light a microphone publishing
    /// into a socket that refuses it.
    func testBeingPromotedReconnectsForAFreshToken() async throws {
        let (viewModel, engine, service) = makeViewModel(
            room: room(canSpeak: false, refusal: "You can listen."), role: .listener
        )
        await viewModel.start()
        XCTAssertFalse(viewModel.canUseMicrophone)
        let tokenBefore = engine.connectedToken

        // The host invites them up; the next poll sees the new role.
        await service.setRole(.speaker)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.role, .speaker)
        XCTAssertTrue(viewModel.canUseMicrophone)
        XCTAssertTrue(engine.connectedCanPublish, "the new connection still could not publish")
        XCTAssertNotEqual(engine.connectedToken, tokenBefore, "the old token was kept after a promotion")
        XCTAssertEqual(
            engine.recordedCalls.filter { $0 == "disconnect" }.count, 1,
            "the old connection was left open"
        )
        XCTAssertTrue(engine.recordedCalls.contains("connect:publisher"))
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.youCanSpeakNow)
    }

    /// And the mirror image: a demotion also re-joins, so nobody keeps a
    /// publishing token after the host moves them off the stage.
    func testBeingDemotedReconnectsAndDropsTheMicrophone() async throws {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await viewModel.toggleMicrophone()
        XCTAssertTrue(viewModel.isMicrophoneEnabled)

        await service.setRole(.listener)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.role, .listener)
        XCTAssertFalse(viewModel.canUseMicrophone)
        XCTAssertFalse(viewModel.isMicrophoneEnabled, "a demoted speaker kept a live microphone")
        XCTAssertFalse(engine.connectedCanPublish)
        // Says they are still here. Being moved off a stage and being thrown
        // out of a room feel identical from the inside if nobody says which.
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.youWereDemoted)
        XCTAssertTrue(viewModel.toast?.text.contains("still in the room") == true)
    }

    // MARK: - Leaving

    /// **Leaving does both halves, always.** `POST /leave` *and* a media
    /// disconnect: one without the other leaves a ghost on the room's list or
    /// a live socket nobody is looking at.
    func testLeavingPostsLeaveAndDisconnectsTheMedia() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()

        await viewModel.leave()

        XCTAssertEqual(engine.disconnectCount, 1, "the media connection was left open")
        let leaves = await service.calls.filter { $0 == "leave" }
        XCTAssertEqual(leaves.count, 1, "the server was not told")
        XCTAssertTrue(viewModel.hasLeft)
        XCTAssertEqual(viewModel.connection, .idle)
    }

    /// Termination takes the same path — that is the whole point of it existing.
    func testTerminationLeavesTheRoomProperly() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()

        await viewModel.handleTermination()

        XCTAssertEqual(engine.disconnectCount, 1)
        let leaves = await service.calls.filter { $0 == "leave" }
        XCTAssertEqual(leaves.count, 1)
    }

    /// Backgrounding does **not** leave: the app declares `UIBackgroundModes:
    /// [audio]` precisely so a room survives somebody checking a message.
    func testBackgroundingKeepsTheRoomAlive() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()

        await viewModel.persistThroughBackgrounding()

        XCTAssertEqual(engine.disconnectCount, 0, "backgrounding dropped the room")
        XCTAssertFalse(viewModel.hasLeft)
        let leaves = await service.calls.filter { $0 == "leave" }
        XCTAssertTrue(leaves.isEmpty)
    }

    /// Leaving twice — the button, then termination — must not double up.
    func testLeavingTwiceIsHarmless() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()

        await viewModel.leave()
        await viewModel.leave()
        await viewModel.handleTermination()

        XCTAssertEqual(engine.disconnectCount, 1)
        let leaves = await service.calls.filter { $0 == "leave" }
        XCTAssertEqual(leaves.count, 1)
    }

    /// A room that ended under the viewer takes them out of it, with the
    /// sentence that says nothing was kept.
    func testARoomThatEndsUnderYouLeavesAndSaysNothingWasRecorded() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()

        await service.setStatus(.ended)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLeft)
        XCTAssertEqual(engine.disconnectCount, 1)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.roomEnded)
    }

    /// Being removed mid-room says the per-room sentence, not a block's.
    func testBeingRemovedMidRoomSaysItIsThisRoomOnly() async {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: false), role: .listener)
        await viewModel.start()

        await service.setRemoved(true)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLeft)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.removedFromRoom)
        // Says in words that it is not a block, and is not the block message.
        XCTAssertTrue(viewModel.toast?.text.contains("isn't a block") == true)
        XCTAssertNotEqual(
            viewModel.toast?.text,
            APIError.api(code: .blocked, message: "", status: 403).userMessage
        )
    }
}

// MARK: - A service the test drives

/// Serves one room whose status, removal flag and roster role the test can
/// change between refreshes — which is how a promotion, an ending and a removal
/// are simulated without a host on another device.
///
/// Every join hands back a **different token**, so a test can tell a genuine
/// re-join from a connection that was quietly kept.
private actor ScriptedRoomService: RoomsServiceProtocol {

    private var stored: VoiceRoom
    private var viewerRole: RoomRole
    private var joinCount = 0
    /// Calls in order, for assertions.
    private(set) var calls: [String] = []

    init(room: VoiceRoom, viewerRole: RoomRole) {
        self.stored = room
        self.viewerRole = viewerRole
    }

    func setRole(_ role: RoomRole) {
        viewerRole = role
        stored = Self.copy(stored, canSpeak: role.canPublish)
    }

    func setStatus(_ status: RoomStatus) {
        stored = Self.copy(stored, status: status)
    }

    func setRemoved(_ isRemoved: Bool) {
        stored = Self.copy(stored, isRemoved: isRemoved)
    }

    func createRoom(_ request: CreateRoomRequest) async throws -> VoiceRoom {
        calls.append("create")
        return stored
    }

    func fetchRooms(status: RoomStatus?, topic: String?, limit: Int) async throws -> [VoiceRoom] {
        calls.append("fetchRooms")
        return [stored]
    }

    func fetchRoom(id: UUID) async throws -> VoiceRoom {
        calls.append("fetchRoom")
        return stored
    }

    func join(roomId: UUID) async throws -> RoomJoin {
        calls.append("join")
        joinCount += 1
        return RoomJoin(
            room: stored,
            url: "wss://sila.gmai.sa/rtc",
            token: "token-\(joinCount)",
            role: stored.isHost ? .host : viewerRole
        )
    }

    func leave(roomId: UUID) async throws {
        calls.append("leave")
    }

    func endRoom(id: UUID) async throws -> VoiceRoom {
        calls.append("end")
        stored = Self.copy(stored, status: .ended)
        return stored
    }

    func promote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        calls.append("promote:\(handle)")
        return stored
    }

    func demote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        calls.append("demote:\(handle)")
        return stored
    }

    func remove(roomId: UUID, handle: String) async throws -> VoiceRoom {
        calls.append("remove:\(handle)")
        return stored
    }

    func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList {
        calls.append("participants")
        // The viewer is `aziz` in every test above; when they host the room
        // their roster row says so.
        return RoomParticipantList(participants: [
            RoomParticipant(role: stored.isHost ? .listener : .host, user: FeedServiceMock.yuki),
            RoomParticipant(role: stored.isHost ? .host : viewerRole, user: FeedServiceMock.aziz),
            RoomParticipant(role: .listener, user: FeedServiceMock.maria)
        ])
    }

    func searchRooms(query: String, limit: Int) async throws -> [VoiceRoom] {
        calls.append("search")
        return []
    }

    private static func copy(
        _ room: VoiceRoom,
        status: RoomStatus? = nil,
        canSpeak: Bool? = nil,
        isRemoved: Bool? = nil
    ) -> VoiceRoom {
        VoiceRoom(
            id: room.id,
            title: room.title,
            topic: room.topic,
            scope: room.scope,
            scopeCountry: room.scopeCountry,
            scopeRegion: room.scopeRegion,
            status: status ?? room.status,
            host: room.host,
            speakerCount: room.speakerCount,
            listenerCount: room.listenerCount,
            scheduledFor: room.scheduledFor,
            startedAt: room.startedAt,
            createdAt: room.createdAt,
            canSpeak: canSpeak ?? room.canSpeak,
            speakRefusal: room.speakRefusal,
            isHost: room.isHost,
            isRemoved: isRemoved ?? room.isRemoved
        )
    }
}
