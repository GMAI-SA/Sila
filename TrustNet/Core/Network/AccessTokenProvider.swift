import Foundation

/// Supplies a currently-valid bearer token to services outside the Auth module.
///
/// Every phase after the first needs `Authorization: Bearer …`, but no module
/// may reach into `Modules/Auth/` for it — this protocol is the seam. The Auth
/// module ships the real implementation (`SessionAccessTokenProvider`); tests
/// and previews use ``StaticAccessTokenProvider``.
public protocol AccessTokenProviding: Sendable {

    /// A token good for at least another minute, refreshing the pair first if
    /// the stored one is about to expire.
    /// - Throws: ``APIError/unauthenticated`` when there is no session at all.
    func accessToken() async throws -> String
}

/// Fixed-token ``AccessTokenProviding`` for tests and previews.
///
/// Initialise with `nil` to simulate a signed-out caller.
public struct StaticAccessTokenProvider: AccessTokenProviding {

    private let token: String?

    /// - Parameter token: The value to hand out, or `nil` to always fail.
    public init(token: String? = "test-access-token") {
        self.token = token
    }

    public func accessToken() async throws -> String {
        guard let token else { throw APIError.unauthenticated }
        return token
    }
}
