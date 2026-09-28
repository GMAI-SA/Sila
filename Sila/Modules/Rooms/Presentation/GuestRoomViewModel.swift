import Foundation
import Observation

/// A guest's time in a room (contract v31): ask for a seat, connect at once,
/// renew the seat before its token lapses, and find out why when the
/// connection goes.
///
/// - **Asking**: `POST /public/rooms/{id}/listen`, with the pass from an
///   earlier answer when there is one (``GuestPassBook``), so the same seat
///   comes back instead of a second.
/// - **Connecting** straight after the answer, listen-only: an unconnected
///   token holds its seat for ninety seconds only. `canPublish` is `false`,
///   the engine is built with ``NoMicrophonePermission``, and nothing here
///   ever calls anything that publishes — **the microphone is never asked
///   for**.
/// - **Renewing** a minute before the token's ten minutes are up, with the
///   pass. The answer brings the room's card too, so the counts stay fresh;
///   a refusal then (the room ended, guests were turned off) ends the
///   listening.
/// - **Losing the connection**: the server took the guest out, or the line
///   went. Asking again says why (a refusal) or hands a fresh token — at most
///   twice a minute, then the screen offers "Try again".
///
/// Everything that takes part — speaking, a hand, a reaction, the chat, a
/// question, a poll — is the screen's invitation to join; this model has no
/// way to send any of it.
@MainActor
@Observable
public final class GuestRoomViewModel {

    public enum Phase: Equatable, Sendable {
        /// Asking for a seat, or dialling the media server with it.
        case connecting
        /// Hearing the room.
        case listening
        /// Not listening, and why.
        case refused(GuestRefusal)
    }

    public let roomId: UUID
    public private(set) var phase: Phase = .connecting
    /// The room's public card: from the tap that opened it, then from every
    /// answer. `nil` for a shared link until the first answer.
    public private(set) var card: RoomCard?
    /// Everybody the media server shows: speakers and member listeners.
    /// Guests are hidden, this one included.
    public private(set) var participants: [VoiceParticipant] = []
    /// Identities the media server says are talking.
    public private(set) var speakingIds: Set<String> = []
    /// What was said while this guest listened. Read only.
    public private(set) var chat: [GuestChatLine] = []
    public private(set) var unreadChat = 0
    /// True while the chat sheet is up; unread stops counting when it is.
    public var isChatOpen = false {
        didSet { if isChatOpen { unreadChat = 0 } }
    }
    /// Emoji floating up the screen, from members.
    public private(set) var reactions: [RoomReaction] = []
    /// When the refusal came: a countdown runs from it.
    public private(set) var refusedAt: Date?
    /// The screen went away; nothing more is asked or heard.
    public private(set) var hasClosed = false

    private let service: GuestRoomsServiceProtocol
    private let passes: GuestPassBook
    private let makeEngine: @MainActor () -> VoiceEngineProtocol
    private let analytics: AnalyticsClient
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date

    @ObservationIgnored private var engine: VoiceEngineProtocol?
    /// Bumped by every start, refusal and close: an answer for an older one
    /// is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var renewTask: Task<Void, Never>?
    @ObservationIgnored private var reconnects: [Date] = []
    @ObservationIgnored private var localIds = 0

