import Foundation
import Observation

/// Supplies access tokens to the socket.
///
/// Separate from ``AccessTokenProviding`` because the socket needs one thing
/// no HTTP call does: a token *other than the one it holds*, when the server
/// asks for a fresh one a minute before expiry (`reauth_required`) or closes
/// `4401 token_expired`. The ordinary provider would hand back the same token
/// until it is inside its own one-minute margin.
public protocol RealtimeTokenProviding: Sendable {
    /// A token to open a socket with — the stored one, refreshed first when
    /// it is about to expire.
    func accessToken() async throws -> String
    /// A token other than `stale`, good for more than a minute: whatever is
    /// stored when another caller has already rotated it, a refresh otherwise.
    func renewedAccessToken(replacing stale: String) async throws -> String
}

/// What a thread or a list needs from real time.
@MainActor
public protocol RealtimeMessaging: AnyObject {
    /// `true` while a socket is up and has said `ready`.
    var isLive: Bool { get }
    /// Every event from now on, until the stream is dropped.
    func events() -> AsyncStream<RealtimeEvent>
    /// Says the viewer is typing in a thread, or stopped.
    /// - Returns: `false` when nothing was sent, because no socket is live.
    @discardableResult
    func sendTyping(conversationId: UUID, active: Bool) -> Bool
}

/// The one WebSocket the app holds (contract v30).
///
/// **Connected while the app is in the foreground and somebody is signed
/// in**, closed in the background — the push covers the time between — and
/// closed at sign-out. ``AppContainer/updateRealtime()`` decides; this type
/// only does what it is told, and the protocol:
///
/// * The handshake carries nothing. The access token is the **first frame**.
/// * `ping` is answered `pong`; a socket silent for longer than the server's
///   own limit is presumed dead and replaced.
/// * `reauth_required` is answered with a fresh token on the same socket.
/// * Every close is decided by ``RealtimeCloseDecision``: reconnect with
///   backoff, renew the token first, or stop (a suspension is reported to
///   ``SuspensionMonitor`` exactly as a `403` from any HTTP call is).
///
/// Nothing depends on it being up. Every screen refreshes over HTTP as it did
/// before, and when the socket is refused or the phone is offline that is all
/// that happens; the events only make things arrive sooner.
@MainActor
@Observable
public final class RealtimeClient: RealtimeMessaging {

    /// Where the connection stands.
    public enum State: Equatable, Sendable {
        /// Not wanted: in the background, or nobody signed in.
        case off
        case connecting
        /// Up, and `ready` said which standing it serves.
        case live(standing: String)
        /// Closed; trying again after `seconds`.
        case waiting(seconds: TimeInterval)
        /// Will not reconnect until started again.
        case stopped(RealtimeStopReason)
    }

    public private(set) var state: State = .off
    /// The last `ready`.
    public private(set) var ready: RealtimeReady?

    public var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    private let url: URL
    private let sockets: RealtimeSocketFactory
    private let tokens: RealtimeTokenProviding
    private let suspension: SuspensionReporting?
    /// The token could not be renewed because the server refused the session:
    /// the app signs out, as the contract says ("sign in if the refresh fails").
    private let onSessionRefused: (@MainActor (Error) async -> Void)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double
    /// How long after a `1013` the screens wait before refreshing.
    private let refreshPause: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    /// Silence after which a socket is presumed dead. The server pings every
    /// 25 s and closes after 75 s without an answer; a phone that has heard
    /// nothing for as long has lost the connection without being told.
    let silenceLimit: TimeInterval

