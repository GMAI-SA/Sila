import Foundation

/// Keeps token refresh single-flight.
///
/// The server revokes a refresh token the first time it is used. When the app
/// comes back after half an hour, the feed, the unread badges, push
/// re-registration and the telemetry flush all find the access token expiring
/// at once, and each would send the same refresh token. The second would be
/// refused `401`, and a refusal signs the person out, deleting the pair the
/// first call had just saved.
///
/// So only one refresh is ever in flight. Every caller that arrives while it
/// runs is handed the same task and gets the same pair. The task is not tied
/// to any one caller: a screen that goes away does not cancel the refresh the
/// others are waiting on.
actor TokenRefresher {

    private var inFlight: Task<TokenPair, Error>?

    /// Runs `refresh`, or joins the one already running.
    func run(_ refresh: @escaping @Sendable () async throws -> TokenPair) async throws -> TokenPair {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await refresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
