import Foundation

/// The Auth module's implementation of ``AccessTokenProviding``.
///
/// Wraps ``AuthTokenStore`` with the same refresh-if-expiring rule
/// ``AuthService`` applies to its own authenticated calls, so a feed request
/// made minutes after the last auth call still goes out with a live token.
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
