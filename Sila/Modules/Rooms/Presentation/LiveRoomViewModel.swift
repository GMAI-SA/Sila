import Foundation
import Observation

/// What a host may do to one person in their room.
///
/// A value type rather than a set of closures scattered through the view, for
/// the same reason ``SafetyMenuActions`` is one: whether a control exists is a
/// decision, and a decision is worth being able to assert on. `nil` from
/// ``LiveRoomViewModel/hostActions(for:)`` means **there is no menu**, which is
/// what a non-host sees.
public struct RoomHostActions: Equatable, Sendable {

    /// Who the actions are about.
    public let target: SafetyTarget
    /// Their role right now.
    public let role: RoomRole
    /// `true` while a call about this person is in flight.
    public let isBusy: Bool
    /// Whether "Invite to speak" applies (they are listening).
    public var canPromote: Bool { role == .listener }
    /// Whether "Move to listeners" applies. Never the host: there is no way to
    /// step off your own stage, and the server says so too.
    public var canDemote: Bool { role == .speaker }
    /// Whether "Remove from room" applies. Never the host.
    public var canRemove: Bool { !role.isHost }

    public init(target: SafetyTarget, role: RoomRole, isBusy: Bool) {
        self.target = target
        self.role = role
        self.isBusy = isBusy
    }
}

/// Drives ``LiveRoomScreen``.
///
/// Five rules, and every one of them is a thing that would otherwise be a bug
/// somebody only notices in a live conversation.
///
/// **The microphone is gated on ``role``, never on a scope.** The role came
/// with the token, and the token is what the media server enforces: a
/// listener's carries `canPublish: false` and their audio is dropped upstream
/// whatever this app draws. So the app never draws it. A mic button that cannot
/// work is worse than no mic button, because the person keeps talking.
///
/// **A promotion is followed by a re-join.** The grant travels with the token,
/// and the token was issued for the role held at join time. Flipping a local
/// boolean when the host invites somebody up would produce a lit microphone
/// publishing into a socket that refuses it. So the poll notices the role
/// changed, tears the connection down and joins again for a new token.
///
/// **Microphone permission is asked when somebody takes the microphone, and
/// never on the way in.** A listener needs no microphone; asking anyway teaches
/// people that this app wants more than it needs, which is how permission
/// prompts get denied by reflex.
///
/// **Leaving always does both halves.** `POST /leave` *and* a media disconnect,
/// including on backgrounding-then-termination. One without the other leaves
/// either a ghost on the room's list or a live socket nobody is looking at.
///
/// **Nothing is recorded, and the screen says so.** There is no recording
/// affordance here because there is no recording, and the sentence lives on the
/// screen rather than in a settings page nobody opens.
@MainActor
@Observable
public final class LiveRoomViewModel {

    /// The room as the server last described it.
    public private(set) var room: VoiceRoom
    /// What the **token currently in hand** permits. The mic gate.
    public private(set) var role: RoomRole
    /// Who is in the room.
    public private(set) var participants: RoomParticipantList = .empty
    /// Where the media connection is.
    public private(set) var connection: VoiceConnectionState = .idle
    /// Whether this device is publishing audio.
    public private(set) var isMicrophoneEnabled = false
    /// Handles the media server says are talking right now.
    public private(set) var speakingHandles: Set<String> = []
    /// `true` while the microphone is being turned on or off.
    public private(set) var isTogglingMic = false
    /// `true` while a new token is being fetched after a role change.
    public private(set) var isRejoining = false
    /// `true` while the leave is running.
    public private(set) var isLeaving = false
    /// `true` while the room is being ended.
    public private(set) var isEnding = false
    /// `true` once the room has been left; the screen dismisses on it.
    public private(set) var hasLeft = false
    /// Set when the host asked to end the room and has not confirmed yet.
    public var isConfirmingEnd = false
    /// Banner message.
    public var toast: SLToastMessage?

    /// The viewer's own handle, so they are never offered a menu about
    /// themselves and never demoted by their own poll.
    public let viewerHandle: String

    private let service: RoomsServiceProtocol
    private let engine: VoiceEngineProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var busyHandles: Set<String> = []
    /// The credentials for the connection currently held.
    private var mediaURL: String
    private var mediaToken: String

