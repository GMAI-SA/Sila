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
    /// Whether their hand is up.
    public let hasHandRaised: Bool
    /// `true` while a call about this person is in flight.
    public let isBusy: Bool
    /// Whether "Invite to speak" / "Approve" applies (they are listening).
    public var canPromote: Bool { role == .listener }
    /// Whether "Lower their hand" applies.
    public var canDismissHand: Bool { hasHandRaised }
    /// Whether "Mute" applies (they hold a microphone that is not the host's).
    public var canMute: Bool { role == .speaker }
    /// Whether "Move to listeners" applies. Never the host: there is no way to
    /// step off your own stage, and the server says so too.
    public var canDemote: Bool { role == .speaker }
    /// Whether "Remove from room" applies. Never the host.
    public var canRemove: Bool { !role.isHost }

    public init(target: SafetyTarget, role: RoomRole, hasHandRaised: Bool = false, isBusy: Bool) {
        self.target = target
        self.role = role
        self.hasHandRaised = hasHandRaised
        self.isBusy = isBusy
    }
}

/// Where the room screen is in its life.
public enum LiveRoomPhase: Equatable, Sendable {
    /// `POST /join` and the media connection are in flight.
    case joining
    /// In the room.
    case inRoom
    /// The door did not open. The sentence is the server's, or the room's.
    case refused(String)
    /// Gone; the screen dismisses on it.
    case left
}

/// Drives ``LiveRoomScreen``.
///
/// **The screen joins.** Tapping a room pushes this screen at once; the join
/// and the media connection happen here, under a connecting header, and a
/// door that does not open is a state of this screen rather than a toast on
/// the list behind it.
///
/// **The microphone is gated on ``role``, never on a scope.** The role came
/// with the token and is what the media server enforces: a listener's carries
/// `canPublish: false` and their audio is dropped upstream whatever this app
/// draws. So the app never draws it.
///
/// **A raised hand is a request.** It goes to the API (the queue the host
/// decides from) and is announced over the media channel (so the host's screen
/// refreshes now). The host approves, dismisses, or does nothing; the person
/// keeps listening throughout.
///
/// **A promotion arrives live.** The server tells the media server, the media
/// server tells this engine, and the role changes without the audio dropping.
/// The reconnect path survives as the fallback for a live update that did not
/// land: the next poll notices the role changed and fetches a fresh token.
///
/// **Leaving always does both halves.** `POST /leave` *and* a media disconnect,
/// including on backgrounding-then-termination.
@MainActor
@Observable
public final class LiveRoomViewModel {

    /// The room as the server last described it.
    public private(set) var room: VoiceRoom
    public private(set) var phase: LiveRoomPhase = .joining
    /// What the **connection in hand** permits. The mic gate.
    public private(set) var role: RoomRole = .listener
    /// Who is in the room.
    public private(set) var participants: RoomParticipantList = .empty
    public private(set) var connection: VoiceConnectionState = .idle
    public private(set) var isMicrophoneEnabled = false
    /// Account ids the media server says are talking right now.
    public private(set) var speakingIds: Set<String> = []
    /// Account ids whose microphone is muted.
    public private(set) var mutedIds: Set<String> = []
    public private(set) var isTogglingMic = false
    public private(set) var isTogglingHand = false
    public private(set) var isRejoining = false
    public private(set) var isLeaving = false
    public private(set) var isEnding = false
    public private(set) var hasLeft = false
    /// The last person the host removed, so a mis-tap has an undo.
    public private(set) var lastRemoved: SafetyTarget?
    /// Set when the host asked to end the room and has not confirmed yet.
    public var isConfirmingEnd = false
    public var toast: SLToastMessage?

    /// The viewer's own handle and id, so they are never offered a menu about
    /// themselves and the speaking ring can find them.
    public let viewerHandle: String
    public let viewerId: UUID?

    private let service: RoomsServiceProtocol
    private let engine: VoiceEngineProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let pollInterval: TimeInterval
    private let eventDebounce: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var busyHandles: Set<String> = []
    private var mediaURL = ""
    private var mediaToken = ""

