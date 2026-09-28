import Foundation

/// The Auth module's implementation of ``AccessTokenProviding``.
///
/// Wraps ``AuthTokenStore`` with the same refresh-if-expiring rule
/// ``AuthService`` applies to its own authenticated calls, so a feed request
/// made minutes after the last auth call still goes out with a live token.
///
/// Around 150 call sites ask for a token, and many of them at once. The
/// refresh itself is single-flight inside ``AuthService/refreshToken(_:)``,
/// so however many of them find the token expiring, one refresh goes out and
/// they all get its pair.
///
/// This type is deliberately the *only* thing later phases receive from
/// `Modules/Auth/Data/` — they get a token, never the store.
public struct SessionAccessTokenProvider: AccessTokenProviding {

    private let store: AuthTokenStore
    private let service: AuthServiceProtocol

    /// - Parameters:
    ///   - store: Where the session secrets live.
    ///   - service: Used to rotate an expiring pair.
    public init(store: AuthTokenStore, service: AuthServiceProtocol) {
        self.store = store
        self.service = service
    }

    public func accessToken() async throws -> String {
        guard let token = await store.token() else { throw APIError.unauthenticated }
        guard token.expiresSoon() else { return token.accessToken }
        let refreshed = try await service.refreshToken(token)
        return refreshed.token.accessToken
    }
}

// MARK: - The real-time socket

extension SessionAccessTokenProvider: RealtimeTokenProviding {

    /// A token other than `stale`, for the socket's re-authentication
    /// (contract v30 §1.5).
    ///
    /// The server asks a minute before the socket's token expires, which is
    /// right at the edge of ``accessToken()``'s own one-minute margin — so this
    /// does not ask whether the token expires soon, only whether it is still
    /// the one the socket holds. If another caller has rotated it meanwhile,
    /// that pair is the session and is used as it is; otherwise it is
    /// refreshed, through the same single-flight refresh every HTTP call uses.
    public func renewedAccessToken(replacing stale: String) async throws -> String {
        guard let token = await store.token() else { throw APIError.unauthenticated }
        if token.accessToken != stale, !token.expiresSoon(leeway: 90) {
            return token.accessToken
        }
        return try await service.refreshToken(token).token.accessToken
    }
}
