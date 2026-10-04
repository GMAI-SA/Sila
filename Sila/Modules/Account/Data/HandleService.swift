import Foundation

/// The production ``HandleServiceProtocol`` (contract v33).
///
/// Holds no session state: the bearer token is fetched per call. Never sends
/// a name to build suggestions from — the server uses the display name on
/// file, and a name in a URL can end up in somebody's access log.
public final class HandleService: HandleServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    public func check(_ handle: String) async throws -> HandleCheck {
        let token = try await tokens.accessToken()
        let request = APIRequest(
            path: "/handles/check",
            accessToken: token,
            query: [URLQueryItem(name: "handle", value: Handle.normalised(handle))]
        )
        return try await network.send(request, as: HandleCheck.self)
    }

    public func choose(_ handle: String) async throws -> AuthUser {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/handle",
            method: .post,
            body: ChooseHandleBody(handle: Handle.normalised(handle)),
            accessToken: token
        )
        return try await network.send(request, as: AuthUser.self)
    }
}

/// `POST /me/handle`.
struct ChooseHandleBody: Encodable, Equatable {
    let handle: String
}
