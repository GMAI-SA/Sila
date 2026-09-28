import Foundation

/// A socket that is two queues of strings, for tests and for the mocked
/// server below.
///
/// The client end is the ``RealtimeSocket`` the client reads; the other end
/// is ``deliver(_:)`` and ``serverClose(code:errorCode:)``, which play the
/// server. Frames arrive in order, and every frame delivered before a close
/// is read before the close is.
public final class InMemoryRealtimeSocket: RealtimeSocket, @unchecked Sendable {

    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closedWith: Int?
    private var sentFrames: [String] = []
    private var opened = false
    private let onOpen: @Sendable (InMemoryRealtimeSocket) -> Void
    private let onSend: @Sendable (InMemoryRealtimeSocket, String) -> Void

    /// - Parameters:
    ///   - onOpen: The client opened it.
    ///   - onSend: The client sent a frame — the "server" answers here.
    public init(
        onOpen: @escaping @Sendable (InMemoryRealtimeSocket) -> Void = { _ in },
        onSend: @escaping @Sendable (InMemoryRealtimeSocket, String) -> Void = { _, _ in }
    ) {
        self.onOpen = onOpen
        self.onSend = onSend
    }

    /// Every frame the client sent, in order.
    public var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    /// The close code, once closed by either end.
    public var closeCode: Int? {
        lock.lock(); defer { lock.unlock() }
        return closedWith
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened && closedWith == nil
    }

    // MARK: RealtimeSocket

    public func open() {
        lock.lock()
        opened = true
        lock.unlock()
        onOpen(self)
    }

    public func send(_ text: String) async throws {
        lock.lock()
        if let code = closedWith {
            lock.unlock()
            throw RealtimeSocketClosed(code: code)
        }
        sentFrames.append(text)
        lock.unlock()
        onSend(self, text)
    }

    public func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let frame = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if let code = closedWith {
                lock.unlock()
                continuation.resume(throwing: RealtimeSocketClosed(code: code))
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    public func close(code: Int) {
        lock.lock()
        guard closedWith == nil else { return lock.unlock() }
        closedWith = code
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(throwing: RealtimeSocketClosed(code: code))
    }

    // MARK: The server's end

    /// A frame from the server.
    public func deliver(_ text: String) {
        lock.lock()
        guard closedWith == nil else { return lock.unlock() }
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: text)
        } else {
            inbox.append(text)
            lock.unlock()
        }
    }

    /// A frame from the server, from a JSON object.
    public func deliver(json: [String: Any]) {
        var frame = json
        if frame["at"] == nil { frame["at"] = ISO8601DateFormatter().string(from: Date()) }
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return }
        deliver(String(decoding: data, as: UTF8.self))
    }

    /// The server closes, saying why first — as every close in the contract
    /// is preceded by an `error` frame.
    public func serverClose(code: Int, errorCode: String? = nil) {
        if let errorCode {
            deliver(json: ["type": "error", "code": errorCode, "message": errorCode])
        }
        // Frames already queued are read first; `receive` throws once the
        // queue is empty. A reader can only be waiting on an empty queue.
        lock.lock()
        guard closedWith == nil else { return lock.unlock() }
        closedWith = code
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(throwing: RealtimeSocketClosed(code: code))
    }
}

/// Stands in for the server's socket when the messages are mocked
/// (`-mockAuth`, `-mockMessages`): speaks contract v30 over an
/// ``InMemoryRealtimeSocket``, and plays the other person in the mocked
/// thread with @noura — who reads what the viewer sends, types, and answers.
///
/// Scenarios (`-mockRealtime <scenario>`):
/// * `replies` — the default: answers what the viewer sends.
/// * `incoming` — also writes first, once the inbox has been opened: types
///   for a while, then writes, with a notification beside it, so the inbox
///   and the badges move on their own.
/// * `unavailable` — every socket is refused `1013 realtime_unavailable`:
///   the app must carry on over HTTP alone.
public final class RealtimeServerMock: RealtimeSocketFactory, @unchecked Sendable {