    /// - Parameters:
    ///   - room: The room as the list described it. Re-read on join.
    ///   - viewerHandle: The signed-in account's handle.
    ///   - viewerId: The signed-in account's id — what the media server calls them.
    ///   - service: Rooms backend.
    ///   - engine: The media transport, behind its seam.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    ///   - pollInterval: Seconds between roster refreshes. Tests pass `0` to
    ///     switch polling off and drive ``refresh()`` by hand.
    ///   - eventDebounce: Seconds to coalesce media events before a refresh.
    public init(
        room: VoiceRoom,
        viewerHandle: String,
        viewerId: UUID? = nil,
        service: RoomsServiceProtocol,
        engine: VoiceEngineProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        people: PeopleDirectory? = nil,
        pollInterval: TimeInterval = RoomConstants.participantPollInterval,
        eventDebounce: TimeInterval = 0.4
    ) {
        self.people = people
        self.room = room
        self.viewerHandle = Handle.normalised(viewerHandle)
        self.viewerId = viewerId
        self.service = service
        self.engine = engine
        self.analytics = analytics
        self.suspension = suspension
        self.pollInterval = pollInterval
        self.eventDebounce = eventDebounce
    }

    /// The guest-list model for this room, built from the same backend this
    /// screen already holds — so the view never has to be handed a service.
    public func makeInvitesViewModel() -> RoomInvitesViewModel {
        RoomInvitesViewModel(
            roomId: room.id, service: service, analytics: analytics,
            people: people, viewerHandle: viewerHandle
        )
    }

    /// Where the invites picker gets its people.
    private let people: PeopleDirectory?

    // MARK: - Derived state

    /// **The single predicate the microphone affordance is gated on.**
    public var canUseMicrophone: Bool {
        phase == .inRoom && role.canPublish && room.status.isJoinable && !room.isRemoved
    }

    /// `true` when this person is here to listen.
    public var isListening: Bool { phase == .inRoom && !role.canPublish }

    /// Whether a listener may ask for the microphone: the room's rule allows it.
    public var canRaiseHand: Bool { isListening && room.canSpeak && room.status.isJoinable }

    /// Whether this viewer's hand is up.
    public var handRaised: Bool { room.handRaised }

    /// Why the microphone is not on offer, or `nil` when it is.
    public var speakRefusal: String? {
        guard isListening, !room.canSpeak else { return nil }
        return room.speakRefusalMessage ?? RoomCopy.speakRefusalFallback
    }

    public var isHost: Bool { room.isHost || role.isHost }

    /// The people on stage, host first.
    public var speakers: [RoomParticipant] { participants.stage }

    /// The people listening, hands first.
    public var listeners: [RoomParticipant] { participants.audience }

    /// The queue the host decides from.
    public var hands: [RoomParticipant] { participants.hands }

    /// One count source — the roster — with the room's numbers until it loads.
    public var attendanceSummary: String {
        guard !participants.participants.isEmpty else { return room.attendanceSummary }
        return RoomCopy.attendance(speakers: speakers.count, listeners: listeners.count)
    }

    /// Whether a participant is talking right now, by account id.
    public func isSpeaking(_ participant: RoomParticipant) -> Bool {
        speakingIds.contains(participant.user.id.uuidString.lowercased())
    }

    /// Whether a participant's microphone is muted, by account id.
    public func isMuted(_ participant: RoomParticipant) -> Bool {
        mutedIds.contains(participant.user.id.uuidString.lowercased())
    }

    /// The host menu for one person, or `nil` when there should not be one.
    public func hostActions(for participant: RoomParticipant) -> RoomHostActions? {
        guard isHost else { return nil }
        let handle = Handle.normalised(participant.user.handle)
        guard handle != viewerHandle else { return nil }
        return RoomHostActions(
            target: SafetyTarget(user: participant.user),
            role: participant.role,
            hasHandRaised: participant.hasHandRaised,
            isBusy: busyHandles.contains(handle)
        )
    }

    // MARK: - Lifecycle

    /// Joins, connects the media, reads the roster, and starts watching.
    public func start() async {
        guard phase == .joining, !hasLeft else { return }
        do {
            let join = try await service.join(roomId: room.id)
            room = join.room
            role = join.role
            mediaURL = join.url
            mediaToken = join.token
        } catch {
            guard suspension?.notice(error) != true else { return }
            let wrapped = APIError.wrapping(error)
            analytics.track(.roomJoinRefused, properties: ["code": wrapped.code?.rawValue ?? "transport"])
            phase = .refused(refusalSentence(wrapped))
            return
        }
        await connectMedia()
        engine.onRoomEvent = { [weak self] event in self?.handle(event) }
        phase = .inRoom
        await refresh()
        startPolling()
    }

