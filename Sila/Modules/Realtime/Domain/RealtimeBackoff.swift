import Foundation

/// What the client does after a socket closes (contract v30 §1.7), decided
/// from the `error` frame the server sends before every close and, when no
/// frame came, from the close code.
public enum RealtimeCloseDecision: Equatable, Sendable {
    /// Try again after ``RealtimeBackoff/delay(_:attempt:jitter:)``.
    case retry(RealtimeRetry)
    /// `4401`: refresh the token over HTTP, then reconnect with the new one.
    case renewToken
    /// `4403` and the like: do not reconnect until the app starts the socket
    /// again — the HTTP API has a screen for this, not the socket.
    case stop(RealtimeStopReason)

    /// - Parameters:
    ///   - errorCode: The `code` of the last `error` frame before the close.
    ///   - closeCode: The WebSocket close code, `1006` when none arrived.
    ///   - handshakeStatus: The HTTP status of a handshake that was refused.
    public static func decide(errorCode: String?, closeCode: Int, handshakeStatus: Int? = nil) -> RealtimeCloseDecision {
        switch errorCode {
        case "account_suspended": return .stop(.suspended)
        case "account_deactivated": return .stop(.deactivated)
        case "token_expired", "unauthorized", "different_account": return .renewToken
        case "realtime_unavailable", "busy", "too_slow": return .retry(.unavailable)
        case "too_many_connections", "rate_limited": return .retry(.later(60))
        default: break
        }
        if let handshakeStatus, handshakeStatus != 101 {
            // Refused before it opened — a server with no socket (an older
            // deploy answers 404) or an origin it does not admit. Nothing a
            // quick retry changes; the app keeps refreshing over HTTP.
            return .retry(.unavailable)
        }
        switch closeCode {
        case 4403: return .stop(.refused)
        case 4401: return .renewToken
        case 1013: return .retry(.unavailable)
        case 4429: return .retry(.later(60))
        default: return .retry(.backoff)
        }
    }
}

/// How soon to try again.
public enum RealtimeRetry: Equatable, Sendable {
    /// 1 s, 2 s, 5 s, 10 s, 30 s, then every 60 s.
    case backoff
    /// `1013`: real time cannot be offered now. 30 s, then longer, up to 5 min.
    case unavailable
    /// A fixed wait — a minute after `4429`.
    case later(TimeInterval)
}

/// Why the socket will not reconnect by itself.
public enum RealtimeStopReason: String, Equatable, Sendable {
    /// `account_suspended`: the suspension screen, as over HTTP.
    case suspended
    /// `account_deactivated`: the account is pending deletion.
    case deactivated
    /// The token could not be renewed: the session is over.
    case signedOut
    /// Any other `4403`.
    case refused
}

/// The waits of contract v30 §1.7, with up to 30 % random jitter so a
/// server restart is not answered by every phone in the same second.
public enum RealtimeBackoff {

    static let steps: [TimeInterval] = [1, 2, 5, 10, 30]
    static let ceiling: TimeInterval = 60
    static let unavailableSteps: [TimeInterval] = [30, 60, 120, 240]
    static let unavailableCeiling: TimeInterval = 300
    /// A socket that stayed up this long starts the backoff again from 1 s.
    public static let resetAfter: TimeInterval = 60

    /// - Parameters:
    ///   - retry: Which schedule.
    ///   - attempt: Failures since the last socket that stayed up a minute, from 0.
    ///   - jitter: `0...1`, scaled to at most 30 % more.
    public static func delay(_ retry: RealtimeRetry, attempt: Int, jitter: Double) -> TimeInterval {
        let spread = 1 + 0.3 * min(max(jitter, 0), 1)
        switch retry {
        case .backoff:
            let base = attempt < steps.count ? steps[max(attempt, 0)] : ceiling
            return base * spread
        case .unavailable:
            let base = attempt < unavailableSteps.count ? unavailableSteps[max(attempt, 0)] : unavailableCeiling
            return min(base * spread, unavailableCeiling)
        case let .later(seconds):
            return seconds * spread
        }
    }
}
