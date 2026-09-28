import Foundation

/// Sends video pieces through a **background** `URLSession`, so an upload
/// keeps going while the app is suspended — switched away from, the phone
/// locked — and the system wakes the app when the pieces have gone.
///
/// One per process, and shared: a background session is named, the system
/// keeps exactly one per name, and a second object claiming the same name
/// would never hear about its tasks. That is also why this is one of the few
/// shared instances in the app rather than something the container builds.
///
/// Each piece is its own upload task from its own file (a background session
/// uploads from files only). A task that finishes while no one is waiting —
/// the app was relaunched in between — is simply let go: the uploader asks
/// the server where the upload stands when it resumes, and sends only what
/// is missing.
///
/// Where the system's transfer daemon will not take the app's tasks — it
/// refuses a build that is not code-signed, as the simulator's are here —
/// the pieces go through an ordinary session instead, for the rest of the
/// process: an upload that only works in the background would be one that
/// never works in front of anybody.
public final class BackgroundVideoUploadTransport: NSObject, VideoUploadTransport, @unchecked Sendable {

    /// The session's name.
    public static let identifier = "com.socialsa.sila.video-upload"
    /// The app's transport.
    public static let shared = BackgroundVideoUploadTransport(identifier: identifier)

    private let identifier: String
    private let lock = NSLock()
    private var lazySession: URLSession?
    private var waiting: [Int: Waiting] = [:]
    /// Handed over by the system when it relaunched the app for this
    /// session's events; called once they have all been delivered.
    private var eventsDone: (() -> Void)?
    /// Set once the daemon has turned a task away.
    private var foreground: ForegroundVideoUploadTransport?

    fileprivate struct Waiting {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        let progress: @Sendable (Int64) -> Void
        var body = Data()
    }

    /// - Parameter identifier: The session's name. Tests use their own, so
    ///   they never share the app's.
    public init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let lazySession { return lazySession }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // Somebody pressed Post: this is not work to put off until the phone
        // is charging.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = VideoLimits.parallelPieces
        // An upload lives a day on the server; a piece waiting longer for a
        // connection is waiting for nothing.
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.timeoutIntervalForRequest = VideoUploadTiming.pieceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "sila.video-upload"
        let made = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lazySession = made
        return made
    }

    /// The system relaunched the app for this session's events. Reconnects
    /// to the session so they are delivered, and keeps `completion` for when
    /// they have been.
    /// - Returns: `false` when the events belong to another session.
    @discardableResult
    public func handleEvents(forSession identifier: String, completion: @escaping () -> Void) -> Bool {
        guard identifier == self.identifier else { return false }
        lock.lock()
        eventsDone = completion
        lock.unlock()
        _ = session
        return true
    }

    // MARK: - VideoUploadTransport

    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        if let foreground = lock.withLock({ self.foreground }) {
            return try await foreground.upload(request, fromFile: file, progress: progress)
        }
        do {
            return try await backgroundUpload(request, fromFile: file, progress: progress)
        } catch is DaemonUnavailable {
            let foreground = lock.withLock { () -> ForegroundVideoUploadTransport in
                if let existing = self.foreground { return existing }
                let made = ForegroundVideoUploadTransport()
                self.foreground = made
                return made
            }
            return try await foreground.upload(request, fromFile: file, progress: progress)
        }
    }

    private func backgroundUpload(
        _ request: URLRequest,
        fromFile file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: file)
                lock.lock()
                waiting[task.taskIdentifier] = Waiting(continuation: continuation, progress: progress)
                lock.unlock()
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    public func cancelAll() async {
        let (made, foreground) = lock.withLock { (lazySession, self.foreground) }
        await foreground?.cancelAll()
        // Nothing to cancel in a session never made; making one just to
        // look would be work for nothing.
        guard let made else { return }
        let tasks = await made.allTasks
        tasks.forEach { $0.cancel() }
    }

    /// Whether the pieces are going through an ordinary session because the
    /// daemon turned this app away.
    var usesForegroundFallback: Bool { lock.withLock { foreground != nil } }

    /// The daemon would not take the task: not a failure of the network.
    struct DaemonUnavailable: Error {}

    /// The errors a task gets when the transfer daemon is not there for
    /// this app, rather than when the network is not.
    static func meansNoDaemon(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.unknown, .backgroundSessionWasDisconnected, .backgroundSessionInUseByAnotherProcess,
                .backgroundSessionRequiresSharedContainer].contains(code)
    }

    // MARK: - Bookkeeping

    fileprivate func take(_ identifier: Int) -> Waiting? {
        lock.lock()
        defer { lock.unlock() }
        return waiting.removeValue(forKey: identifier)
    }

    fileprivate func append(_ data: Data, to identifier: Int) {
        lock.lock()
        waiting[identifier]?.body.append(data)
        lock.unlock()
    }

    fileprivate func progressHandler(_ identifier: Int) -> (@Sendable (Int64) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return waiting[identifier]?.progress
    }

    fileprivate func finishEvents() {
        lock.lock()
        let done = eventsDone
        eventsDone = nil
        lock.unlock()
        guard let done else { return }
        DispatchQueue.main.async { done() }
    }
}

extension BackgroundVideoUploadTransport: URLSessionDataDelegate {

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progressHandler(task.taskIdentifier)?(totalBytesSent)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        append(data, to: dataTask.taskIdentifier)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Nobody waiting: a task from before a relaunch. The uploader reads
        // the server's state when it resumes, so there is nothing to do.
        guard let waiting = take(task.taskIdentifier) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                waiting.continuation.resume(throwing: CancellationError())
            } else if Self.meansNoDaemon(error) {
                waiting.continuation.resume(throwing: DaemonUnavailable())
            } else {
                waiting.continuation.resume(throwing: APIError.wrapping(error))
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            waiting.continuation.resume(throwing: APIError.transport("The server returned a non-HTTP response."))
            return
        }
        waiting.continuation.resume(returning: (waiting.body, response))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishEvents()
    }
}

/// Sends pieces through an ordinary session: the live tests' transport, and
/// a fallback anywhere a background session cannot be had.
public final class ForegroundVideoUploadTransport: VideoUploadTransport, @unchecked Sendable {

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = VideoUploadTiming.pieceTimeout * 2
        configuration.httpMaximumConnectionsPerHost = VideoLimits.parallelPieces
        session = URLSession(configuration: configuration)
    }

    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = PieceProgressDelegate(progress)
        do {
            let (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("The server returned a non-HTTP response.")
            }
            return (data, http)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.wrapping(error)
        }
    }

    public func cancelAll() async {
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
    }
}

/// Reports a piece's bytes sent.
private final class PieceProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}

/// The task a cancellation must reach, which may not exist yet when the
/// cancellation arrives.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
