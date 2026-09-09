import Foundation

/// ``CommunitiesServiceProtocol`` over the API.
public final class CommunitiesService: CommunitiesServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    // MARK: - Reading

    public func fetchCommunities(mine: Bool, forYou: Bool, topic: String?, limit: Int) async throws -> [Community] {
        let token = try await tokens.accessToken()
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if mine { query.append(URLQueryItem(name: "mine", value: "true")) }
        if forYou { query.append(URLQueryItem(name: "for_you", value: "true")) }
        if let topic, !topic.isEmpty { query.append(URLQueryItem(name: "topic", value: topic)) }
        return try await network.send(
            APIRequest(path: "/communities", accessToken: token, query: query),
            as: CommunityList.self
        ).communities
    }

    public func fetchCommunity(slug: String) async throws -> Community {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/communities/\(path(slug))", accessToken: token),
            as: Community.self
        )
    }

    public func fetchPosts(slug: String, cursor: String?) async throws -> FeedPage {
        let token = try await tokens.accessToken()
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await network.send(
            APIRequest(path: "/communities/\(path(slug))/posts", accessToken: token, query: query),
            as: FeedPage.self
        )
    }

    public func fetchRooms(slug: String) async throws -> [VoiceRoom] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/communities/\(path(slug))/rooms", accessToken: token),
            as: CommunityRoomList.self
        ).rooms
    }

    public func fetchMembers(slug: String, status: String) async throws -> [CommunityMember] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(
                path: "/communities/\(path(slug))/members",
                accessToken: token,
                query: [URLQueryItem(name: "status", value: status)]
            ),
            as: CommunityMemberList.self
        ).members
    }

    // MARK: - Running one

    public func createCommunity(_ request: CreateCommunityRequest) async throws -> Community {
        let token = try await tokens.accessToken()
        let community = try await network.send(
            try APIRequest.json("/communities", method: .post, body: request, accessToken: token),
            as: Community.self
        )
        analytics.track(.communityCreated, properties: [
            "visibility": community.visibility.rawValue,
            "join_policy": community.joinPolicy.rawValue
        ])
        return community
    }

    public func updateCommunity(slug: String, update: CommunityUpdate) async throws -> Community {
        let token = try await tokens.accessToken()
        return try await network.send(
            try APIRequest.json("/communities/\(path(slug))", method: .patch, body: update, accessToken: token),
            as: Community.self
        )
    }

    public func closeCommunity(slug: String) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: "/communities/\(path(slug))", method: .delete, accessToken: token))
        analytics.track(.communityClosed)
    }

    public func join(slug: String) async throws -> Community {
        let token = try await tokens.accessToken()
        let community = try await network.send(
            APIRequest(path: "/communities/\(path(slug))/join", method: .post, accessToken: token),
            as: Community.self
        )
        analytics.track(.communityJoined, properties: ["pending": String(community.isPending)])
        return community
    }

    public func leave(slug: String) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(path: "/communities/\(path(slug))/leave", method: .post, accessToken: token)
        )
        analytics.track(.communityLeft)
    }

    public func invite(slug: String, handles: [String]) async throws {
        let token = try await tokens.accessToken()
        _ = try await network.sendData(
            try APIRequest.json(
                "/communities/\(path(slug))/invites",
                method: .post,
                body: RoomInviteBody(handles: RoomInviteHandles.clean(handles)),
                accessToken: token
            )
        )
    }

    public func approve(slug: String, handle: String) async throws {
        let token = try await tokens.accessToken()
        _ = try await network.sendData(
            APIRequest(
                path: "/communities/\(path(slug))/members/\(Handle.pathComponent(handle))/approve",
                method: .post,
                accessToken: token
            )
        )
    }

    public func remove(slug: String, handle: String, ban: Bool) async throws {
        let token = try await tokens.accessToken()
        _ = try await network.sendData(
            APIRequest(
                path: "/communities/\(path(slug))/members/\(Handle.pathComponent(handle))",
                method: .delete,
                accessToken: token,
                query: [URLQueryItem(name: "ban", value: ban ? "true" : "false")]
            )
        )
    }

    public func setRole(slug: String, handle: String, role: CommunityRole) async throws {
        let token = try await tokens.accessToken()
        _ = try await network.sendData(
            try APIRequest.json(
                "/communities/\(path(slug))/members/\(Handle.pathComponent(handle))/role",
                method: .post,
                body: CommunityRoleBody(role: role.rawValue),
                accessToken: token
            )
        )
    }

    /// A slug is already `[a-z0-9_]`; escaped anyway, because a path built by
    /// interpolation is a path somebody will eventually put a slash in.
    private func path(_ slug: String) -> String {
        slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
    }
}
