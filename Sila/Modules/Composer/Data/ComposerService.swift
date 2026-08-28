import Foundation

/// The production ``ComposerServiceProtocol``.
///
/// Talks to `POST /posts` (contract v2, clarified by v3) through the injected
/// ``NetworkClient``. Like ``FeedService`` it holds no session state: the bearer
/// token is fetched per call from ``AccessTokenProviding``.
public final class ComposerService: ComposerServiceProtocol {

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

    public func createPost(_ draft: PostDraft) async throws -> Post {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/posts",
            method: .post,
            body: CreatePostBody(draft: draft),
            accessToken: token
        )
        let post = try await network.send(request, as: Post.self)

        analytics.track(.postCreated, properties: [
            "scope": draft.scope.wireValue,
            "kind": kind(of: draft),
            "length": String(draft.trimmedText.count)
        ])
        return post
    }

    /// What the post is, for analytics only — a reply, a quote or a root.
    private func kind(of draft: PostDraft) -> String {
        if draft.replyToPostId != nil { return "reply" }
        if draft.quotedPostId != nil { return "quote" }
        return "post"
    }
}