    /// - Parameters:
    ///   - roomId: The room to listen to.
    ///   - card: The card the tap came from, when it came from one.
    ///   - service: The two public routes.
    ///   - passes: The seats' passes, for the app's life.
    ///   - makeEngine: A fresh media engine per connection; a guest's is built
    ///     never to ask for the microphone.
    ///   - sleep: Waits for a renewal. Tests drive it by hand.
    ///   - now: The clock the reconnect limit and the countdown read.
    public init(
        roomId: UUID,
        card: RoomCard? = nil,
        service: GuestRoomsServiceProtocol,
        passes: GuestPassBook,
        makeEngine: @escaping @MainActor () -> VoiceEngineProtocol,
        analytics: AnalyticsClient,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.roomId = roomId
        self.card = card?.id == roomId ? card : nil
        self.service = service
        self.passes = passes
        self.makeEngine = makeEngine
        self.analytics = analytics
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Derived

    public var isListening: Bool { phase == .listening }

    public var refusal: GuestRefusal? {
        if case let .refused(refusal) = phase { return refusal }
        return nil
    }

    /// The host and the speakers, host first.
    public var stage: [VoiceParticipant] {
        participants.filter(\.isOnStage).sorted { lhs, rhs in
            if lhs.isHost != rhs.isHost { return lhs.isHost }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Members listening.
    public var audience: [VoiceParticipant] {
        participants.filter { !$0.isOnStage }
    }

    public func isSpeaking(_ participant: VoiceParticipant) -> Bool {
        speakingIds.contains(participant.identity)
    }

    /// "2 speaking · 14 listening · 3 guests listening" — from the media
    /// server while listening, from the card otherwise. Guests are counted
    /// only here: they are on nobody's stage or roster.
    public var attendanceLine: String? {
        guard let card, card.status == .live || isListening else { return nil }
        var parts: [String]
        if isListening {
            parts = [RoomCopy.attendance(speakers: stage.count, listeners: audience.count)]
        } else {
            parts = [L10n.plural("rooms.attendance.listening", max(card.participantCount, card.metrics.listeners))]
        }
        if card.liveGuestCount > 0 { parts.append(RoomCopy.guestsListening(card.liveGuestCount)) }
        return parts.joined(separator: " · ")
    }

    /// "Starts in 3 hours." for a room that has not started, when its time
    /// is known.
    public var startsLine: String? {
        guard refusal?.code == .roomNotLive, let date = card?.scheduledFor else { return nil }
        return RoomCopy.scheduledFor(date)
    }

    /// Seconds left before asking again is worth it, at `date`; 0 when now.
    public func secondsUntilRetry(at date: Date) -> Int {
        guard let refusal, let wait = refusal.retryAfter, let refusedAt else { return 0 }
        return max(0, Int((refusedAt.addingTimeInterval(TimeInterval(wait)).timeIntervalSince(date)).rounded(.up)))
    }

    // MARK: - Lifecycle

    /// Opens the room the first time the screen appears; a later appearance
    /// of the same screen (a sheet closing over it) changes nothing.
    public func open() async {
        guard !hasOpened else { return }
        hasOpened = true
        await start()
    }
    @ObservationIgnored private var hasOpened = false

    /// Opens the room, or tries again: ask for a seat, and connect with it.
    public func start() async {
        guard !hasClosed else { return }
        reconnects = []
        analytics.track(.guestRoomOpened, properties: ["room_id": roomId.uuidString.lowercased(), "is_guest": "true"])
        await restart()
    }

    /// Leaving, or the screen going away: the connection closes and the
    /// renewal stops. The seat is the server's to end.
    public func close() async {
        guard !hasClosed else { return }
        hasClosed = true
        generation += 1
        stopRenewing()
        await dropEngine()
        participants = []
        speakingIds = []
    }

    private func restart() async {
        generation += 1
        let current = generation
        stopRenewing()
        await dropEngine()
        guard current == generation, !hasClosed else { return }
        phase = .connecting
        refusedAt = nil
        participants = []
        speakingIds = []
        await attempt(current)
    }

    private func attempt(_ current: Int) async {
        let seat: GuestSeat
        do {
            seat = try await service.listen(roomId: roomId, guestPass: passes.pass(for: roomId))
        } catch {
            guard current == generation, !hasClosed, !APIError.wrapping(error).isCancellation else { return }
            refuse(GuestRefusal(error: error))
            return
        }
        // Kept even when this attempt was overtaken: it is the same seat.
        passes.keep(seat.guestPass, for: roomId)
        guard current == generation, !hasClosed else { return }
        if let room = seat.room { card = room }
        scheduleRenewal(after: GuestListening.renewDelay(expiresIn: seat.expiresIn), current)

        // At once: an unconnected token holds its seat for ninety seconds.
        let engine = makeEngine()
        self.engine = engine
        engine.onChange = { [weak self] in self?.engineChanged(current) }
        engine.onRoomEvent = { [weak self] event in self?.handle(event, current) }
        do {
            try await engine.connect(url: seat.url, token: seat.token, canPublish: false)
        } catch {
            guard current == generation, !hasClosed else { return }
            if case VoiceEngineError.cancelled = error { return }
            refuse(GuestRefusal(.connectFailed))
            return
        }
        guard current == generation, !hasClosed else {
            engine.onChange = nil
            engine.onRoomEvent = nil
            await engine.disconnect()
            return
        }
        phase = .listening
        adoptEngine()
        analytics.track(.guestRoomListening, properties: ["room_id": roomId.uuidString.lowercased(), "is_guest": "true"])
    }

    // MARK: - The connection

    private func engineChanged(_ current: Int) {
        guard current == generation, let engine else { return }
        adoptEngine()
        guard phase == .listening else { return }
        switch engine.connection {
        case .idle, .failed: connectionDropped()
        case .connecting, .connected, .reconnecting: break
        }
    }

    private func adoptEngine() {
        guard let engine else { return }
        participants = engine.participants
        speakingIds = Set(engine.speakingIdentities.map { $0.lowercased() })
    }

    /// The server took the guest out, or the line went. Asking again says
    /// which: a refusal, or a fresh token to connect with.
    private func connectionDropped() {
        let at = now()
        reconnects = reconnects.filter { at.timeIntervalSince($0) < 60 }
        guard GuestListening.mayReconnect(now: at, previous: reconnects) else {
            refuse(GuestRefusal(.connectFailed))
            return
        }
        reconnects.append(at)
        // The dying connection says so more than once (disconnected, then
        // why); only the first is a drop.
        generation += 1
        phase = .connecting
        Task { [weak self] in await self?.restart() }
    }

    private func handle(_ event: VoiceRoomEvent, _ current: Int) {
        guard current == generation else { return }
        switch event {
        case let .message(message):
            receive(message)
        case .participantJoined, .participantLeft, .metadataChanged, .muteChanged, .permissionsChanged:
            adoptEngine()
        }
    }

    // MARK: - What the room says

    private func receive(_ message: RoomDataMessage) {
        switch message.type {
        case "guests_changed":
            // The host turned guests off: the server is taking this seat out.
            if message.allowGuests == false { refuse(GuestRefusal(.guestsNotAllowed)) }
        case "reaction":
            guard let emoji = message.emoji, !emoji.isEmpty else { return }
            show(RoomReaction(emoji: emoji, name: message.name ?? message.handle, big: message.big))
        case "chat_hidden":
            guard let hidden = message.messageId?.lowercased() else { return }
            chat.removeAll { $0.id == hidden }
        default:
            guard let line = GuestChatLine.from(message, localId: { [unowned self] in
                self.localIds += 1
                return "local-\(self.localIds)"
            }) else { return }
            guard !chat.contains(where: { $0.id == line.id }) else { return }
            chat.append(line)
            if chat.count > GuestListening.chatLimit { chat.removeFirst(chat.count - GuestListening.chatLimit) }
            if !isChatOpen { unreadChat += 1 }
        }
    }

    private func show(_ reaction: RoomReaction) {
        reactions.append(reaction)
        if reactions.count > 12 { reactions.removeFirst(reactions.count - 12) }
        let lifetime: TimeInterval = reaction.big ? 5.5 : 4
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            self?.reactions.removeAll { $0.id == reaction.id }
        }
    }

    // MARK: - Renewing

    private func scheduleRenewal(after delay: TimeInterval, _ current: Int) {
        renewTask?.cancel()
        renewTask = Task { [weak self, sleep = self.sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.renew(current)
        }
    }

    private func renew(_ current: Int) async {
        guard current == generation, !hasClosed else { return }
        do {
            let seat = try await service.listen(roomId: roomId, guestPass: passes.pass(for: roomId))
            passes.keep(seat.guestPass, for: roomId)
            guard current == generation, !hasClosed else { return }
            if let room = seat.room { card = room }
            scheduleRenewal(after: GuestListening.renewDelay(expiresIn: seat.expiresIn), current)
        } catch {
            guard current == generation, !hasClosed, !APIError.wrapping(error).isCancellation else { return }
            let refusal = GuestRefusal(error: error)
            switch refusal.code {
            case .connectFailed, .guestsFull:
                // The line blinked, or a seat race: still connected, so ask
                // again shortly.
                scheduleRenewal(after: GuestListening.renewRetryDelay, current)
            case .rateLimited:
                scheduleRenewal(
                    after: max(GuestListening.renewRetryDelay, TimeInterval(refusal.retryAfter ?? 60)),
                    current
                )
            default:
                // Ended, turned off, closed, gone: the server is closing it.
                refuse(refusal)
            }
        }
    }

    private func stopRenewing() {
        renewTask?.cancel()
        renewTask = nil
    }

    // MARK: - Refusing

    private func refuse(_ refusal: GuestRefusal) {
        generation += 1
        stopRenewing()
        if let old = engine {
            engine = nil
            old.onChange = nil
            old.onRoomEvent = nil
            Task { await old.disconnect() }
        }
        participants = []
        speakingIds = []
        reactions = []
        phase = .refused(refusal)
        refusedAt = now()
        analytics.track(.guestRoomRefused, properties: [
            "room_id": roomId.uuidString.lowercased(), "reason": refusal.code.rawValue, "is_guest": "true"
        ])
        if refusal.code == .roomNotLive, card?.scheduledFor == nil {
            Task { [weak self] in await self?.findScheduledCard() }
        }
    }

    /// "Starts …" for a room that is not live yet, when the link did not
    /// bring its card: the scheduled list has it.
    private func findScheduledCard() async {
        guard let rooms = try? await service.fetchRooms(status: .scheduled, limit: GuestListening.maximumListLimit),
              let found = rooms.first(where: { $0.id == roomId }),
              card?.scheduledFor == nil else { return }
        card = found
    }

    private func dropEngine() async {
        guard let old = engine else { return }
        engine = nil
        old.onChange = nil
        old.onRoomEvent = nil
        await old.disconnect()
    }
}
