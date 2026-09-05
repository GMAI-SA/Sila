import Foundation
import Observation

/// A `Sendable` way to tell the app that a call was refused as unverified.
///
/// The twin of ``SuspensionReporting``, and here for the same reason:
/// ``URLSessionNetworkClient`` is not main-actor isolated and knows nothing
/// about screens, but it is the one place every request passes through.
public protocol VerificationGateReporting: Sendable {
    /// Called every time a request comes back `403 unverified`.
    func verificationRequired()
}

/// A ``VerificationGateReporting`` built from a closure.
public struct VerificationGateSignal: VerificationGateReporting {

    private let handler: @Sendable () -> Void

    public init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    public func verificationRequired() { handler() }
}

/// Turns `403 unverified` — from anywhere — back into the verification wall.
///
/// Contract v9 moved the check into `get_current_user`, so verification stopped
/// being a permission granted on top of an account and became a condition of
/// holding one: every authenticated route now refuses an unverified caller,
/// bar the four that exist to lift the refusal. A session that was fine a
/// moment ago — a moderator revoked a verification, a re-verification lapsed —
/// therefore starts answering 403 to *everything*. Left alone, that renders as
/// an error alert with a Retry button on whichever tab happened to be open,
/// and Retry produces the same 403 forever while the one screen that can fix
/// it stays out of reach.
///
/// The route is deliberately **not** decided here. `GET /auth/me` is one of the
/// four endpoints that stays open, precisely so the client can discover *why*
/// it was refused, and ``AuthSession`` already turns a status into a screen.
/// So this asks the session to re-read the truth and re-route, rather than
/// inventing a second, quieter copy of the routing rules that could disagree
/// with the first.
///
/// Reconciliation is deduplicated: an unverified account produces one 403 per
/// in-flight request, and a screen with four of them must not fire four
/// `/auth/me` calls.
@MainActor
@Observable
public final class VerificationGate {

    /// `true` while an `/auth/me` reconciliation is in flight.
    ///
    /// Observed by nothing that renders — it exists so the second, third and
    /// fourth 403 of the same burst are cheap.
    public private(set) var isReconciling = false

    /// `true` once any call has been refused as unverified this session.
    ///
    /// Kept for tests and telemetry, not for routing: the route comes from the
    /// server's answer, never from this flag.
    public private(set) var wasRefused = false

    /// What to do about it. Set by ``AppContainer`` once the session exists —
    /// the transport that feeds this gate is built *before* the session, so the
    /// wiring cannot be an initialiser argument.
    public var reconcile: (@MainActor () async -> Void)?

    private let analytics: AnalyticsClient?

    /// - Parameter analytics: Event sink. Optional so tests can build one bare.
    public init(analytics: AnalyticsClient? = nil) {
        self.analytics = analytics
    }

    /// Records a `403 unverified` seen anywhere, and reconciles once.
    public func noticeRefusal() {
        wasRefused = true
        guard !isReconciling, let reconcile else { return }
        isReconciling = true
        analytics?.track(.verificationGateTripped, properties: ["source": "403"])
        Task { @MainActor in
            await reconcile()
            isReconciling = false
        }
    }

    /// Routes an error, and reports whether it did.
    ///
    /// The mirror of ``SuspensionMonitor/notice(_:)``: when this returns `true`
    /// the caller should not publish an error string, because retrying can only
    /// produce the same 403 and the app is already on its way to the wall.
    /// - Returns: `true` when the error was `403 unverified`.
    @discardableResult
    public func notice(_ error: Error) -> Bool {
        guard APIError.wrapping(error).code == .unverified else { return false }
        noticeRefusal()
        return true
    }

    /// Forgets everything, so the next account to sign in on this device does
    /// not inherit somebody else's refusal.
    public func clear() {
        wasRefused = false
        isReconciling = false
    }

    /// The `Sendable` handle handed to the network client.
    public var signal: VerificationGateReporting {
        // Resolved on the main actor *inside* the task, for the same isolation
        // reason as ``SuspensionMonitor/signal``.
        VerificationGateSignal {
            Task { @MainActor [weak self] in self?.noticeRefusal() }
        }
    }
}
