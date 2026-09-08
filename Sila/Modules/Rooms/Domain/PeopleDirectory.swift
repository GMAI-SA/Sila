import Foundation

/// Where a picker gets its people: the ones the viewer already knows — their
/// followers and the people they follow — and, for anybody else, a search.
///
/// Typing a handle into a field is how invitations used to work, and it is
/// a poor way to find the person you mean. A picker over people you know is
/// the ordinary case; search remains for everybody else.
public protocol PeopleDirectory: Sendable {
    /// The viewer's followers and the people they follow, merged, no
    /// duplicates, sorted by name. Never includes the viewer.
    func knownPeople(of viewerHandle: String) async throws -> [UserSummary]
    /// Anybody, by name or handle.
    func search(_ query: String) async throws -> [UserSummary]
}

/// The production directory, over the profile and search services.
public struct KnownPeopleDirectory: PeopleDirectory {

    private let profile: ProfileServiceProtocol
    private let search: SearchServiceProtocol
    /// How many pages of each list to read. Three pages of a hundred is more
    /// people than anybody scrolls; beyond that, search.
    private let maxPages: Int

    public init(profile: ProfileServiceProtocol, search: SearchServiceProtocol, maxPages: Int = 3) {
        self.profile = profile
        self.search = search
        self.maxPages = maxPages
    }

    public func knownPeople(of viewerHandle: String) async throws -> [UserSummary] {
        let me = Handle.normalised(viewerHandle)
        guard !me.isEmpty else { return [] }
        async let followers = pages { cursor in try await profile.fetchFollowers(handle: me, cursor: cursor) }
        async let following = pages { cursor in try await profile.fetchFollowing(handle: me, cursor: cursor) }
        let all = try await following + followers
        var seen = Set<String>()
        var people: [UserSummary] = []
        for person in all {
            let key = Handle.normalised(person.handle)
            guard !key.isEmpty, key != me, !seen.contains(key) else { continue }
            seen.insert(key)
            people.append(person)
        }
        return people.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public func search(_ query: String) async throws -> [UserSummary] {
        try await search.searchUsers(query: query)
    }

    private func pages(_ fetch: (String?) async throws -> FollowListPage) async throws -> [UserSummary] {
        var rows: [UserSummary] = []
        var cursor: String? = nil
        for _ in 0..<maxPages {
            let page = try await fetch(cursor)
            rows += page.items.map(\.user)
            guard let next = page.nextCursor, !next.isEmpty, !page.items.isEmpty else { break }
            cursor = next
        }
        return rows
    }
}
