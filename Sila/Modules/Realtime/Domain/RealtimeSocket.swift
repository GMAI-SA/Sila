import Foundation

/// One WebSocket, reduced to what ``RealtimeClient`` needs of it.
///
/// A seam, like ``NetworkClient``: the client's whole protocol — the token in
/// the first frame, the heartbeat, re-authentication, what each close code
/// means — is tested against a socket that is a queue of strings, and only
/// ``URLSessionRealtimeSocket`` knows about `URLSessionWebSocketTask`.
public protocol RealtimeSocket: AnyObject, Sendable {
    /// Opens the connection. Frames sent before it is open are queued by the
    /// transport.
    func open()
    /// Sends one text frame.
    func send(_ text: String) async throws
    /// The next text frame. Throws ``RealtimeSocketClosed`` once the socket
    /// has closed, for whatever reason.
    func receive() async throws -> String
    /// Closes with a WebSocket close code. Idempotent.
    func close(code: Int)
}

/// Makes a fresh socket per connection attempt.
public protocol RealtimeSocketFactory: Sendable {
    func makeSocket(url: URL) -> RealtimeSocket
}

/// How a socket ended.
public struct RealtimeSocketClosed: Error, Equatable, Sendable {
    /// The close code the server sent, or `1006` when none arrived — the
    /// connection simply dropped.
    public let code: Int
    /// The HTTP status of a refused handshake (`403` for a foreign origin),
    /// when the socket never opened.
    public let handshakeStatus: Int?

    public init(code: Int, handshakeStatus: Int? = nil) {
        self.code = code
        self.handshakeStatus = handshakeStatus
    }

    /// No close frame: the network went, or the process on the other end.
    public static let dropped = RealtimeSocketClosed(code: 1006)
}