    /// - Parameters:
    ///   - join: What `POST /rooms/{id}/join` handed back — the room, the media
    ///     URL, the token and the role that token grants.
    ///   - viewerHandle: The signed-in account's handle.
    ///   - service: Rooms backend.
    ///   - engine: The media transport, behind its seam.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    ///   - pollInterval: Seconds between roster refreshes. Tests pass `0` to
    ///     switch polling off and drive ``refresh()`` by hand.
    public init(
        join: RoomJoin,
        viewerHandle: String,
        service: RoomsServiceProtocol,
        engine: VoiceEngineProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        pollInterval: TimeInterval = RoomConstants.participantPollInterval
    ) {
        self.room = join.room
        self.role = join.role
        self.mediaURL = join.url
        self.mediaToken = join.token
        self.viewerHandle = Handle.normalised(viewerHandle)
        self.service = service
        self.engine = engine
        self.analytics = analytics
        self.suspension = suspension
        self.pollInterval = pollInterval
    }

    // MARK: - Derived state

    /// **The single predicate the microphone affordance is gated on.**
    ///
    /// Not "does the scope allow it" — that question was answered by the server
    /// and is already baked into the token this role came with.
    public var canUseMicrophone: Bool {
        role.canPublish && room.status.isJoinable && !room.isRemoved
    }

    /// `true` when this person is here to listen.
    public var isListening: Bool { !canUseMicrophone }

    /// Why the microphone is not on offer, or `nil` when it is.
    ///
    /// The server's ``VoiceRoom/speakRefusal`` is rendered **verbatim** when
    /// there is one; nothing here rewrites, shortens or re-derives it.
    public var speakRefusal: String? {
        guard isListening else { return nil }
        return room.speakRefusalMessage ?? RoomCopy.speakRefusalFallback
    }

    /// `true` when this viewer opened the room.
    public var isHost: Bool { room.isHost || role.isHost }

    /// The people on stage, host first.
    public var speakers: [RoomParticipant] { participants.stage }

    /// The people listening.
    public var listeners: [RoomParticipant] { participants.audience }

    /// Whether a participant is talking right now.
    public func isSpeaking(_ participant: RoomParticipant) -> Bool {
        speakingHandles.contains(Handle.normalised(participant.user.handle))
    }

    /// The host menu for one person, or `nil` when there should not be one.
    ///
    /// `nil` for **every** participant when the viewer is not the host — which
    /// is the assertion that matters: a non-host must not be shown controls
    /// that exist, greyed out, teaching them the room has a hierarchy they can
    /// reach into.
    public func hostActions(for participant: RoomParticipant) -> RoomHostActions? {
        guard isHost else { return nil }
        let handle = Handle.normalised(participant.user.handle)
        // No menu about yourself: every entry on it is either meaningless
        // (invite yourself up) or refused by the server (demote the host).
        guard handle != viewerHandle else { return nil }
        return RoomHostActions(
            target: SafetyTarget(user: participant.user),
            role: participant.role,
            isBusy: busyHandles.contains(handle)
        )
    }

    // MARK: - Lifecycle

    /// Opens the media connection and starts the roster poll.
    public func start() async {
        await connectMedia()
        await refresh()
        startPolling()
    }

    private func connectMedia() async {
        do {
            // `canPublish` is passed as well as encoded in the token. The token
            // is the enforcement; this is the client admitting what it thinks,
            // so a disagreement is a loud local failure rather than audio
            // vanishing silently somewhere upstream.
            try await engine.connect(url: mediaURL, token: mediaToken, canPublish: role.canPublish)
        } catch {
            analytics.track(.roomMediaFailed, properties: ["stage": "connect"])
            toast = .error(
                (error as? VoiceEngineError)?.userMessage ?? APIError.wrapping(error).userMessage
            )
        }
        adoptEngineState()
        engine.onChange = { [weak self] in self?.adoptEngineState() }
    }

    /// Mirrors the engine's state onto the observable properties.
    private func adoptEngineState() {
        connection = engine.connection
        isMicrophoneEnabled = engine.isMicrophoneEnabled
        speakingHandles = Set(engine.speakingIdentities.map { Handle.normalised($0) })
    }

