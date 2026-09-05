import Foundation

/// The production ``MessagesServiceProtocol``.
public final class MessagesService: MessagesServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    // MARK: - Reading

    public func fetchConversations() async throws -> [Conversation] {
        try await conversations(requests: false)
    }

    public func fetchRequests() async throws -> [Conversation] {
        try await conversations(requests: true)
    }

    private func conversations(requests: Bool) async throws -> [Conversation] {
        let token = try await tokens.accessToken()
        // Only sent when it is doing something: `requests=false` is the
        // server's default, and a URL that states its defaults is a URL whose
        // logs cannot be read at a glance.
        let query = requests ? [URLQueryItem(name: "requests", value: "true")] : []
        return try await network.send(
            APIRequest(path: "/conversations", accessToken: token, query: query),
            as: [Conversation].self
        )
    }

    public func fetchCounts() async throws -> MessageCounts {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/conversations/unread-count", accessToken: token),
            as: MessageCounts.self
        )
    }

    public func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/messages",
                accessToken: token
            ),
            as: [DirectMessage].self
        )
    }

    // MARK: - Writing

    @discardableResult
    public func send(to handle: String, text: String) async throws -> UUID {
        let token = try await tokens.accessToken()
        let body = try JSONEncoder().encode(["text": text])
        let response = try await network.send(
            APIRequest(
                path: "/conversations/\(handle)/messages",
                method: .post,
                body: body,
                accessToken: token
            ),
            as: SendResponse.self
        )
        analytics.track(.messageSent, properties: [:])
        return response.conversationId
    }

    public func accept(conversationId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/accept",
                method: .post,
                accessToken: token
            )
        )
        analytics.track(.messageRequestAccepted, properties: [:])
    }

    public func markRead(conversationId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/read",
                method: .post,
                accessToken: token
            )
        )
    }

    public func deleteMessage(id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(
                path: "/messages/\(id.uuidString.lowercased())",
                method: .delete,
                accessToken: token
            )
        )
    }

    /// `POST /conversations/{handle}/messages` answers with the thread the
    /// message landed in — which the caller may not have known existed.
    private struct SendResponse: Decodable {
        let conversationId: UUID
    }
}