    public enum Scenario: String, Sendable {
        case replies
        case incoming
        case unavailable
    }

    /// What @noura answers.
    public static let reply = "On my way"
    /// What @noura writes first, in `incoming`.
    public static let opener = "Are you coming tonight?"

    private let scenario: Scenario
    private let messages: MessagesServiceMock?
    private let otherHandle: String
    private let pace: Double
    private let lock = NSLock()
    private var current: InMemoryRealtimeSocket?
    private var wroteFirst = false
    private var notifications = 3

    /// - Parameters:
    ///   - scenario: What the other person does.
    ///   - messages: The mocked messages store the socket's events describe.
    ///   - otherHandle: Who answers.
    ///   - pace: Multiplies every delay; `0` in unit tests.
    public init(scenario: Scenario, messages: MessagesServiceMock?, otherHandle: String = "noura", pace: Double = 1) {
        self.scenario = scenario
        self.messages = messages
        self.otherHandle = otherHandle
        self.pace = pace
        if let messages {
            let hook: @Sendable (DirectMessage, Conversation) -> Void = { [weak self] message, thread in
                self?.viewerSent(message, in: thread)
            }
            let opened: @Sendable () -> Void = { [weak self] in self?.inboxOpened() }
            Task {
                await messages.setOnSent(hook)
                if scenario == .incoming { await messages.setOnInboxRead(opened) }
            }
        }
    }

    public func makeSocket(url: URL) -> RealtimeSocket {
        InMemoryRealtimeSocket(
            onOpen: { _ in },
            onSend: { [weak self] socket, text in self?.received(text, on: socket) }
        )
    }

    // MARK: - The protocol

    private func received(_ text: String, on socket: InMemoryRealtimeSocket) {
        guard let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = frame["type"] as? String else {
            socket.deliver(json: ["type": "error", "code": "bad_frame", "message": "Send a JSON object with a type."])
            return
        }
        switch type {
        case "auth":
            authenticated(socket)
        case "ping":
            socket.deliver(json: ["type": "pong"])
        case "pong", "typing":
            break
        default:
            socket.deliver(json: ["type": "error", "code": "unknown_type", "message": "Unknown frame type.", "ref": type])
        }
    }

    private func authenticated(_ socket: InMemoryRealtimeSocket) {
        if scenario == .unavailable {
            socket.serverClose(code: 1013, errorCode: "realtime_unavailable")
            return
        }
        lock.lock()
        let already = current === socket
        current = socket
        lock.unlock()
        if already {
            socket.deliver(json: [
                "type": "auth_ok", "standing": "verified",
                "token_expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(1_800)),
            ])
            return
        }
        socket.deliver(json: [
            "type": "ready",
            "connection_id": UUID().uuidString.lowercased(),
            "user_id": UserSummary.mockViewer.id.uuidString.lowercased(),
            "standing": "verified",
            "events": ["account.status", "message.deleted", "message.new", "message.read", "notification.new", "typing"],
            "heartbeat_seconds": 25,
            "typing_seconds": 6,
            "token_expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(1_800)),
        ])
    }

    // MARK: - The other person

    /// `incoming`: the first time the inbox is read, @noura types — renewed
    /// every few seconds, as the server announces somebody who keeps typing —
    /// then writes, and a notification lands.
    private func inboxOpened() {
        lock.lock()
        let first = !wroteFirst
        wroteFirst = true
        lock.unlock()
        guard first, let messages else { return }
        let handle = otherHandle
        Task { [weak self] in
            guard let self else { return }
            await self.pause(2)
            guard let thread = await messages.conversation(with: handle) else { return }
            for _ in 0..<3 {
                self.push(self.typing(in: thread, active: true))
                await self.pause(3)
            }
            guard let (updated, message) = await messages.receive(from: handle, text: Self.opener) else { return }
            self.push(self.messageNew(message, in: updated, alert: true))
            self.lock.lock()
            self.notifications += 1
            let unread = self.notifications
            self.lock.unlock()
            self.push([
                "type": "notification.new", "id": UUID().uuidString.lowercased(), "kind": "follow", "unread_count": unread,
            ])
        }
    }