    private func refusalSentence(_ error: APIError) -> String {
        switch error.code {
        case .removedFromRoom: return RoomCopy.removedFromRoom
        case .roomEnded, .notFound: return RoomCopy.roomEnded
        case .notInvited: return room.joinRefusal ?? RoomCopy.inviteOnlyRefusal
        case .notFollowed: return room.joinRefusal ?? RoomCopy.followingOnlyRefusal
        default: return error.userMessage
        }
    }

    private func connectMedia() async {
        do {
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

    private func adoptEngineState() {
        connection = engine.connection
        isMicrophoneEnabled = engine.isMicrophoneEnabled
        speakingIds = Set(engine.speakingIdentities.map { $0.lowercased() })
        mutedIds = Set(engine.mutedIdentities.map { $0.lowercased() })
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

    // MARK: - Live events

    /// Something the media server said. Two events change what the viewer may
    /// do *now* and are applied at once; every event refreshes the roster.
    private func handle(_ event: VoiceRoomEvent) {
        guard !hasLeft else { return }
        switch event {
        case let .message(message) where message.isReaction:
            receive(reaction: message)
            return  // Nothing on the roster changed; do not spend a read on it.
        case let .message(message) where message.isChat:
            receive(chat: message)
            return
        case let .permissionsChanged(canPublish):
            if canPublish, !role.canPublish {
                role = .speaker
                toast = .success(RoomCopy.youCanSpeakNow)
            } else if !canPublish, role == .speaker {
                role = .listener
                isMicrophoneEnabled = false
                toast = .info(RoomCopy.youWereDemoted)
            }
        case let .muteChanged(identity, isMuted):
            if isMuted, role.canPublish, identity == viewerId?.uuidString.lowercased(), isMicrophoneEnabled || engine.isMicrophoneEnabled == false {
                // The host muted us: the track went quiet under the app.
                if isMicrophoneEnabled { toast = .warning(RoomCopy.youWereMuted) }
            }
        default:
            break
        }
        adoptEngineState()
        scheduleRefresh()
    }

    // MARK: - Reactions and chat

    /// Emoji currently floating up the screen. Cleared as they age out.
    public private(set) var reactions: [RoomReaction] = []
    /// What has been said in this room's chat, oldest first, capped.
    public private(set) var chat: [RoomChatMessage] = []
    /// The line being typed.
    public var chatDraft = ""
    /// Whether the next line goes to the host alone.
    public var chatToHostOnly = false
    /// True while the chat panel is up; unread stops counting when it is.
    public var isChatOpen = false {
        didSet { if isChatOpen { unreadChat = 0 } }
    }
    /// Lines that arrived while the panel was closed.
    public private(set) var unreadChat = 0

    /// How long a reaction stays on screen.
    static let reactionLifetime: TimeInterval = 4
    /// How many lines a room keeps. Old ones fall off the top: this is a
    /// conversation happening now, not a transcript.
    static let chatLimit = 200
    static let chatCharacterLimit = 240

    /// Sends an emoji to the room. Anybody may — listening is not silence.
    public func react(_ emoji: String) async {
        guard let viewerId, !hasLeft else { return }
        show(RoomReaction(emoji: emoji, name: L10n.t("rooms.chat.you")))
        analytics.track(.roomReactionSent, properties: ["emoji": emoji])
        await engine.publish(
            .reaction(emoji, userId: viewerId, handle: viewerHandle, name: viewerDisplayName)
        )
    }

    /// True when there is something to send.
    public var canSendChat: Bool {
        let trimmed = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= Self.chatCharacterLimit && !hasLeft
    }

    /// Says a line, to the room or to the host alone.
    public func sendChat() async {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendChat, let viewerId else { return }
        let toHost = chatToHostOnly && !isHost
        chatDraft = ""
        append(
            RoomChatMessage(
                userId: viewerId.uuidString.lowercased(),
                handle: viewerHandle,
                name: L10n.t("rooms.chat.you"),
                text: text,
                toHost: toHost,
                isMine: true
            )
        )
        analytics.track(.roomChatSent, properties: ["to_host": String(toHost)])
        // Addressed to the host's connection when it is private, so "only the
        // host" is true on the wire and not a promise other clients keep.
        let destinations = toHost ? [hostIdentity].compactMap { $0 } : []
        await engine.publish(
            .chat(text, userId: viewerId, handle: viewerHandle, name: viewerDisplayName, toHost: toHost),
            to: destinations
        )
    }

    /// The media server's name for the host — the account id, as everywhere.
    private var hostIdentity: String? {
        participants.participants.first { $0.role.isHost }?.user.id.uuidString.lowercased()
            ?? room.host.id.uuidString.lowercased()
    }

    /// The viewer's own name, for what others see on a reaction or a line.
    private var viewerDisplayName: String {
        participants.participants.first { $0.user.id == viewerId }?.user.displayName ?? viewerHandle
    }

    private func receive(reaction message: RoomDataMessage) {
        guard let emoji = message.emoji, !emoji.isEmpty else { return }
        guard message.userId != viewerId?.uuidString.lowercased() else { return }  // ours is already up
        show(RoomReaction(emoji: emoji, name: message.name ?? message.handle))
    }

    private func receive(chat message: RoomDataMessage) {
        guard let text = message.text, !text.isEmpty else { return }
        guard message.userId != viewerId?.uuidString.lowercased() else { return }  // ours is already listed
        append(
            RoomChatMessage(
                userId: message.userId,
                handle: message.handle,
                name: message.name ?? message.handle ?? L10n.t("rooms.chat.someone"),
                text: String(text.prefix(Self.chatCharacterLimit)),
                toHost: message.toHost
            )
        )
        if !isChatOpen { unreadChat += 1 }
    }

    private func show(_ reaction: RoomReaction) {
        reactions.append(reaction)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reactionLifetime * 1_000_000_000))
            await MainActor.run { self?.expireReactions() }
        }
    }