    private func startPolling() {
        guard pollInterval > 0, pollTask == nil else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    // MARK: - Refreshing

    /// Re-reads the room and its roster, and reacts to what changed.
    ///
    /// Three things can have happened since the last poll, and each is handled
    /// rather than merely displayed: the room ended, the viewer was removed
    /// from it, or the viewer's role changed — the last of which needs a **new
    /// token**, because the old one grants what the old role had.
    public func refresh() async {
        guard !hasLeft else { return }
        do {
            async let current = service.fetchRoom(id: room.id)
            async let roster = service.fetchParticipants(roomId: room.id)
            let updated = try await current
            participants = try await roster
            let previousRole = role
            room = updated

            if updated.status != .live {
                toast = .info(RoomCopy.roomEnded)
                await leave()
                return
            }
            if updated.isRemoved {
                // Said as what it is: this room, and nothing else.
                toast = .warning(RoomCopy.removedFromRoom)
                await leave()
                return
            }

            let serverRole = rosterRole ?? previousRole
            if serverRole != previousRole {
                await adopt(newRole: serverRole, from: previousRole)
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            let wrapped = APIError.wrapping(error)
            // A room that has gone is a room to leave, not one to keep polling.
            if wrapped.code == .roomEnded || wrapped.code == .notFound {
                toast = .info(RoomCopy.roomEnded)
                await leave()
            }
            // Anything else is a blip in a background refresh. A banner in
            // front of somebody mid-conversation, for a poll they did not ask
            // for, is noise — the next tick either recovers or it does not.
        }
    }

    /// The role the server's roster gives this viewer, if it lists them.
    private var rosterRole: RoomRole? {
        participants.participants
            .first { Handle.normalised($0.user.handle) == viewerHandle }?
            .role
    }

    /// Adopts a role the server changed under us.
    ///
    /// **A promotion re-joins.** The token in hand was minted for the old role,
    /// so a listener who is invited up gets a whole new connection rather than
    /// a flipped boolean — otherwise the microphone would light up and publish
    /// into a socket that refuses it.
    ///
    /// A demotion re-joins too, for the mirror-image reason: leaving a
    /// publishing token in place would let somebody keep talking after the host
    /// moved them off the stage.
    private func adopt(newRole: RoomRole, from previous: RoomRole) async {
        isRejoining = true
        defer { isRejoining = false }

        // The microphone goes down first, whichever direction this is. Coming
        // back up is the person's own decision, made against the new token.
        if isMicrophoneEnabled {
            try? await engine.setMicrophoneEnabled(false)
        }
        await engine.disconnect()

        do {
            let join = try await service.join(roomId: room.id)
            room = join.room
            role = join.role
            mediaURL = join.url
            mediaToken = join.token
            await connectMedia()
            toast = join.role.canPublish && !previous.canPublish
                ? .success(RoomCopy.youCanSpeakNow)
                : .info(RoomCopy.youWereDemoted)
        } catch {
            guard suspension?.notice(error) != true else { return }
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .removedFromRoom {
                toast = .warning(RoomCopy.removedFromRoom)
            } else {
                toast = .error(wrapped.userMessage)
            }
            await leave()
        }
    }

    // MARK: - The microphone

    /// Turns the microphone on or off.
    ///
    /// Refuses outright when ``canUseMicrophone`` is `false`, which the UI
    /// already guarantees by not drawing the control — belt and braces on the
    /// one path where the failure is somebody talking to nobody.
    public func toggleMicrophone() async {
        guard canUseMicrophone, !isTogglingMic else { return }
        isTogglingMic = true
        defer { isTogglingMic = false }

        let target = !isMicrophoneEnabled
        do {
            try await engine.setMicrophoneEnabled(target)
            isMicrophoneEnabled = engine.isMicrophoneEnabled
            analytics.track(
                target ? .roomMicEnabled : .roomMicDisabled,
                properties: ["role": role.rawValue]
            )
        } catch VoiceEngineError.microphoneDenied {
            analytics.track(.roomMicDenied)
            // Not an error banner that implies the room broke: the room is
            // fine, the person is still hearing it, and the sentence says how
            // to change their mind.
            toast = .warning(RoomCopy.microphoneDenied)
        } catch {
            toast = .error(
                (error as? VoiceEngineError)?.userMessage ?? APIError.wrapping(error).userMessage
            )
        }
    }

    // MARK: - Host controls

    /// Invites somebody onto the stage.
    ///
    /// The promotion changes their role; **their** client re-joins for a token
    /// that permits publishing. Nothing here can hand them the grant directly,
    /// and nothing here pretends to.
    public func promote(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomSpeakerPromoted) { [service, room] handle in
            try await service.promote(roomId: room.id, handle: handle)
        } success: { RoomCopy.invited(actions.target.name) }
    }

    /// Moves somebody back to the audience. They stay in the room.
    public func demote(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomSpeakerDemoted) { [service, room] handle in
            try await service.demote(roomId: room.id, handle: handle)
        } success: { RoomCopy.demoted(actions.target.name) }
    }