    /// The viewer wrote to @noura: their own copy comes back (the sender's
    /// other devices hear it; this one drops it by id), she reads it, types,
    /// and answers.
    private func viewerSent(_ message: DirectMessage, in thread: Conversation) {
        guard let messages, thread.other.handle == otherHandle, thread.accepted else { return }
        let handle = otherHandle
        Task { [weak self] in
            guard let self else { return }
            await self.pause(0.2)
            self.push(self.messageNew(message, in: thread, alert: false))
            await self.pause(0.8)
            await messages.otherPersonRead(conversationId: thread.id)
            self.push([
                "type": "message.read",
                "conversation_id": thread.id.uuidString.lowercased(),
                "reader_id": thread.other.id.uuidString.lowercased(),
                "read_at": ISO8601DateFormatter().string(from: Date()),
            ])
            await self.pause(1.0)
            // Typing for a while, renewed as the server renews it.
            for _ in 0..<4 {
                self.push(self.typing(in: thread, active: true))
                await self.pause(3)
            }
            guard let (updated, reply) = await messages.receive(from: handle, text: Self.reply) else { return }
            self.push(self.messageNew(reply, in: updated, alert: true))
        }
    }

    private func push(_ frame: [String: Any]) {
        lock.lock()
        let socket = current
        lock.unlock()
        socket?.deliver(json: frame)
    }

    private func pause(_ seconds: Double) async {
        guard pace > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * pace * 1_000_000_000))
    }

    private func typing(in thread: Conversation, active: Bool) -> [String: Any] {
        [
            "type": "typing",
            "conversation_id": thread.id.uuidString.lowercased(),
            "user_id": thread.other.id.uuidString.lowercased(),
            "active": active,
            "expires_in": active ? 6 : 0,
        ]
    }

    private func messageNew(_ message: DirectMessage, in thread: Conversation, alert: Bool) -> [String: Any] {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sender: [String: Any] = [
            "id": message.sender.id.uuidString.lowercased(),
            "handle": message.sender.handle,
            "display_name": message.sender.displayName,
            "is_verified": message.sender.isVerified,
            "country_code": message.sender.countryCode ?? NSNull(),
        ]
        return [
            "type": "message.new",
            "conversation_id": thread.id.uuidString.lowercased(),
            "message": [
                "id": message.id.uuidString.lowercased(),
                "conversation_id": thread.id.uuidString.lowercased(),
                "sender": sender,
                "text": message.text ?? NSNull(),
                "deleted": message.deleted,
                "read": message.read,
                "created_at": stamp.string(from: message.createdAt),
            ],
            "conversation": [
                "id": thread.id.uuidString.lowercased(),
                "accepted": thread.accepted,
                "is_request": thread.isRequest,
            ],
            "alert": alert,
        ]
    }
}

/// Tokens for ``RealtimeServerMock``, which checks none.
struct MockRealtimeTokens: RealtimeTokenProviding {
    func accessToken() async throws -> String { "mock-access-token" }
    func renewedAccessToken(replacing stale: String) async throws -> String { "mock-access-token-renewed" }
}

/// Makes ``UnreachableRealtimeSocket``s.
struct UnreachableRealtimeSocketFactory: RealtimeSocketFactory {
    func makeSocket(url: URL) -> RealtimeSocket { UnreachableRealtimeSocket() }
}

/// A socket that cannot open: the URL is not a WebSocket's. The client
/// treats it as a server with no real time, and the app refreshes over HTTP.
final class UnreachableRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    func open() {}
    func send(_ text: String) async throws { throw RealtimeSocketClosed(code: 1006, handshakeStatus: 404) }
    func receive() async throws -> String { throw RealtimeSocketClosed(code: 1006, handshakeStatus: 404) }
    func close(code: Int) {}
}