    /// Takes down everything past its moment. Called on a timer rather than
    /// per reaction so a burst does not queue a hundred separate removals.
    public func expireReactions() {
        let cutoff = Date().addingTimeInterval(-Self.reactionLifetime)
        reactions.removeAll { $0.sentAt <= cutoff }
    }

    private func append(_ message: RoomChatMessage) {
        chat.append(message)
        if chat.count > Self.chatLimit {
            chat.removeFirst(chat.count - Self.chatLimit)
        }
    }

    /// Coalesces a burst of events into one roster read.
    private func scheduleRefresh() {
        eventTask?.cancel()
        eventTask = Task { [weak self, eventDebounce] in
            if eventDebounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(eventDebounce * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Waits for any event-driven refresh to land. For tests.
    public func settle() async {
        await eventTask?.value
    }

    // MARK: - Refreshing

    /// Re-reads the room and its roster, and reacts to what changed.
    public func refresh() async {
        guard !hasLeft, phase == .inRoom else { return }
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
                toast = .warning(RoomCopy.removedFromRoom)
                await leave()
                return
            }

            let serverRole = rosterRole ?? updated.viewerRole ?? previousRole
            if serverRole != previousRole {
                await adopt(newRole: serverRole, from: previousRole)
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .roomEnded || wrapped.code == .notFound {
                toast = .info(RoomCopy.roomEnded)
                await leave()
            }
            // Anything else is a blip in a background refresh.
        }
    }

    private var rosterRole: RoomRole? {
        if let viewerId, let role = participants.role(of: viewerId) { return role }
        return participants.participants
            .first { Handle.normalised($0.user.handle) == viewerHandle }?
            .role
    }

    /// Adopts a role the server changed.
    ///
    /// When the media server already applied it (the connection can or cannot
    /// publish as the new role says), the role is simply taken on — no audio
    /// drop. When it did not, the old path runs: disconnect, join for a token
    /// minted for the new role, reconnect.
    private func adopt(newRole: RoomRole, from previous: RoomRole) async {
        if engine.canPublish == newRole.canPublish, engine.connection.isActive {
            role = newRole
            if !newRole.canPublish, isMicrophoneEnabled {
                try? await engine.setMicrophoneEnabled(false)
                isMicrophoneEnabled = false
            }
            toast = newRole.canPublish && !previous.canPublish
                ? .success(RoomCopy.youCanSpeakNow)
                : .info(RoomCopy.youWereDemoted)
            return
        }

        isRejoining = true
        defer { isRejoining = false }
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
            toast = wrapped.code == .removedFromRoom ? .warning(RoomCopy.removedFromRoom) : .error(wrapped.userMessage)
            await leave()
        }
    }

    // MARK: - The microphone

    public func toggleMicrophone() async {
        guard canUseMicrophone, !isTogglingMic else { return }
        isTogglingMic = true
        defer { isTogglingMic = false }

        let target = !isMicrophoneEnabled
        do {
            try await engine.setMicrophoneEnabled(target)
            isMicrophoneEnabled = engine.isMicrophoneEnabled
            analytics.track(target ? .roomMicEnabled : .roomMicDisabled, properties: ["role": role.rawValue])
        } catch VoiceEngineError.microphoneDenied {
            analytics.track(.roomMicDenied)
            toast = .warning(RoomCopy.microphoneDenied)
        } catch {
            toast = .error((error as? VoiceEngineError)?.userMessage ?? APIError.wrapping(error).userMessage)
        }
    }

    // MARK: - Hands

    /// Asks for the microphone, or withdraws the request.
    public func toggleHand() async {
        guard isListening, !isTogglingHand else { return }
        isTogglingHand = true
        defer { isTogglingHand = false }
        let raising = !handRaised
        do {
            room = raising
                ? try await service.raiseHand(roomId: room.id)
                : try await service.lowerHand(roomId: room.id)
            if let viewerId {
                await engine.publish(.hand(userId: viewerId, raised: raising))
            }
            toast = raising ? .success(RoomCopy.handRaised) : .info(RoomCopy.handLowered)
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    // MARK: - Host controls

    /// Hands somebody the microphone — the answer to a raised hand, or an
    /// invitation out of the blue.
    public func promote(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomSpeakerPromoted) { [service, room] handle in
            try await service.promote(roomId: room.id, handle: handle)
        } success: { RoomCopy.invited(actions.target.name) }
    }

    /// Lowers somebody's hand without calling on them.
    public func dismissHand(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomHandDismissed) { [service, room] handle in
            try await service.dismissHand(roomId: room.id, handle: handle)
        } success: { RoomCopy.handDismissed(actions.target.name) }
    }

    /// Mutes a speaker now. They keep the seat.
    public func mute(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomSpeakerMuted) { [service, room] handle in
            try await service.mute(roomId: room.id, handle: handle)
            return room
        } success: { RoomCopy.muted(actions.target.name) }
    }

