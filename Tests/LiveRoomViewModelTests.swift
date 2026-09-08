import XCTest
@testable import Sila

/// ``LiveRoomViewModel``: the door, the microphone gate, the hands, the host
/// controls, the live events, and the two halves of leaving.
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
        refusal: String? = nil,
        canJoin: Bool = true,
        joinRefusal: String? = nil
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
            isRemoved: isRemoved,
            canJoin: canJoin,
            joinRefusal: joinRefusal
        )
    }

    /// Builds a view model over a service that serves the room and answers the
    /// join with `role` — anything else and the first refresh would 404 the
    /// room out from under every assertion.
    private func makeViewModel(
        room: VoiceRoom,
        role: RoomRole,
        engine: VoiceEngineMock? = nil,
        viewerHandle: String = "aziz"
    ) -> (LiveRoomViewModel, VoiceEngineMock, ScriptedRoomService) {
        let engine = engine ?? VoiceEngineMock()
        let service = ScriptedRoomService(room: room, viewerRole: role)
        let viewModel = LiveRoomViewModel(
            room: room,
            viewerHandle: viewerHandle,
            viewerId: FeedServiceMock.aziz.id,
            service: service,
            engine: engine,
            analytics: RecordingAnalyticsClient(),
            // Polling off and events undebounced: `refresh()` is driven by
            // hand so the assertions are about what changed, not about when a
            // timer happened to fire.
            pollInterval: 0,
            eventDebounce: 0
        )
        return (viewModel, engine, service)
    }

    // MARK: - The door

    /// The screen joins. It is pushed at once and does the join itself.
    func testStartJoinsThenConnectsThenReadsTheRoster() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        XCTAssertEqual(viewModel.phase, .joining)
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .inRoom)
        XCTAssertEqual(viewModel.role, .speaker)
        let calls = await service.calls
        XCTAssertEqual(calls.first, "join")
        XCTAssertTrue(calls.contains("participants"))
        XCTAssertEqual(engine.recordedCalls.first, "connect:publisher")
        XCTAssertEqual(viewModel.speakers.count + viewModel.listeners.count, 3)
    }

    /// A door that does not open is a state of the screen, in the server's
    /// words — never a spinner on the list behind.
    func testARefusedJoinIsAStateWithTheServersSentence() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: false), role: .listener)
        await service.refuseJoin(.notInvited, message: "This room is invite only")
        await viewModel.start()
        guard case let .refused(reason) = viewModel.phase else {
            return XCTFail("the door opened")
        }
        XCTAssertEqual(reason, RoomCopy.inviteOnlyRefusal)
        XCTAssertTrue(engine.recordedCalls.isEmpty, "nothing was connected")
    }

    func testAFollowingOnlyRefusalReadsAsOne() async {
        let (viewModel, _, service) = makeViewModel(
            room: room(canSpeak: false, canJoin: false, joinRefusal: "This room is for people the host follows"),
            role: .listener
        )
        await service.refuseJoin(.notFollowed, message: "This room is for people the host follows")
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .refused("This room is for people the host follows"))
    }

    func testARemovedViewerIsToldItIsThisRoomOnly() async {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: false, isRemoved: true), role: .listener)
        await service.refuseJoin(.removedFromRoom, message: "Removed")
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .refused(RoomCopy.removedFromRoom))
        XCTAssertTrue(RoomCopy.removedFromRoom.contains("isn't a block"))
    }

    // MARK: - The microphone gate

    /// **The assertion the whole feature turns on.** A listener's role means no
    /// microphone affordance, and the engine refuses the call if one is made.
    func testAListenersTokenIsRejectedForPublishing() async throws {
        let (viewModel, engine, _) = makeViewModel(room: room(canSpeak: false, refusal: "You can listen."), role: .listener)
        await viewModel.start()

        XCTAssertFalse(viewModel.canUseMicrophone)
        XCTAssertTrue(viewModel.isListening)
        XCTAssertEqual(engine.recordedCalls, ["connect:listener"])

        await viewModel.toggleMicrophone()
        XCTAssertFalse(viewModel.isMicrophoneEnabled)
        XCTAssertFalse(engine.recordedCalls.contains("mic:on"))

        do {
            try await engine.setMicrophoneEnabled(true)
            XCTFail("a listener's connection published")
        } catch VoiceEngineError.notPermittedToPublish {
            // The media server's answer, made locally.
        }
    }

    func testASpeakersTokenPublishes() async throws {
        let (viewModel, engine, _) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        XCTAssertTrue(viewModel.canUseMicrophone)
        await viewModel.toggleMicrophone()
        XCTAssertTrue(viewModel.isMicrophoneEnabled)
        XCTAssertEqual(engine.recordedCalls, ["connect:publisher", "mic:on"])
        await viewModel.toggleMicrophone()
        XCTAssertFalse(viewModel.isMicrophoneEnabled)
    }

    /// `can_speak` is a room-level fact; the **role** is what the token grants.
    func testTheRoleWinsOverCanSpeakWhenTheTwoDisagree() async {
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()
        XCTAssertFalse(viewModel.canUseMicrophone, "can_speak offered a microphone the token forbids")
        XCTAssertTrue(viewModel.canRaiseHand, "but the room's rule allows asking for it")
    }

    func testEnteringARoomNeverAsksForTheMicrophone() async {
        let engine = VoiceEngineMock(isPermissionGranted: false)
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true), role: .speaker, engine: engine)
        await viewModel.start()
        XCTAssertEqual(engine.recordedCalls, ["connect:publisher"], "a permission prompt on the way in")
        XCTAssertNil(viewModel.toast)
    }

    func testDeniedMicrophonePermissionKeepsTheRoomAndExplainsItself() async throws {
        let engine = VoiceEngineMock(isPermissionGranted: false)
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true), role: .speaker, engine: engine)
        await viewModel.start()
        await viewModel.toggleMicrophone()
        XCTAssertFalse(viewModel.isMicrophoneEnabled)
        XCTAssertEqual(viewModel.phase, .inRoom, "a denied prompt threw the person out")
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.microphoneDenied)
    }

    func testTheListenerSeesTheServersRefusalVerbatim() async {
        let refusal = "Only 🇸🇦 Saudi Arabia-verified accounts can speak in this room."
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: false, refusal: refusal), role: .listener)
        await viewModel.start()
        XCTAssertEqual(viewModel.speakRefusal, refusal)
        XCTAssertFalse(viewModel.canRaiseHand, "a hand nobody could call on")
    }

    // MARK: - Hands

    func testAListenerRaisesAHandAndTheHostIsNudged() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()
        XCTAssertTrue(viewModel.canRaiseHand)
        XCTAssertFalse(viewModel.handRaised)

        await viewModel.toggleHand()

        XCTAssertTrue(viewModel.handRaised)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.handRaised)
        let calls = await service.calls
        XCTAssertTrue(calls.contains("hand:up"))
        XCTAssertEqual(engine.publishedMessages.last, .hand(userId: FeedServiceMock.aziz.id, raised: true))
        XCTAssertTrue(viewModel.isListening, "still listening: a hand is a request")

        await viewModel.toggleHand()
        XCTAssertFalse(viewModel.handRaised)
        XCTAssertEqual(engine.publishedMessages.last?.raised, false)
    }

    func testASpeakerHasNoHandToRaise() async {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        XCTAssertFalse(viewModel.canRaiseHand)
        await viewModel.toggleHand()
        let calls = await service.calls
        XCTAssertFalse(calls.contains("hand:up"))
    }

    /// The host's queue: listeners with a hand up, oldest first, with Approve
    /// and Lower — and a nudge from the media channel refreshes it at once.
    func testTheHostSeesTheQueueAndApprovesFromIt() async throws {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        XCTAssertTrue(viewModel.hands.isEmpty)

        await service.raise(handle: "maria")
        engine.simulate(.message(.hand(userId: FeedServiceMock.maria.id, raised: true)))
        await viewModel.settle()

        XCTAssertEqual(viewModel.hands.map(\.user.handle), ["maria"])
        let actions = try XCTUnwrap(viewModel.hostActions(for: viewModel.hands[0]))
        XCTAssertTrue(actions.hasHandRaised)
        XCTAssertTrue(actions.canPromote && actions.canDismissHand)
        XCTAssertFalse(actions.canMute)

        await viewModel.promote(actions)
        let calls = await service.calls
        XCTAssertTrue(calls.contains("promote:maria"))
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.invited(FeedServiceMock.maria.displayName))
    }

    func testTheHostCanLowerAHandWithoutCallingOnIt() async throws {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        await service.raise(handle: "maria")
        await viewModel.refresh()
        let actions = try XCTUnwrap(viewModel.hostActions(for: viewModel.hands[0]))
        await viewModel.dismissHand(actions)
        let calls = await service.calls
        XCTAssertTrue(calls.contains("dismiss:maria"))
        XCTAssertTrue(viewModel.hands.isEmpty)
    }

    // MARK: - Host controls

    func testANonHostGetsNoHostMenuForAnybody() async {
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        for participant in viewModel.speakers + viewModel.listeners {
            XCTAssertNil(viewModel.hostActions(for: participant), "a non-host was offered controls over \(participant.user.handle)")
        }
    }

    func testAHostGetsAMenuForEverybodyExceptThemselves() async throws {
        let (viewModel, _, _) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        let me = try XCTUnwrap((viewModel.speakers + viewModel.listeners).first { $0.user.handle == "aziz" })
        XCTAssertNil(viewModel.hostActions(for: me))
        for other in (viewModel.speakers + viewModel.listeners) where other.user.handle != "aziz" {
            XCTAssertNotNil(viewModel.hostActions(for: other))
        }
    }

    func testTheHostMenuOffersOnlyWhatAppliesToThatPerson() {
        let listener = RoomHostActions(target: SafetyTarget(user: FeedServiceMock.maria), role: .listener, isBusy: false)
        XCTAssertTrue(listener.canPromote && listener.canRemove)
        XCTAssertFalse(listener.canDemote || listener.canMute || listener.canDismissHand)

        let speaker = RoomHostActions(target: SafetyTarget(user: FeedServiceMock.maria), role: .speaker, isBusy: false)
        XCTAssertTrue(speaker.canDemote && speaker.canMute && speaker.canRemove)
        XCTAssertFalse(speaker.canPromote)

        let host = RoomHostActions(target: SafetyTarget(user: FeedServiceMock.yuki), role: .host, isBusy: false)
        XCTAssertFalse(host.canDemote || host.canRemove || host.canMute)
    }

    func testMutingASpeakerKeepsTheirSeat() async throws {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        let yuki = try XCTUnwrap(viewModel.speakers.first { $0.user.handle == "yuki" })
        let actions = try XCTUnwrap(viewModel.hostActions(for: yuki))
        XCTAssertTrue(actions.canMute)
        await viewModel.mute(actions)
        let calls = await service.calls
        XCTAssertTrue(calls.contains("mute:yuki"))
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.muted(FeedServiceMock.yuki.displayName))
        XCTAssertTrue(RoomCopy.muted(FeedServiceMock.yuki.displayName).contains("keep their seat"))
    }

    func testRemovingSomebodySaysItAppliesToThisRoomOnlyAndCanBeUndone() async throws {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        let maria = try XCTUnwrap(viewModel.listeners.first { $0.user.handle == "maria" })
        let actions = try XCTUnwrap(viewModel.hostActions(for: maria))
        await viewModel.remove(actions)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.removed(FeedServiceMock.maria.displayName))
        XCTAssertFalse(viewModel.toast!.text.lowercased().contains("block"))
        XCTAssertEqual(viewModel.lastRemoved?.handle, "maria")

        await viewModel.readmitLastRemoved()
        let calls = await service.calls
        XCTAssertTrue(calls.contains("readmit:maria"))
        XCTAssertNil(viewModel.lastRemoved)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.readmitted(FeedServiceMock.maria.displayName))
    }

    func testAskingToEndARoomEndsNothing() async {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        viewModel.requestEnd()
        XCTAssertTrue(viewModel.isConfirmingEnd)
        let calls = await service.calls
        XCTAssertFalse(calls.contains("end"))
        XCTAssertFalse(viewModel.hasLeft)
    }

    func testEndingARoomAlsoLeavesIt() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true, isHost: true), role: .host)
        await viewModel.start()
        await viewModel.endRoom()
        let calls = await service.calls
        XCTAssertTrue(calls.contains("end"))
        XCTAssertTrue(calls.contains("leave"))
        XCTAssertEqual(engine.disconnectCount, 1)
        XCTAssertTrue(viewModel.hasLeft)
    }

    // MARK: - Live events

    /// A promotion applied by the media server arrives live: the role changes
    /// and the audio never drops.
    func testBeingPromotedLiveNeedsNoReconnect() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()
        XCTAssertFalse(viewModel.canUseMicrophone)

        await service.setRole(.speaker)
        engine.setCanPublish(true)
        await viewModel.settle()

        XCTAssertEqual(viewModel.role, .speaker)
        XCTAssertTrue(viewModel.canUseMicrophone)
        XCTAssertEqual(engine.disconnectCount, 0, "the audio was dropped for a promotion the media server had already applied")
        XCTAssertEqual(engine.recordedCalls.filter { $0.hasPrefix("connect") }.count, 1)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.youCanSpeakNow)
    }

    func testBeingDemotedLiveDropsTheMicrophoneAndKeepsTheSeatInTheRoom() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await viewModel.toggleMicrophone()
        XCTAssertTrue(viewModel.isMicrophoneEnabled)

        await service.setRole(.listener)
        engine.setCanPublish(false)
        await viewModel.settle()

        XCTAssertEqual(viewModel.role, .listener)
        XCTAssertFalse(viewModel.isMicrophoneEnabled, "a demoted speaker kept a live microphone")
        XCTAssertFalse(viewModel.hasLeft)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.youWereDemoted)
        XCTAssertTrue(viewModel.toast?.text.contains("still in the room") == true)
    }

    /// The fallback: the roster says the role changed but the connection was
    /// never told — then, and only then, a fresh token is fetched.
    func testAPromotionTheMediaServerMissedReconnectsForAFreshToken() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: false, refusal: "You can listen."), role: .listener)
        await viewModel.start()
        let tokenBefore = engine.connectedToken

        await service.setRole(.speaker)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.role, .speaker)
        XCTAssertTrue(engine.connectedCanPublish)
        XCTAssertNotEqual(engine.connectedToken, tokenBefore, "the old token was kept")
        XCTAssertEqual(engine.disconnectCount, 1)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.youCanSpeakNow)
    }

    func testAJoinOrLeaveOnTheMediaServerRefreshesTheRosterAtOnce() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()
        let before = await service.calls.filter { $0 == "participants" }.count
        engine.simulate(.participantJoined(identity: FeedServiceMock.noor.id.uuidString.lowercased()))
        await viewModel.settle()
        let after = await service.calls.filter { $0 == "participants" }.count
        XCTAssertEqual(after, before + 1, "a join on the media server waited for the poll")
    }

    func testSpeakingIsKeyedOnTheAccountIdNotTheHandle() async throws {
        let (viewModel, engine, _) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()
        let yuki = try XCTUnwrap(viewModel.speakers.first { $0.user.handle == "yuki" })
        engine.setSpeaking([FeedServiceMock.yuki.id.uuidString.lowercased()])
        XCTAssertTrue(viewModel.isSpeaking(yuki))
        engine.setSpeaking(["yuki"])
        XCTAssertFalse(viewModel.isSpeaking(yuki), "the media server names accounts by id; a handle must not light the ring")
    }

    func testAMutedSpeakerShowsAsMuted() async throws {
        let (viewModel, engine, _) = makeViewModel(room: room(canSpeak: true), role: .listener)
        await viewModel.start()
        let yuki = try XCTUnwrap(viewModel.speakers.first { $0.user.handle == "yuki" })
        engine.simulate(.muteChanged(identity: FeedServiceMock.yuki.id.uuidString.lowercased(), isMuted: true))
        await viewModel.settle()
        XCTAssertTrue(viewModel.isMuted(yuki))
    }

    // MARK: - Leaving

    func testLeavingPostsLeaveAndDisconnectsTheMedia() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await viewModel.leave()
        let calls = await service.calls
        XCTAssertTrue(calls.contains("leave"))
        XCTAssertEqual(engine.disconnectCount, 1)
        XCTAssertTrue(viewModel.hasLeft)
        XCTAssertEqual(viewModel.phase, .left)
    }

    func testTerminationLeavesTheRoomProperly() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await viewModel.handleTermination()
        let calls = await service.calls
        XCTAssertTrue(calls.contains("leave"))
        XCTAssertEqual(engine.disconnectCount, 1)
    }

    func testBackgroundingKeepsTheRoomAlive() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await viewModel.persistThroughBackgrounding()
        let calls = await service.calls
        XCTAssertFalse(calls.contains("leave"), "backgrounding left the room")
        XCTAssertEqual(engine.disconnectCount, 0)
        XCTAssertFalse(viewModel.hasLeft)
    }

    func testLeavingTwiceIsHarmless() async {
        let (viewModel, engine, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await viewModel.leave()
        await viewModel.leave()
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "leave" }.count, 1)
        XCTAssertEqual(engine.disconnectCount, 1)
    }

    func testARoomThatEndsUnderYouLeavesAndSaysNothingWasRecorded() async {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await service.setStatus(.ended)
        await viewModel.refresh()
        XCTAssertTrue(viewModel.hasLeft)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.roomEnded)
    }

    func testBeingRemovedMidRoomSaysItIsThisRoomOnly() async {
        let (viewModel, _, service) = makeViewModel(room: room(canSpeak: true), role: .speaker)
        await viewModel.start()
        await service.setRemoved(true)
        await viewModel.refresh()
        XCTAssertTrue(viewModel.hasLeft)
        XCTAssertEqual(viewModel.toast?.text, RoomCopy.removedFromRoom)
    }
}

