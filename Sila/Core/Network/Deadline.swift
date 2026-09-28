import Foundation

/// Waiting for the server for a few seconds, whatever the network does.
///
/// Offline, a request does not fail at once: the client waits for a
/// connection for up to ``AppConfig/connectivityWait``. That is right for a
/// feed somebody is waiting to read, and wrong for a call whose answer changes
/// nothing on the phone — sign-out, which ends the session here whatever the
/// server says. Such a call gives the server a few seconds and then goes on
/// without it.
public enum Deadline {

    /// Sleeps for `seconds`, or less if the waiting is cancelled.
    public static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Runs `operation` until it finishes or `deadline` returns, whichever
    /// comes first.
    ///
    /// Past the deadline the operation is cancelled — a request still waiting
    /// for a connection is abandoned — and nobody waits for it any longer.
    /// - Returns: `true` when the operation finished in time.
    @discardableResult
    public static func run(
        _ operation: @escaping @Sendable () async -> Void,
        until deadline: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let work = Task { await operation() }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                await deadline()
                once.resume(false)
            }
            Task {
                await work.value
                once.resume(true)
                timer.cancel()
            }
        }
        if !finished { work.cancel() }
        return finished
    }
}

/// Resumes a continuation with the first value it is handed; later ones are
/// dropped.
final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let taken: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
