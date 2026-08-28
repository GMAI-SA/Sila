import Foundation

/// **The Auth module's entire public API surface.**
///
/// Phases 2–10 may depend on this protocol and on nothing else in
/// `Modules/Auth/`. They must not import ``AuthService``, any view model, or
/// any screen.
public protocol AuthSessionProtocol: AnyObject, Sendable {

    /// The signed-in account, or `nil` when there is no session.
    var currentUser: AuthUser? { get async }

    /// Whether the current user has completed identity verification.
    var isVerified: Bool { get async }

    /// Gate used by feature screens on appear.
    /// - Throws: ``AuthGateError/notAuthenticated`` or ``AuthGateError/notVerified``.
    func requireVerified() async throws
}

/// Failures thrown by ``AuthSessionProtocol/requireVerified()``.
public enum AuthGateError: Error, Equatable {
    /// No session at all — send the user to the welcome screen.
    case notAuthenticated
    /// Signed in but not verified — send the user to the wall.
    case notVerified(VerificationStatus)
}