    /// Removes somebody from **this room**.
    ///
    /// Per-room, and the confirmation copy says so. It is not a block: their
    /// account is untouched, their posts stay where they are, and they can open
    /// or join any other room on Sila a second later.
    public func remove(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomParticipantRemoved) { [service, room] handle in
            try await service.remove(roomId: room.id, handle: handle)
        } success: { RoomCopy.removed(actions.target.name) }
    }

    private func hostCall(
        _ actions: RoomHostActions,
        event: AnalyticsEvent,
        _ call: @escaping (String) async throws -> VoiceRoom,
        success: () -> String
    ) async {
        guard isHost, !actions.isBusy else { return }
        let handle = actions.target.handle
        busyHandles.insert(handle)
        defer { busyHandles.remove(handle) }

        do {
            room = try await call(handle)
            analytics.track(event)
            toast = .success(success())
            // The roster is what the controls are drawn from, so it is re-read
            // rather than guessed at — a stage that disagrees with the server
            // is a stage whose menus offer the wrong thing.
            participants = (try? await service.fetchParticipants(roomId: room.id)) ?? participants
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Puts the end-room confirmation on screen. **Ends nothing.**
    public func requestEnd() {
        guard isHost, !isEnding else { return }
        isConfirmingEnd = true
    }

    /// Ends the room for everybody, then leaves.
    public func endRoom() async {
        guard isHost, !isEnding else { return }
        isConfirmingEnd = false
        isEnding = true
        defer { isEnding = false }

        do {
            room = try await service.endRoom(id: room.id)
            analytics.track(.roomEnded)
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
            return
        }
        // The host leaves their own ended room like anybody else: both halves.
        await leave()
    }

    // MARK: - Leaving

    /// Leaves the room: `POST /leave` **and** a media disconnect, always both.
    ///
    /// The two are started together rather than in sequence. The disconnect is
    /// local and instant, which is what stops the audio; the leave needs the
    /// network, and starting it first gives it the best chance of landing when
    /// this is running inside the seconds iOS grants a terminating app. A
    /// failure of either does not stop the other, and calling this twice is
    /// harmless — which matters, because backgrounding, the Leave button and
    /// termination can all reach it.
    public func leave() async {
        guard !hasLeft else { return }
        hasLeft = true
        isLeaving = true
        pollTask?.cancel()
        pollTask = nil
        engine.onChange = nil

        let serverLeave = Task { [service, room] in
            try? await service.leave(roomId: room.id)
        }
        await engine.disconnect()
        _ = await serverLeave.value

        connection = .idle
        isMicrophoneEnabled = false
        isLeaving = false
    }

    /// Called when the app goes into the background. **Deliberately does not
    /// leave.**
    ///
    /// The app declares `UIBackgroundModes: [audio]` precisely so a room
    /// survives somebody checking a message; tearing it down here would make
    /// the feature unusable and would be a strange reading of "the user pressed
    /// Home". What it does do is stop the roster poll — a timer firing every
    /// eight seconds behind a locked screen buys nothing and costs battery —
    /// and the next foreground refresh picks the roster back up.
    public func persistThroughBackgrounding() async {
        guard !hasLeft else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called when the app comes back to the front.
    public func resumeFromBackground() async {
        guard !hasLeft else { return }
        await refresh()
        startPolling()
    }

    /// Called when the app is going away for good.
    ///
    /// Same work as ``leave()``; a separate name so the call site reads as what
    /// it is, and so a future change to one cannot silently change the other.
    /// This is the path that stops a terminated app leaving a ghost on the
    /// room's participant list and a socket nobody owns.
    public func handleTermination() async {
        await leave()
    }
}