    /// Moves somebody back to the audience. They stay in the room.
    public func demote(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomSpeakerDemoted) { [service, room] handle in
            try await service.demote(roomId: room.id, handle: handle)
        } success: { RoomCopy.demoted(actions.target.name) }
    }

    /// Removes somebody from **this room**. Undoable with ``readmitLastRemoved()``.
    public func remove(_ actions: RoomHostActions) async {
        await hostCall(actions, event: .roomParticipantRemoved) { [service, room] handle in
            try await service.remove(roomId: room.id, handle: handle)
        } success: { RoomCopy.removed(actions.target.name) }
        if toast?.text == RoomCopy.removed(actions.target.name) {
            lastRemoved = actions.target
        }
    }

    /// Undoes the last removal.
    public func readmitLastRemoved() async {
        guard isHost, let target = lastRemoved else { return }
        do {
            room = try await service.readmit(roomId: room.id, handle: target.handle)
            analytics.track(.roomParticipantReadmitted)
            lastRemoved = nil
            toast = .success(RoomCopy.readmitted(target.name))
            participants = (try? await service.fetchParticipants(roomId: room.id)) ?? participants
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
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
            participants = (try? await service.fetchParticipants(roomId: room.id)) ?? participants
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func requestEnd() {
        guard isHost, !isEnding else { return }
        isConfirmingEnd = true
    }

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
        await leave()
    }

    // MARK: - Leaving

    /// Leaves the room: `POST /leave` **and** a media disconnect, always both.
    public func leave() async {
        guard !hasLeft else { return }
        hasLeft = true
        isLeaving = true
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel()
        eventTask = nil
        engine.onChange = nil
        engine.onRoomEvent = nil

        let serverLeave = Task { [service, room] in
            try? await service.leave(roomId: room.id)
        }
        await engine.disconnect()
        _ = await serverLeave.value

        connection = .idle
        isMicrophoneEnabled = false
        isLeaving = false
        phase = .left
    }

    /// Backgrounding keeps the audio and stops the poll.
    public func persistThroughBackgrounding() async {
        guard !hasLeft else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    public func resumeFromBackground() async {
        guard !hasLeft, phase == .inRoom else { return }
        await refresh()
        startPolling()
    }

    public func handleTermination() async {
        await leave()
    }
}
