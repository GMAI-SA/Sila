import Foundation

/// Why confirming a stored session with the server failed, and so what the
/// app does about it.
///
/// A launch used to treat every failure as "sign in again", which deleted a
/// perfectly good session whenever the phone was offline or a deploy answered
/// `502`. Only the first case below ends a session.
enum SessionCheckFailure: Equatable {

    /// The server says these credentials will never work again: a `401`, or
    /// no session at all. Sign out.
    case refused
    /// The API could not be reached, or answered with a failure of its own:
    /// no connection, a timeout, a `5xx`, a rate limit, or a page from
    /// something standing in front of it — a captive portal's login page
    /// where JSON should be, a proxy's or a firewall's error page. Keep the
    /// session, say the app is offline, try again.
    case unreachable
    /// The API answered, in its own words, with a refusal that is not about
    /// the credentials (a suspension, a deletion that can still be
    /// cancelled). Keep the session; the screens that make the next call
    /// route on the answer.
    case declined

    init(_ error: Error) {
        guard let apiError = error as? APIError else {
            // A cancelled task or anything else that never reached the server.
            self = .unreachable
            return
        }
        if AuthService.isUnrecoverable(apiError) {
            self = .refused
            return
        }
        switch apiError {
        case .transport, .cancelled, .decoding:
            self = .unreachable
        case .http:
            // A status with no error body the API would write: whatever
            // answered, it was not the API speaking about this session.
            self = .unreachable
        case let .api(_, _, status):
            self = (status >= 500 || status == 408 || status == 429) ? .unreachable : .declined
        case .unauthenticated, .biometricFailed, .detailsMismatch:
            self = .declined
        }
    }
}
