import Foundation
import UIKit

/// Time iOS lends an app to finish something after it leaves the screen.
///
/// Asked for around the two steps of a video that must not stop half way
/// when somebody switches to another app while they wait: compressing the
/// picked file, and writing the post that waited for its video. iOS lends
/// about half a minute. When that runs out, `onExpiry` stops the work
/// cleanly and the time is handed back at once, as iOS requires of an app
/// that wants to keep running in the background at all.
///
/// It also notes whether the app went to the background while the time was
/// held, so a failure there can be told apart from a failure on screen.
final class VideoBackgroundTime: @unchecked Sendable {

    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var wentAway = false
    private var observer: NSObjectProtocol?

    private init() {}

    /// Asks for the time.
    /// - Parameters:
    ///   - name: What the time is for, as the system's logs show it.
    ///   - onExpiry: Stops the work. Called on the main thread, once, and
    ///     only if the time runs out first.
    @MainActor
    static func begin(_ name: String, onExpiry: @escaping @Sendable () -> Void = {}) -> VideoBackgroundTime {
        let time = VideoBackgroundTime()
        time.observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak time] _ in
            time?.markAway()
        }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak time] in
            onExpiry()
            // iOS calls this on the main thread and ends the app if the time
            // is not handed back before it returns.
            MainActor.assumeIsolated { time?.handBack() }
        }
        time.lock.withLock { time.identifier = identifier }
        return time
    }

    /// Hands the time back.
    /// - Returns: Whether the app was in the background at any point while
    ///   the time was held, or is now.
    @MainActor
    @discardableResult
    func finish() -> Bool {
        let away = lock.withLock { wentAway } || UIApplication.shared.applicationState == .background
        handBack()
        return away
    }

    /// Safe to call more than once: only the first call hands anything back.
    @MainActor
    private func handBack() {
        let (identifier, observer) = lock.withLock { () -> (UIBackgroundTaskIdentifier, NSObjectProtocol?) in
            let taken = (self.identifier, self.observer)
            self.identifier = .invalid
            self.observer = nil
            return taken
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
    }

    private func markAway() {
        lock.withLock { wentAway = true }
    }

    deinit {
        // Never left holding time nobody will hand back: iOS would end the
        // app for it.
        let identifier = self.identifier
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard identifier != .invalid else { return }
        Task { @MainActor in UIApplication.shared.endBackgroundTask(identifier) }
    }
}
