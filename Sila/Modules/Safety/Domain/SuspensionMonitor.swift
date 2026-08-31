import Foundation
import Observation

/// A `Sendable` way to tell the app an account is suspended.
///
/// Exists so ``URLSessionNetworkClient`` — which is not main-actor isolated and
/// knows nothing about screens — can report the one HTTP failure that is not a
/// failure at all. Everything else it produces is an error a caller shows;
/// `403 account_suspended` is a route the whole app has to take.
public protocol SuspensionReporting: Sendable {
    /// Called every time a request comes back `403 account_suspended`.
    func accountSuspended()
}

/// A ``SuspensionReporting`` built from a closure.
public struct SuspensionSignal: SuspensionReporting {

    private let handler: @Sendable () -> Void

    public init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    public func accountSuspended() { handler() }
}

/// Holds the answer to "should this app be showing the suspension screen?".
///
/// One object, observed by ``RootView``, written from two directions:
///
/// * **Any call that answers `403 account_suspended`.** Every request in the app
///   goes through one ``NetworkClient``, so the interception is a single line in
///   a single place rather than a `catch` bolted onto every view model. A
///   suspended account cannot brute-force its way past this by finding a screen
///   whose author forgot.
/// * **`GET /me/suspension` itself**, which is one of the two endpoints that
///   still answer while suspended, and which supplies the reason, the expiry and
///   the appeal the screen actually renders.
///
/// It also clears itself, which matters more than it sounds: an appeal that is
/// upheld, or a suspension that simply expires, has to let somebody back into
/// the app without reinstalling it.
@MainActor
@Observable
public final class SuspensionMonitor {

    /// `true` while the app should be showing nothing but the suspension screen.
    public private(set) var isSuspended = false

    /// The record behind the screen, once `GET /me/suspension` has answered.
    ///
    /// `nil` while all that is known is "some call came back 403" — which is
    /// enough to route, and not enough to render. The screen fetches the rest.
    public private(set) var suspension: Suspension?

    private let analytics: AnalyticsClient?

    /// - Parameter analytics: Event sink. Optional so tests can build one bare.
    public init(analytics: AnalyticsClient? = nil) {
        self.analytics = analytics
    }

    /// The route the app should take.
    public var route: SafetyRoute { isSuspended ? .suspended : .normal }

    /// Records a `403 account_suspended` seen anywhere.
    ///
    /// Idempotent: a suspended account produces one of these per request, and
    /// the first is the only one that changes anything.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        analytics?.track(.suspensionRouted, properties: ["source": "403"])
    }

    /// Routes an error, and reports whether it did.
    ///
    /// Called from every safety `catch` block for the same reason
    /// ``AccountViewModel`` calls `handledDeactivation`: when this returns
    /// `true` the caller must **not** publish an error string, because retrying
    /// produces the same 403 forever and the person needs the appeal form
    /// instead.
    /// - Returns: `true` when the error was a suspension.
    @discardableResult
    public func notice(_ error: Error) -> Bool {
        guard SafetyRouting.route(forError: error) == .suspended else { return false }
        suspend()
        return true
    }

    /// Adopts what `GET /me/suspension` said — including that there is nothing
    /// wrong, which is how somebody gets back in.
    public func adopt(_ suspension: Suspension) {
        self.suspension = suspension.suspended ? suspension : nil
        let wasSuspended = isSuspended
        isSuspended = suspension.suspended
        if isSuspended && !wasSuspended {
            analytics?.track(.suspensionRouted, properties: ["source": "loaded"])
        }
        if !isSuspended && wasSuspended {
            analytics?.track(.suspensionLifted)
        }
    }

    /// Forgets everything — used when the session ends, so the next account to
    /// sign in on this device does not inherit somebody else's suspension.
    public func clear() {
        isSuspended = false
        suspension = nil
    }

    /// The `Sendable` handle handed to the network client.
    public var signal: SuspensionReporting {
        // Captured weakly again *inside* the task rather than once outside it:
        // the outer closure is `@Sendable` and may run off the main actor, so
        // reading `self` there is what the compiler refuses. Hopping to the
        // main actor first and resolving the reference there is both safe and
        // what the isolation actually requires.
        SuspensionSignal {
            Task { @MainActor [weak self] in self?.suspend() }
        }
    }
}
