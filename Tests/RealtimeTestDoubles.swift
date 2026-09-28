import XCTest
@testable import Sila

/// Hands out ``InMemoryRealtimeSocket``s and plays the server behind them:
/// by default it answers the token with `ready`, as the real one does.
final class ScriptedSockets: RealtimeSocketFactory, @unchecked Sendable {

    private let lock = NSLock()
    private var sockets: [InMemoryRealtimeSocket] = []
    private var urls: [URL] = []
    /// What the "server" does with a client frame on the `n`th socket (from 0).
    /// The default answers `auth` with `ready` and `ping` with `pong`.
    var respond: (@Sendable (_ index: Int, _ socket: InMemoryRealtimeSocket, _ frame: [String: Any]) -> Void)?

    var made: [InMemoryRealtimeSocket] {
        lock.lock(); defer { lock.unlock() }
        return sockets
    }

    var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    func makeSocket(url: URL) -> RealtimeSocket {
        lock.lock()
        let index = sockets.count
        lock.unlock()
        let socket = InMemoryRealtimeSocket(onSend: { [weak self] socket, text in
            guard let self,
                  let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
            if let respond = self.respond {
                respond(index, socket, frame)
            } else {
                Self.answer(socket, frame)
            }
        })
        lock.lock()
        sockets.append(socket)
        urls.append(url)
        lock.unlock()
        return socket
    }

    /// What the server says to a verified account's token and to a ping.
    static func answer(_ socket: InMemoryRealtimeSocket, _ frame: [String: Any], standing: String = "verified") {
        switch frame["type"] as? String {
        case "auth":
            if socket.sent.filter({ $0.contains(#""type":"auth""#) }).count > 1 {
                socket.deliver(json: ["type": "auth_ok", "standing": standing])
            } else {
                socket.deliver(json: ready(standing: standing))
            }
        case "ping":
            socket.deliver(json: ["type": "pong"])
        default:
            break
        }
    }

    static func ready(standing: String = "verified") -> [String: Any] {
        [
            "type": "ready",
            "connection_id": "c0ffee",
            "user_id": UserSummary.mockViewer.id.uuidString.lowercased(),
            "standing": standing,
            "events": standing == "none"
                ? ["account.status"]
                : ["account.status", "message.deleted", "message.new", "message.read", "notification.new", "typing"],
            "heartbeat_seconds": 25,
            "typing_seconds": 6,
            "token_expires_at": "2026-09-28T15:15:33+00:00",
        ]
    }
}

/// Tokens that count how they were asked for.
actor CountingRealtimeTokens: RealtimeTokenProviding {

    private(set) var issued = 0
    private(set) var renewals: [String] = []
    private var failure: Error?

    init(failing failure: Error? = nil) {
        self.failure = failure
    }

    func fail(with error: Error?) { failure = error }

    func accessToken() async throws -> String {
        if let failure { throw failure }
        issued += 1
        return "tok-\(issued)"
    }

    func renewedAccessToken(replacing stale: String) async throws -> String {
        if let failure { throw failure }
        renewals.append(stale)
        issued += 1
        return "tok-\(issued)"
    }
}

/// Records every wait the client asks for, and waits only a moment, so a
/// client that keeps reconnecting cannot spin.
actor RecordedWaits {
    private(set) var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

/// Counts suspensions reported.
final class SuspensionCounter: SuspensionReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reported: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func accountSuspended() {
        lock.lock(); count += 1; lock.unlock()
    }
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

/// A stand-in for the socket, for screens: events are pushed by the test,
/// typing frames are recorded.
@MainActor
final class FakeRealtime: RealtimeMessaging {
    var isLive = true
    private(set) var typingSent: [(UUID, Bool)] = []
    private var continuations: [AsyncStream<RealtimeEvent>.Continuation] = []

    func events() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        continuations.append(continuation)
        return stream
    }

    func push(_ event: RealtimeEvent) {
        for continuation in continuations { continuation.yield(event) }
    }

    @discardableResult
    func sendTyping(conversationId: UUID, active: Bool) -> Bool {
        guard isLive else { return false }
        typingSent.append((conversationId, active))
        return true
    }
}

extension XCTestCase {

    /// Waits, on the main actor, until `condition` holds.
    @MainActor
    func eventually(
        timeout: TimeInterval = 3,
        _ message: @autoclosure () -> String = "condition never held",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if await condition() { return }
        XCTFail(message(), file: file, line: line)
    }
}

/// One JSON frame, parsed.
func frameObject(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}
