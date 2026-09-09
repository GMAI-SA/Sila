import Foundation

/// Reading and running communities.
public protocol CommunitiesServiceProtocol: Sendable {
    /// Communities to browse. `forYou` puts the viewer's interests first;
    /// `mine` narrows to the ones they are in.
    func fetchCommunities(mine: Bool, forYou: Bool, topic: String?, limit: Int) async throws -> [Community]
    func fetchCommunity(slug: String) async throws -> Community
    func createCommunity(_ request: CreateCommunityRequest) async throws -> Community
    func updateCommunity(slug: String, update: CommunityUpdate) async throws -> Community
    func closeCommunity(slug: String) async throws

    func join(slug: String) async throws -> Community
    func leave(slug: String) async throws
    func invite(slug: String, handles: [String]) async throws
    func approve(slug: String, handle: String) async throws
    /// Removes somebody. `ban` keeps them out; declining a request does not.
    func remove(slug: String, handle: String, ban: Bool) async throws
    func setRole(slug: String, handle: String, role: CommunityRole) async throws

    func fetchPosts(slug: String, cursor: String?) async throws -> FeedPage
    func fetchRooms(slug: String) async throws -> [VoiceRoom]
    func fetchMembers(slug: String, status: String) async throws -> [CommunityMember]
}

extension CommunitiesServiceProtocol {
    public func fetchCommunities(
        mine: Bool = false,
        forYou: Bool = false,
        topic: String? = nil,
        limit: Int = 20
    ) async throws -> [Community] {
        try await fetchCommunities(mine: mine, forYou: forYou, topic: topic, limit: limit)
    }

    public func remove(slug: String, handle: String) async throws {
        try await remove(slug: slug, handle: handle, ban: true)
    }

    public func fetchMembers(slug: String) async throws -> [CommunityMember] {
        try await fetchMembers(slug: slug, status: "active")
    }
}
