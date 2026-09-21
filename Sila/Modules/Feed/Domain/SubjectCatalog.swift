import Foundation

/// Anything that can name the subjects a timeline can be narrowed to.
///
/// Both halves of the app can: a signed-in account reads the taxonomy from
/// `GET /topics`, a guest from `GET /public/topics`. The labels come from the
/// server in the language the app is running in, so the strip never carries a
/// second, drifting copy of the vocabulary.
public protocol TopicCatalogProviding: Sendable {
    /// The server's fixed taxonomy.
    func fetchTopics() async throws -> [TopicOption]
}

extension PublicFeedService: TopicCatalogProviding {}

/// What the subject strip needs to know before it can draw itself.
public struct SubjectCatalog: Equatable, Sendable {

    /// The whole taxonomy, as the server sent it.
    public var topics: [TopicOption]
    /// Subjects this account said it is interested in. They lead the strip.
    public var interests: Set<String>
    /// Subjects this account hid. They never appear in the strip at all.
    public var muted: Set<String>

    public init(topics: [TopicOption] = [], interests: Set<String> = [], muted: Set<String> = []) {
        self.topics = topics
        self.interests = interests
        self.muted = muted
    }

    /// The row, in the order it is drawn.
    public var strip: [TopicOption] {
        SubjectOrder.strip(topics: topics, interests: interests, muted: muted)
    }
}

/// What the strip offers, and in what order.
///
/// A free function rather than something inside the view, so the two rules
/// that matter — chosen interests first, hidden subjects absent — can be
/// tested without drawing anything.
public enum SubjectOrder {

    /// - Parameters:
    ///   - topics: The server's taxonomy. Rows with no id are dropped.
    ///   - interests: Subject ids this account chose.
    ///   - muted: Subject ids this account hid. Never offered: the strip is
    ///     for choosing what to see, and putting a hidden subject in it would
    ///     invite somebody to undo their own decision by accident.
    public static func strip(
        topics: [TopicOption],
        interests: Set<String>,
        muted: Set<String>
    ) -> [TopicOption] {
        topics
            .filter { $0.isValid && !muted.contains($0.id) }
            .sorted { first, second in
                let firstChosen = interests.contains(first.id)
                let secondChosen = interests.contains(second.id)
                if firstChosen != secondChosen { return firstChosen }
                // Alphabetical inside each group, in whatever language the
                // server's labels came back in.
                return first.label.localizedCaseInsensitiveCompare(second.label) == .orderedAscending
            }
    }
}

/// Loads a ``SubjectCatalog``.
public protocol SubjectCatalogProviding: Sendable {
    func loadSubjects() async throws -> SubjectCatalog
}

/// The catalogue for somebody who is signed in: the taxonomy, plus what this
/// account has already said about it.
public struct AccountSubjects: SubjectCatalogProviding {

    private let service: PreferencesServiceProtocol

    public init(_ service: PreferencesServiceProtocol) {
        self.service = service
    }

    public func loadSubjects() async throws -> SubjectCatalog {
        // Two independent reads; there is no reason for the second to wait.
        async let topicsCall = service.fetchTopics()
        async let preferencesCall = service.fetchPreferences()
        let preferences = try await preferencesCall
        return SubjectCatalog(
            topics: try await topicsCall,
            interests: Set(preferences.interests),
            muted: Set(preferences.mutedTopics)
        )
    }
}

/// The catalogue for somebody who has not joined: the taxonomy and nothing
/// else, because there is no account yet to hold an opinion about it.
public struct GuestSubjects: SubjectCatalogProviding {

    private let service: TopicCatalogProviding

    public init(_ service: TopicCatalogProviding) {
        self.service = service
    }

    public func loadSubjects() async throws -> SubjectCatalog {
        SubjectCatalog(topics: try await service.fetchTopics())
    }
}
