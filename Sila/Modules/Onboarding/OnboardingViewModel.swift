import Foundation
import Observation

/// The first-run flow (contract v19): which subjects, then which people, then
/// one card — the room that is live now, when there is one — so the first
/// thing a new account sees is never a blank feed.
///
/// Subjects **rank** the feed; they never narrow it. The step says "choose
/// three or more" as guidance, not as a gate, and Skip is always there.
@MainActor
@Observable
public final class OnboardingViewModel {

    public enum Step: Equatable, Sendable {
        case subjects
        case people
        case finale
    }

    /// Guidance, not a rule: the Continue button works with any number.
    public static let suggestedMinimum = 3

    public private(set) var step: Step = .subjects
    public private(set) var topics: [TopicOption] = []
    public private(set) var selected: Set<String> = []
    public private(set) var people: [SuggestedPerson] = []
    public private(set) var followed: Set<UUID> = []
    public private(set) var following: Set<UUID> = []
    /// The one card at the end, when something is live.
    public private(set) var liveRoom: VoiceRoom?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var loadError: String?
    public var toast: SLToastMessage?

    private let discover: DiscoverServiceProtocol
    private let preferences: PreferencesServiceProtocol
    private let profile: ProfileServiceProtocol?
    private let rooms: RoomsServiceProtocol?
    private let analytics: AnalyticsClient
    private let onFinish: @MainActor () -> Void

    public init(
        discover: DiscoverServiceProtocol,
        preferences: PreferencesServiceProtocol,
        profile: ProfileServiceProtocol?,
        rooms: RoomsServiceProtocol?,
        analytics: AnalyticsClient,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.discover = discover
        self.preferences = preferences
        self.profile = profile
        self.rooms = rooms
        self.analytics = analytics
        self.onFinish = onFinish
    }

    // MARK: - Step 1: subjects

    /// "Pick three or more" until three are picked, then a count.
    public var subjectsHint: String {
        selected.count >= Self.suggestedMinimum
            ? L10n.plural("onboarding.interests.chosen", selected.count)
            : L10n.t("onboarding.interests.hint")
    }

    public func load() async {
        guard topics.isEmpty, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            topics = try await preferences.fetchTopics().filter(\.isValid)
        } catch {
            let wrapped = APIError.wrapping(error)
            if !wrapped.isCancellation { loadError = wrapped.userMessage }
        }
    }

    public func isSelected(_ topicId: String) -> Bool { selected.contains(topicId) }

    public func toggle(_ topicId: String) {
        if selected.contains(topicId) { selected.remove(topicId) } else { selected.insert(topicId) }
    }

    /// Saves the chosen subjects and moves on to people.
    public func continueFromSubjects() async {
        await submit(skipped: false)
    }

    /// Skips subjects. Still stamped on the server, so it is never asked again.
    public func skipSubjects() async {
        selected = []
        await submit(skipped: true)
    }

    private func submit(skipped: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await discover.submitOnboardingInterests(topics: selected.sorted(), skipped: skipped || selected.isEmpty)
        } catch {
            let wrapped = APIError.wrapping(error)
            guard !wrapped.isCancellation else { return }
            // Not a dead end: the choice is kept, the step moves on, and a
            // later save from the subject strip records it just the same.
            toast = .error(wrapped.userMessage)
        }
        step = .people
        await loadPeople()
    }

    // MARK: - Step 2: people

    func loadPeople() async {
        people = (try? await discover.fetchPeople(topics: selected.sorted(), limit: 20)) ?? []
        if people.isEmpty { await finish() }
    }

    public func isFollowed(_ person: SuggestedPerson) -> Bool { followed.contains(person.id) }
    public func isFollowing(_ person: SuggestedPerson) -> Bool { following.contains(person.id) }

    public func follow(_ person: SuggestedPerson) async {
        guard let profile, !followed.contains(person.id), !following.contains(person.id) else { return }
        following.insert(person.id)
        defer { following.remove(person.id) }
        do {
            let result = try await profile.setFollowing(true, handle: person.user.handle)
            if result.following || result.requested {
                followed.insert(person.id)
                analytics.track(.onboardingPersonFollowed, properties: ["reason": person.reason.rawValue])
            }
        } catch {
            toast = .error(for: error)
        }
    }

    /// Follows everybody on the list who is not followed yet.
    public func followAll() async {
        for person in people where !followed.contains(person.id) {
            await follow(person)
        }
    }

    // MARK: - The end

    /// Ends the people step: one card if something is live, else the feed.
    public func finish() async {
        if let rooms, let live = try? await rooms.fetchRooms(status: .live, topic: nil, limit: 5),
           let first = live.first(where: { $0.status == .live }) {
            liveRoom = first
            step = .finale
        } else {
            complete(result: "feed")
        }
    }

    /// Leaves the flow.
    public func complete(result: String) {
        analytics.track(.onboardingCompleted, properties: ["result": result])
        onFinish()
    }
}
