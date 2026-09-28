import Foundation

/// The production ``RealtimeSocketFactory``.
public struct URLSessionRealtimeSocketFactory: RealtimeSocketFactory {
    public init() {}

    public func makeSocket(url: URL) -> RealtimeSocket {
        URLSessionRealtimeSocket(url: url)
    }
}

/// ``RealtimeSocket`` over `URLSessionWebSocketTask`.
///
/// **No credentials in the handshake** (contract v30 §1.1): no token in the
/// URL, no cookie, no header — the token is the first frame. The session is
/// ephemeral, so no cookie store is consulted, and it sends no `Origin`: the
/// server admits a native app that names none.
public final class URLSessionRealtimeSocket: NSObject, RealtimeSocket, URLSessionWebSocketDelegate, @unchecked Sendable {

    private let task: URLSessionWebSocketTask
    private var session: URLSession?
    private let lock = NSLock()
    private var closeCode: Int?

    public init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        // Fail rather than wait: a socket that cannot connect is retried by
        // the client's own backoff, and the app keeps refreshing over HTTP
        // meanwhile. Waiting for connectivity here would hide that.
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConfig.requestTimeout
        self.task = session.webSocketTask(with: request)
        self.session = session
        super.init()
        task.delegate = self
    }

    public func open() {
        task.resume()
    }

    public func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw closed()
        }
    }

    public func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case let .string(text):
                return text
            case .data:
                // The protocol is JSON text. A binary frame is the server
                // closing us (1003) in all but name.
                close(code: 1003)
                throw RealtimeSocketClosed(code: 1003)
            @unknown default:
                throw closed()
            }
        } catch let closed as RealtimeSocketClosed {
            throw closed
        } catch {
            throw self.closed()
        }
    }

    public func close(code: Int) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: nil)
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
    }

    /// What the socket ended with: the close frame's code when one arrived,
    /// the handshake's status when it never opened, `1006` otherwise.
    private func closed() -> RealtimeSocketClosed {
        lock.lock()
        let delegated = closeCode
        lock.unlock()
        let code = delegated ?? (task.closeCode != .invalid ? task.closeCode.rawValue : 1006)
        let status = (task.response as? HTTPURLResponse)?.statusCode
        return RealtimeSocketClosed(code: code, handshakeStatus: status == 101 ? nil : status)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        self.closeCode = closeCode.rawValue
        lock.unlock()
    }
}
