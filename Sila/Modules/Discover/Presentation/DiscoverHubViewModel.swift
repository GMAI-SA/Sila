import Foundation
import Observation

/// One section of the Explore hub, loading and failing on its own.
public enum HubSection<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    /// A failed section hides itself: one broken surface must not take the
    /// whole hub down with it, and an error box for "people to follow" is
    /// noise nobody asked for.
    case failed

    public var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    public var isLoading: Bool { self == .loading }
}

/// Drives the Explore hub's idle screen and the Live now rail on Home.
///
/// Owned by ``MainTabView`` so both tabs share one copy of what is live, and
/// so the hub keeps its sections while somebody wanders off and comes back.
/// Every section loads on its own; nothing waits for anything else.
@MainActor
@Observable
public final class DiscoverHubViewModel {

    public private(set) var live: HubSection<[VoiceRoom]> = .idle
    public private(set) var subjects: HubSection<[TopicOption]> = .idle
    public private(set) var trending: HubSection<[TrendingSection]> = .idle
    public private(set) var needsReply: HubSection<[Post]> = .idle
    public private(set) var people: HubSection<[SuggestedPerson]> = .idle
    /// The question of the week, while one is live.
    public private(set) var prompt: WeeklyPrompt?
    /// People followed from the hub, so a row can say so without a refetch.
    public private(set) var followed: Set<UUID> = []
    /// People with a follow in flight.
    public private(set) var following: Set<UUID> = []
    public var toast: SLToastMessage?

    private let discover: DiscoverServiceProtocol
    private let rooms: RoomsServiceProtocol
    private let preferences: PreferencesServiceProtocol
    private let profile: ProfileServiceProtocol?
    private let analytics: AnalyticsClient

    /// How many rows of Needs a reply the hub previews before "See all".
    public static let needsReplyPreview = 3

    public init(
        discover: DiscoverServiceProtocol,
        rooms: RoomsServiceProtocol,
        preferences: PreferencesServiceProtocol,
        profile: ProfileServiceProtocol?,
        analytics: AnalyticsClient
    ) {
        self.discover = discover
        self.rooms = rooms
        self.preferences = preferences
        self.profile = profile
        self.analytics = analytics
    }

    /// Live rooms, for the rail. Rooms that are not live are dropped even if
    /// the server lists them, so the rail never says "live" about a schedule.
    public var liveRooms: [VoiceRoom] {
        (live.value ?? []).filter { $0.status == .live }
    }

    // MARK: - Loading

    /// Loads every section once. Safe on every appearance.
    public func loadIfNeeded() async {
        await withTaskGroup(of: Void.self) { group in
            if live == .idle { group.addTask { await self.loadLive() } }
            if subjects == .idle { group.addTask { await self.loadSubjects() } }
            if trending == .idle { group.addTask { await self.loadTrending() } }
            if needsReply == .idle { group.addTask { await self.loadNeedsReply() } }
            if people == .idle { group.addTask { await self.loadPeople() } }
        }
    }

    /// Everything again — pull to refresh.
    public func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadLive() }
            group.addTask { await self.loadSubjects() }
            group.addTask { await self.loadTrending() }
            group.addTask { await self.loadNeedsReply() }
            group.addTask { await self.loadPeople() }
        }
    }

    /// The question of the week, for the top of For You. Silent on failure.
    public func loadPrompt() async {
        do {
            let current = try await discover.fetchCurrentPrompt()
            prompt = current?.live == true ? current : nil
        } catch {
            // Keep whatever was showing; the card is an offer, not a feature.
        }
    }

    /// Only the rail — Home asks for this and nothing else.
    public func loadLive() async {
        if live.value == nil { live = .loading }
        do {
            live = .loaded(try await rooms.fetchRooms(status: .live, topic: nil, limit: 10))
        } catch {
            if !APIError.wrapping(error).isCancellation { live = live.value.map { .loaded($0) } ?? .failed }
            else if live == .loading { live = .idle }
        }
    }

    func loadSubjects() async {
        subjects = .loading
        do {
            subjects = .loaded(try await preferences.fetchTopics().filter(\.isValid))
        } catch {
            subjects = APIError.wrapping(error).isCancellation ? .idle : .failed
        }
    }

    func loadTrending() async {
        trending = .loading
        do {
            // No topics: the server answers for this account's saved subjects.
            trending = .loaded(try await discover.fetchTrending(topics: []))
        } catch {
            trending = APIError.wrapping(error).isCancellation ? .idle : .failed
        }
    }

    func loadNeedsReply() async {
        needsReply = .loading
        do {
            needsReply = .loaded(try await discover.fetchNeedsReply(cursor: nil).posts)
        } catch {
            needsReply = APIError.wrapping(error).isCancellation ? .idle : .failed
        }
    }

    func loadPeople() async {
        people = .loading
        do {
            people = .loaded(try await discover.fetchPeople(topics: [], limit: 10))
        } catch {
            people = APIError.wrapping(error).isCancellation ? .idle : .failed
        }
    }

    // MARK: - Actions

    /// Follows somebody from the People section.
    public func follow(_ person: SuggestedPerson) async {
        guard let profile, !following.contains(person.id), !followed.contains(person.id) else { return }
        following.insert(person.id)
        defer { following.remove(person.id) }
        do {
            let result = try await profile.setFollowing(true, handle: person.user.handle)
            if result.following || result.requested { followed.insert(person.id) }
        } catch {
            toast = .error(for: error)
        }
    }

    /// Drops a post everywhere the hub holds it — it was deleted, or its
    /// author blocked.
    public func remove(postId: UUID) {
        if var posts = needsReply.value {
            posts.removeAll { $0.id == postId }
            needsReply = .loaded(posts)
        }
    }

    public func track(section: String) {
        analytics.track(.exploreSectionOpened, properties: ["source": section])
    }
}
