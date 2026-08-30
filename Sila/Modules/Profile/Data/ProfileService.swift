import Foundation

/// The production ``ProfileServiceProtocol``.
///
/// Talks to the contract's `/users/{handle}` family through the injected
/// ``NetworkClient``. Like every other service it holds no session state: the
/// bearer token is fetched per call from ``AccessTokenProviding``.
public final class ProfileService: ProfileServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - network: HTTP transport.
    ///   - tokens: Supplies the bearer token.
    ///   - analytics: Event sink.
    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    // MARK: - Reading

    public func fetchProfile(handle: String) async throws -> Profile {
        let token = try await tokens.accessToken()
        let profile = try await network.send(
            APIRequest(path: "/users/\(try component(handle))", accessToken: token),
            as: Profile.self
        )
        analytics.track(.profileLoaded, properties: [
            "is_me": String(profile.isMe),
            "is_following": String(profile.isFollowing)
        ])
        return profile
    }

    public func fetchPosts(handle: String, cursor: String?, limit: Int) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        // The server validates `limit` with `ge=1, le=50` and answers **422**
        // outside that range instead of clamping, so the clamp happens here —
        // an unreadable FastAPI validation body is not an error worth showing.
        var query = [URLQueryItem(name: "limit", value: String(clamped(limit)))]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await network.send(
            APIRequest(path: "/users/\(try component(handle))/posts", accessToken: token, query: query),
            as: FeedPage.self
        )
    }

    // MARK: - Following

    public func setFollowing(_ following: Bool, handle: String) async throws -> FollowResult {
        let token = try await tokens.accessToken()
        let result = try await network.send(
            APIRequest(
                path: "/users/\(try component(handle))/follow",
                method: following ? .post : .delete,
                accessToken: token
            ),
            as: FollowResult.self
        )
        analytics.track(following ? .followAdded : .followRemoved)
        return result
    }

    // MARK: - Plumbing

    /// The handle as a safe path component.
    ///
    /// A handle that survives sanitisation as nothing at all is reported as the
    /// 404 it would be anyway, without spending a request to find that out —
    /// and, more importantly, without building `/users//posts`, which is a
    /// different endpoint entirely.
    private func component(_ handle: String) throws -> String {
        let component = Handle.pathComponent(handle)
        guard !component.isEmpty else {
            throw APIError.api(
                code: .userNotFound,
                message: "No account with that handle",
                status: 404
            )
        }
        return component
    }

    private func clamped(_ limit: Int) -> Int {
        min(max(limit, 1), FeedConstants.maximumPageSize)
    }
}
