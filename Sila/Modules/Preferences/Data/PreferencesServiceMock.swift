import Foundation

/// Scripted ``PreferencesServiceProtocol`` used by tests, previews and the
/// `-mockPreferences` launch argument.
///
/// Serves the real 20-topic taxonomy, because the whole point of the screen is
/// how a list of twenty behaves — a demo with four topics would hide the only
/// layout problem worth solving. Saves round-trip through stored state, so the
/// mock cannot show a "saved" banner for something it did not store.
public actor PreferencesServiceMock: PreferencesServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// A filled-in account: the filter on with two interests, one muted
        /// topic and one muted country.
        case populated
        /// A brand-new account — the server's defaults, nothing chosen.
        case empty
        /// Every call fails with a transport error.
        case offline
        /// Loads fine; every save is rejected by the server.
        case saveFails
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// Artificial latency, in seconds. Tests pass `0`.
    private let latency: Double

    /// The stored preferences, mutated by a successful save.
    private var stored: FeedPreferences

    /// Bodies received by ``updatePreferences(_:)``, in order — the assertion
    /// surface for the full-replacement semantics.
    public private(set) var receivedUpdates: [PreferencesUpdate] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay.
    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
        self.stored = scenario == .empty ? FeedPreferences() : Self.filledIn
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - PreferencesServiceProtocol

    public func fetchTopics() async throws -> [TopicOption] {
        try await delay()
        try failIfOffline()
        return Self.taxonomy
    }

    public func fetchPreferences() async throws -> FeedPreferences {
        try await delay()
        try failIfOffline()
        return stored
    }

    public func updatePreferences(_ update: PreferencesUpdate) async throws -> FeedPreferences {
        receivedUpdates.append(update)
        try await delay()
        try failIfOffline()

        if scenario == .saveFails {
            throw APIError.api(
                code: .unknownTopic,
                message: "Not topics in this taxonomy: quantum_basketry",
                status: 400
            )
        }

        var next = stored
        if let topics = update.topics {
            let known = Set(Self.taxonomy.map(\.id))
            let unknown = topics.map(\.topic).filter { !known.contains($0) }
            guard unknown.isEmpty else {
                throw APIError.api(
                    code: .unknownTopic,
                    message: "Not topics in this taxonomy: \(unknown.sorted().joined(separator: ", "))",
                    status: 400
                )
            }
            // Full replacement, exactly like the server: what is not in the
            // array has no stance afterwards.
            next.interests = topics.filter { $0.stance == "interested" }.map(\.topic).sorted()
            next.mutedTopics = topics.filter { $0.stance == "muted" }.map(\.topic).sorted()
        }
        if let enabled = update.filterInternationalByInterests {
            next.filterInternationalByInterests = enabled
        }
        if let untagged = update.showUntaggedPosts {
            next.showUntaggedPosts = untagged
        }
        if let countries = update.mutedCountries {
            let bad = countries.filter { $0.trimmingCharacters(in: .whitespaces).count != 2 }
            guard bad.isEmpty else {
                throw APIError.api(
                    code: .invalidCountry,
                    message: "Expected ISO-3166 alpha-2 codes: \(bad.joined(separator: ", "))",
                    status: 400
                )
            }
            next.mutedCountries = MutedCountries.normalised(countries)
        }
        if let notifications = update.notifications {
            // Full replacement, exactly like the server: the object that comes
            // back is the object that was sent.
            next.notifications = NotificationPreferences(enabled: notifications)
        }
        stored = next
        return stored
    }

    // MARK: - Fixture world

    /// The server's taxonomy, verbatim. Ids are the wire contract, so these are
    /// copied rather than invented.
    public static let taxonomy: [TopicOption] = [
        TopicOption(id: "technology", detail: "Software, hardware, AI, startups, engineering"),
        TopicOption(id: "business", detail: "Companies, management, entrepreneurship, commerce"),
        TopicOption(id: "finance", detail: "Markets, investing, banking, personal finance, crypto"),
        TopicOption(id: "politics", detail: "Government, policy, elections, public affairs"),
        TopicOption(id: "news", detail: "Current events and breaking news not covered by another topic"),
        TopicOption(id: "sports", detail: "Athletes, matches, leagues, fitness competition"),
        TopicOption(id: "health", detail: "Medicine, wellbeing, fitness, mental health"),
        TopicOption(id: "science", detail: "Research, space, physics, biology, discovery"),
        TopicOption(id: "education", detail: "Schools, universities, teaching, studying, courses"),
        TopicOption(id: "religion", detail: "Faith, worship, religious practice and scholarship"),
        TopicOption(id: "culture", detail: "Society, heritage, language, traditions, social commentary"),
        TopicOption(id: "entertainment", detail: "Film, television, music, celebrities, streaming"),
        TopicOption(id: "gaming", detail: "Video games, esports, game development"),
        TopicOption(id: "art", detail: "Visual art, design, photography, literature, architecture"),
        TopicOption(id: "food", detail: "Cooking, restaurants, recipes, coffee, dining"),
        TopicOption(id: "travel", detail: "Destinations, tourism, flights, hotels, exploring"),
        TopicOption(id: "environment", detail: "Climate, sustainability, nature, conservation"),
        TopicOption(id: "motoring", detail: "Cars, motorsport, driving, vehicles"),
        TopicOption(id: "real_estate", detail: "Property, housing, construction, land"),
        TopicOption(id: "jobs", detail: "Hiring, careers, workplace, recruitment")
    ]

    /// The ``MockScenario/populated`` starting point.
    static let filledIn = FeedPreferences(
        interests: ["science", "technology"],
        mutedTopics: ["politics"],
        filterInternationalByInterests: true,
        showUntaggedPosts: true,
        mutedCountries: ["JP"],
        // Likes already silenced — the switch people reach for first, so the
        // mocked world shows what the screen looks like once somebody has.
        notifications: NotificationPreferences([.like: false])
    )

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }
}