    private var wanted = false
    private var accountId: UUID?
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var socket: RealtimeSocket?
    private var token: String?
    private var lastHeard = Date.distantPast
    private var sendChain: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]

    /// - Parameters:
    ///   - url: `wss://…/api/v1/realtime` (``AppConfig/realtimeURL``).
    ///   - sockets: Makes the transport; a queue of strings in tests.
    ///   - tokens: The session's tokens.
    ///   - suspension: Told about `account_suspended`, as the HTTP client is.
    ///   - onSessionRefused: The token could not be renewed: the session is over.
    ///   - sleep: Waits between attempts. Injectable so tests do not.
    ///   - jitter: `0...1`.
    ///   - refreshPause: The pause before ``RealtimeEvent/unavailable``
    ///     reaches the screens: random, up to ten seconds (§1.7).
    ///   - now: The clock the heartbeat watchdog reads.
    ///   - silenceLimit: How long without a frame before the socket is replaced.
    public init(
        url: URL,
        sockets: RealtimeSocketFactory,
        tokens: RealtimeTokenProviding,
        suspension: SuspensionReporting? = nil,
        onSessionRefused: (@MainActor (Error) async -> Void)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        refreshPause: @escaping @Sendable () -> TimeInterval = {
            RealtimeBackoff.unavailableRefreshPause(jitter: Double.random(in: 0...1))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        silenceLimit: TimeInterval = 80
    ) {
        self.url = url
        self.sockets = sockets
        self.tokens = tokens
        self.suspension = suspension
        self.onSessionRefused = onSessionRefused
        self.sleep = sleep
        self.jitter = jitter
        self.refreshPause = refreshPause
        self.now = now
        self.silenceLimit = silenceLimit
    }

    // MARK: - Wanted or not

    /// Connects for `accountId`, unless already connected or trying for it.
    /// A different account replaces the socket.
    public func start(accountId: UUID?) {
        if wanted, loop != nil, self.accountId == accountId { return }
        halt()
        wanted = true
        self.accountId = accountId
        generation += 1
        let current = generation
        loop = Task { [weak self] in await self?.run(current) }
    }

    /// Closes the socket and stops trying — the app went to the background,
    /// or nobody is signed in.
    public func stop() {
        wanted = false
        accountId = nil
        halt()
        state = .off
        ready = nil
    }

    private func halt() {
        generation += 1
        loop?.cancel()
        loop = nil
        let wasUp = socket != nil
        // 1000, a normal close: the server gives the socket's place back at once.
        socket?.close(code: 1000)
        socket = nil
        token = nil
        sendChain = nil
        if wasUp { emit(.disconnected) }
    }

    // MARK: - Events

    public func events() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func emit(_ event: RealtimeEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// `1013`: the screens refresh as they did before real time — after a
    /// random pause of up to ten seconds (contract v30 §1.7), so the phones a
    /// replica drops at the same moment do not all refresh in the same
    /// second. Not if the socket was stopped or restarted meanwhile: its next
    /// `ready` refreshes them anyway.
    private func announceUnavailable(_ current: Int) {
        let pause = refreshPause()
        Task { [weak self] in
            if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            guard let self, current == self.generation else { return }
            self.emit(.unavailable)
        }
    }

    // MARK: - Sending

    @discardableResult
    public func sendTyping(conversationId: UUID, active: Bool) -> Bool {
        guard isLive, let socket else { return false }
        enqueue(RealtimeOutgoing.typing(conversationId: conversationId, active: active), on: socket)
        return true
    }

    /// Sends in order: a typing "stopped" must never overtake its "started".
    private func enqueue(_ text: String, on socket: RealtimeSocket) {
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            try? await socket.send(text)
        }
    }

    // MARK: - The loop

    private enum Outcome {
        case closed(RealtimeCloseDecision, stayedUp: TimeInterval?)
        case cancelled
    }

    private func run(_ current: Int) async {
        var attempt = 0
        var renew = false
        var renewals = 0
        while wanted, current == generation, !Task.isCancelled {
            let outcome = await connect(current, renewing: renew)
            guard current == generation, !Task.isCancelled else { return }
            renew = false
            guard case let .closed(decision, stayedUp) = outcome else { return }
            if let stayedUp, stayedUp >= RealtimeBackoff.resetAfter {
                attempt = 0
                renewals = 0
            }
            let delay: TimeInterval
            switch decision {
            case let .stop(reason):
                if reason == .suspended { suspension?.accountSuspended() }
                state = .stopped(reason)
                loop = nil
                return
            case .renewToken:
                renew = true
                renewals += 1
                // Once at once; a token refused again straight after renewal
                // is not fixed by asking faster.
                delay = renewals == 1 ? 0 : RealtimeBackoff.delay(.backoff, attempt: attempt, jitter: jitter())
                if renewals > 1 { attempt += 1 }
            case let .retry(retry):
                delay = RealtimeBackoff.delay(retry, attempt: attempt, jitter: jitter())
                attempt += 1
            }
            state = .waiting(seconds: delay)
            if delay > 0 {
                do { try await sleep(delay) } catch { return }
            }
        }
    }

    /// One socket, from the token to its close.
    private func connect(_ current: Int, renewing: Bool) async -> Outcome {
        state = .connecting

        let token: String
        do {
            if renewing, let stale = self.token {
                token = try await tokens.renewedAccessToken(replacing: stale)
            } else {
                token = try await tokens.accessToken()
            }
        } catch {
            guard current == generation else { return .cancelled }
            return .closed(await tokenFailed(error), stayedUp: nil)
        }
        guard current == generation, !Task.isCancelled else { return .cancelled }

        let socket = sockets.makeSocket(url: url)
        self.socket = socket
        self.token = token
        socket.open()
        lastHeard = now()
        enqueue(RealtimeOutgoing.auth(token: token), on: socket)

        let watchdog = watch(socket, current)
        defer { watchdog.cancel() }

        var errorCode: String?
        var upSince: Date?
        do {
            while true {
                let text = try await socket.receive()
                guard current == generation, !Task.isCancelled else {
                    socket.close(code: 1000)
                    return .cancelled
                }
                lastHeard = now()
                guard let frame = RealtimeFrame.parse(text) else { continue }
                switch frame {
                case .ping:
                    enqueue(RealtimeOutgoing.pong, on: socket)
                case .pong, .unknown:
                    break
                case let .authOK(standing, _):
                    if let standing { state = .live(standing: standing) }
                case .reauthRequired:
                    renew(on: socket, current)
                case let .error(code, ref, conversationId):
                    if ref == "typing" {
                        emit(.typingRefused(code: code, conversationId: conversationId))
                    } else {
                        errorCode = code
                    }
                case let .event(event):
                    switch event {
                    case let .ready(ready):
                        upSince = now()
                        self.ready = ready
                        state = .live(standing: ready.standing)
                    case let .accountStatus(me) where isLive:
                        // The server widens or narrows what this socket
                        // carries by itself; the state says so too.
                        state = .live(standing: me.standing.rawValue)
                    default:
                        break
                    }
                    emit(event)
                }
            }
        } catch {
            let closed = error as? RealtimeSocketClosed ?? .dropped
            socket.close(code: 1000)
            guard current == generation else { return .cancelled }
            if self.socket === socket { self.socket = nil }
            sendChain = nil
            let decision = RealtimeCloseDecision.decide(
                errorCode: errorCode,
                closeCode: closed.code,
                handshakeStatus: closed.handshakeStatus
            )
            if upSince != nil {
                // Whatever happened while it was down is only in the HTTP
                // answers now. A socket that cannot come back for a while
                // (1013) says so, so the screens refresh as they did before.
                if case .retry(.unavailable) = decision { announceUnavailable(current) }
                emit(.disconnected)
            }
            return .closed(decision, stayedUp: upSince.map { now().timeIntervalSince($0) })
        }
    }

    /// No token: the session is over, or the server cannot be reached.
    private func tokenFailed(_ error: Error) async -> RealtimeCloseDecision {
        switch Self.tokenFailure(error) {
        case .noSession:
            // Nothing stored on this phone — signing out, or signed out. The
            // session decides that, not the socket.
            return .stop(.signedOut)
        case .refused:
            await onSessionRefused?(error)
            return .stop(.signedOut)
        case .unreachable:
            // Offline, or the API itself failing: try again later.
            return .retry(.backoff)
        }
    }

    enum TokenFailure: Equatable { case noSession, refused, unreachable }

    /// Only the **server** refusing the refresh ends a session: a `401`. No
    /// token on the phone at all is somebody signing out already; anything
    /// else is the network.
    static func tokenFailure(_ error: Error) -> TokenFailure {
        guard let apiError = error as? APIError else { return .unreachable }
        if case .unauthenticated = apiError { return .noSession }
        return AuthService.isUnrecoverable(apiError) ? .refused : .unreachable
    }

    /// `reauth_required`: a fresh token on the same socket. If it cannot be
    /// had, the server closes `token_expired` thirty seconds past expiry and
    /// the reconnect renews it.
    private func renew(on socket: RealtimeSocket, _ current: Int) {
        guard let stale = token else { return }
        let tokens = tokens
        Task { [weak self] in
            do {
                let fresh = try await tokens.renewedAccessToken(replacing: stale)
                guard let self, current == self.generation, self.socket === socket else { return }
                self.token = fresh
                self.enqueue(RealtimeOutgoing.auth(token: fresh), on: socket)
            } catch {
                guard let self, current == self.generation else { return }
                switch Self.tokenFailure(error) {
                case .refused:
                    await self.onSessionRefused?(error)
                    self.stop()
                    self.state = .stopped(.signedOut)
                case .noSession:
                    self.stop()
                    self.state = .stopped(.signedOut)
                case .unreachable:
                    break
                }
            }
        }
    }

    /// Replaces a socket that has gone quiet for longer than the server's
    /// own heartbeat allows: the connection is gone and nobody said so.
    private func watch(_ socket: RealtimeSocket, _ current: Int) -> Task<Void, Never> {
        let limit = silenceLimit
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(limit / 4 * 1_000_000_000))
                guard !Task.isCancelled, let self, current == self.generation, self.socket === socket else { return }
                if self.now().timeIntervalSince(self.lastHeard) > limit {
                    socket.close(code: 1001)
                    return
                }
            }
        }
    }
}