// MARK: - Test double

/// Serves one room whose status, removal flag, roster role and hands the test
/// can change between refreshes — which is how a promotion, an ending, a
/// removal and a raised hand are simulated without a host on another device.
///
/// Every join hands back a **different token**, so a test can tell a genuine
/// re-join from a connection that was quietly kept.
private actor ScriptedRoomService: RoomsServiceProtocol {

    private var stored: VoiceRoom
    private var viewerRole: RoomRole
    private var joinCount = 0
    private var hands: [String: Date] = [:]
    private var joinRefusal: (APIErrorCode, String)?
    /// Calls in order, for assertions.
    private(set) var calls: [String] = []

    init(room: VoiceRoom, viewerRole: RoomRole) {
        self.stored = room
        self.viewerRole = viewerRole
    }

    func setRole(_ role: RoomRole) {
        viewerRole = role
        stored = Self.copy(stored, canSpeak: role.canPublish || stored.canSpeak, viewerRole: role)
    }

    func setStatus(_ status: RoomStatus) { stored = Self.copy(stored, status: status) }
    func setRemoved(_ isRemoved: Bool) { stored = Self.copy(stored, isRemoved: isRemoved) }
    func refuseJoin(_ code: APIErrorCode, message: String) { joinRefusal = (code, message) }
    func raise(handle: String) { hands[handle] = Date() }

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
        return Self.copy(stored, viewerRole: stored.isHost ? .host : viewerRole, handRaised: hands["aziz"] != nil, handsCount: hands.count)
    }

    func join(roomId: UUID) async throws -> RoomJoin {
        calls.append("join")
        if let (code, message) = joinRefusal {
            throw APIError.api(code: code, message: message, status: 403)
        }
        joinCount += 1
        let role: RoomRole = stored.isHost ? .host : viewerRole
        return RoomJoin(
            room: Self.copy(stored, viewerRole: role),
            url: "wss://sila.gmai.sa/rtc",
            token: "token-\(joinCount)",
            role: role
        )
    }

    func leave(roomId: UUID) async throws { calls.append("leave") }

    func endRoom(id: UUID) async throws -> VoiceRoom {
        calls.append("end")
        stored = Self.copy(stored, status: .ended)
        return stored
    }

    func promote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        calls.append("promote:\(handle)")
        hands[handle] = nil
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

    func readmit(roomId: UUID, handle: String) async throws -> VoiceRoom {
        calls.append("readmit:\(handle)")
        return stored
    }

    func mute(roomId: UUID, handle: String) async throws {
        calls.append("mute:\(handle)")
    }

    func raiseHand(roomId: UUID) async throws -> VoiceRoom {
        calls.append("hand:up")
        hands["aziz"] = Date()
        return Self.copy(stored, viewerRole: viewerRole, handRaised: true, handsCount: hands.count)
    }

    func lowerHand(roomId: UUID) async throws -> VoiceRoom {
        calls.append("hand:down")
        hands["aziz"] = nil
        return Self.copy(stored, viewerRole: viewerRole, handRaised: false, handsCount: hands.count)
    }

    func dismissHand(roomId: UUID, handle: String) async throws -> VoiceRoom {
        calls.append("dismiss:\(handle)")
        hands[handle] = nil
        return Self.copy(stored, handsCount: hands.count)
    }

    func fetchInvites(roomId: UUID) async throws -> RoomInviteList {
        calls.append("invites")
        return RoomInviteList(roomId: roomId, invited: [])
    }

    func invite(roomId: UUID, handles: [String]) async throws -> RoomInviteList {
        calls.append("invite")
        return RoomInviteList(roomId: roomId, invited: [])
    }

    func revokeInvite(roomId: UUID, handle: String) async throws -> RoomInviteList {
        calls.append("revoke")
        return RoomInviteList(roomId: roomId, invited: [])
    }

    func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList {
        calls.append("participants")
        // The viewer is `aziz` in every test above; when they host the room
        // their roster row says so.
        return RoomParticipantList(participants: [
            RoomParticipant(role: stored.isHost ? .speaker : .host, user: FeedServiceMock.yuki, joinedAt: Date().addingTimeInterval(-500)),
            RoomParticipant(role: stored.isHost ? .host : viewerRole, user: FeedServiceMock.aziz, joinedAt: Date().addingTimeInterval(-400), handRaisedAt: hands["aziz"]),
            RoomParticipant(role: .listener, user: FeedServiceMock.maria, joinedAt: Date().addingTimeInterval(-300), handRaisedAt: hands["maria"])
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
        isRemoved: Bool? = nil,
        viewerRole: RoomRole? = nil,
        handRaised: Bool? = nil,
        handsCount: Int? = nil
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
            isRemoved: isRemoved ?? room.isRemoved,
            isInviteOnly: room.isInviteOnly,
            isInvited: room.isInvited,
            canJoin: room.canJoin,
            joinRefusal: room.joinRefusal,
            isFollowingOnly: room.isFollowingOnly,
            viewerRole: viewerRole ?? room.viewerRole,
            handRaised: handRaised ?? room.handRaised,
            handsCount: handsCount ?? room.handsCount
        )
    }
}
