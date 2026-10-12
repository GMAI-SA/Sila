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
        if let sort = update.hashtagSort {
            next.hashtagSort = HashtagSort(wire: sort)
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
    /// copied rather than invented. The Arabic names and descriptions are the
    /// server's own (`label_ar`, `description_ar`), shown in the Arabic
    /// screenshot run (``MockCopy``).
    public static let taxonomy: [TopicOption] = [
        topic("technology", "Software, hardware, AI, startups, engineering",
              "التقنية", "البرمجيات والعتاد والذكاء الاصطناعي والشركات الناشئة والهندسة"),
        topic("business", "Companies, management, entrepreneurship, commerce",
              "الأعمال", "الشركات والإدارة وريادة الأعمال والتجارة"),
        topic("finance", "Markets, investing, banking, personal finance, crypto",
              "المال", "الأسواق والاستثمار والمصارف والمال الشخصي والعملات الرقمية"),
        topic("politics", "Government, policy, elections, public affairs",
              "السياسة", "الحكومة والسياسات والانتخابات والشأن العام"),
        topic("news", "Current events and breaking news not covered by another topic",
              "الأخبار", "الأحداث الجارية والأخبار العاجلة التي لا يغطيها موضوع آخر"),
        topic("sports", "Athletes, matches, leagues, fitness competition",
              "الرياضة", "الرياضيون والمباريات والدوريات ومنافسات اللياقة"),
        topic("health", "Medicine, wellbeing, fitness, mental health",
              "الصحة", "الطب والعافية واللياقة والصحة النفسية"),
        topic("science", "Research, space, physics, biology, discovery",
              "العلوم", "البحث والفضاء والفيزياء والأحياء والاكتشاف"),
        topic("education", "Schools, universities, teaching, studying, courses",
              "التعليم", "المدارس والجامعات والتدريس والدراسة والدورات"),
        topic("religion", "Faith, worship, religious practice and scholarship",
              "الدين", "الإيمان والعبادة والممارسة الدينية والعلم الشرعي"),
        topic("culture", "Society, heritage, language, traditions, social commentary",
              "الثقافة", "المجتمع والتراث واللغة والتقاليد والتعليق الاجتماعي"),
        topic("entertainment", "Film, television, music, celebrities, streaming",
              "الترفيه", "الموسيقى والمشاهير والعروض الحية وصنّاع المحتوى"),
        topic("gaming", "Video games, esports, game development",
              "الألعاب", "ألعاب الفيديو والرياضات الإلكترونية وتطوير الألعاب"),
        topic("art", "Visual art, design, photography, literature, architecture",
              "الفن", "الفن البصري والتصميم والتصوير والأدب والعمارة"),
        topic("food", "Cooking, restaurants, recipes, coffee, dining",
              "الطعام", "الطبخ والمطاعم والوصفات والقهوة والمأكولات"),
        topic("travel", "Destinations, tourism, flights, hotels, exploring",
              "السفر", "الوجهات والسياحة والرحلات الجوية والفنادق والاستكشاف"),
        topic("environment", "Climate, sustainability, nature, conservation",
              "البيئة", "المناخ والاستدامة والطبيعة والحفاظ على البيئة"),
        topic("motoring", "Cars, motorsport, driving, vehicles",
              "السيارات", "السيارات ورياضة المحركات والقيادة والمركبات"),
        topic("real_estate", "Property, housing, construction, land",
              "العقار", "العقارات والإسكان والبناء والأراضي"),
        topic("jobs", "Hiring, careers, workplace, recruitment",
              "الوظائف", "التوظيف والمسار المهني وبيئة العمل والاستقطاب")
    ]

    private static func topic(_ id: String, _ detail: String, _ labelAr: String, _ detailAr: String) -> TopicOption {
        MockCopy.isArabic
            ? TopicOption(id: id, detail: detailAr, label: labelAr)
            : TopicOption(id: id, detail: detail)
    }

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
