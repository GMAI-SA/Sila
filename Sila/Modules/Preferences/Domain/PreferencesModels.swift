import Foundation

// MARK: - Taxonomy

/// One topic in the server's fixed taxonomy (contract v4, `GET /topics`).
///
/// ``id`` is the wire contract and is stable forever; the human-readable
/// ``label`` is derived on the client precisely because the contract says
/// labels are *not* stable and must never be relied on.
public struct TopicOption: Identifiable, Hashable, Sendable, Decodable {

    /// Stable server id, e.g. `"real_estate"`. Never rendered raw.
    public let id: String
    /// The server's one-line explanation of what the topic covers.
    public let detail: String
    /// Title-cased name derived from ``id`` — `"real_estate"` → `"Real estate"`.
    public let label: String

    /// - Parameters:
    ///   - id: Server topic id.
    ///   - detail: The server's description of the topic.
    public init(id: String, detail: String) {
        self.id = id
        self.detail = detail
        self.label = TopicOption.makeLabel(from: id)
    }

    /// Explicit keys are required because ``init(from:)`` is custom. The wire
    /// field is `description`, which is *not* touched by `.convertFromSnakeCase`.
    private enum CodingKeys: String, CodingKey {
        case id
        case detail = "description"
    }

    /// Tolerant decoder: one malformed row must not blank the whole taxonomy.
    /// Rows with no id decode to an empty id and are dropped by
    /// ``TopicsResponse``, because a topic nobody can name is not selectable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = ((try? container.decode(String.self, forKey: .id)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        id = rawId
        detail = (try? container.decode(String.self, forKey: .detail)) ?? ""
        label = TopicOption.makeLabel(from: rawId)
    }

    /// `true` when the row carries a usable id.
    public var isValid: Bool { !id.isEmpty }

    /// `"real_estate"` → `"Real estate"`.
    static func makeLabel(from id: String) -> String {
        let words = id.split(separator: "_").joined(separator: " ")
        guard let first = words.first else { return id }
        return String(first).uppercased() + words.dropFirst()
    }
}

/// What a person has said about one topic.
///
/// The server stores only two stances; ``none`` is the *absence* of a row, and
/// it is expressed on the wire by leaving the topic out of the `topics` array
/// entirely — never by sending a null stance.
public enum TopicStance: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Counted by the International filter's allow-list.
    case interested
    /// Always hidden from International, whether or not the filter is on.
    case muted
    /// No opinion recorded. Not sent to the server.
    case none

    public var id: String { rawValue }

    /// The value the server expects, or `nil` when the topic must be omitted.
    public var wireValue: String? {
        switch self {
        case .interested: return "interested"
        case .muted: return "muted"
        case .none: return nil
        }
    }

    /// Button label.
    public var title: String {
        switch self {
        case .interested: return "Interested"
        case .muted: return "Muted"
        case .none: return "No opinion"
        }
    }

    /// What choosing this stance actually does, in plain language.
    public var accessibilityHint: String {
        switch self {
        case .interested:
            return "Counts this topic towards your International feed when the topic filter is on"
        case .muted:
            return "Hides posts labelled with this topic from your International feed, even when the filter is off"
        case .none:
            return "Records no opinion about this topic"
        }
    }
}

// MARK: - Preferences

/// Everything `GET /me/preferences` returns — the whole input to the
/// International feed's filter, for this account.
///
/// The defaults here are the server's defaults, so a decode that finds nothing
/// describes the same behaviour the backend would apply.
public struct FeedPreferences: Equatable, Sendable, Decodable {

    /// Topic ids marked interested, sorted.
    public var interests: [String]
    /// Topic ids marked muted, sorted.
    public var mutedTopics: [String]
    /// Whether the International feed is narrowed to ``interests``.
    ///
    /// On its own this does nothing: with no interests selected the server
    /// deliberately keeps the feed open — see ``narrowsToInterests``.
    public var filterInternationalByInterests: Bool
    /// Whether posts the classifier has not reached yet still appear while the
    /// feed is narrowed. Irrelevant when it is not — see ``narrowsToInterests``.
    public var showUntaggedPosts: Bool
    /// ISO-3166 alpha-2 codes whose *verified* authors are hidden, sorted.
    public var mutedCountries: [String]
    /// Which kinds of notification reach the notifications list.
    ///
    /// Lives in the same document as the feed settings because the server keeps
    /// it there, but it is edited from ``NotificationSettingsSheet`` rather than
    /// the feed-preferences screen — the person who wants likes silenced is
    /// standing in the notifications list when they decide that.
    public var notifications: NotificationPreferences

    /// Creates a preference set. The defaults match the server's.
    public init(
        interests: [String] = [],
        mutedTopics: [String] = [],
        filterInternationalByInterests: Bool = false,
        showUntaggedPosts: Bool = true,
        mutedCountries: [String] = [],
        notifications: NotificationPreferences = NotificationPreferences()
    ) {
        self.notifications = notifications
        self.interests = interests.sorted()
        self.mutedTopics = mutedTopics.sorted()
        self.filterInternationalByInterests = filterInternationalByInterests
        self.showUntaggedPosts = showUntaggedPosts
        self.mutedCountries = mutedCountries.sorted()
    }

    /// Explicit keys are required because ``init(from:)`` is custom, and the
    /// raw values are the *camel-cased* forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case interests
        case mutedTopics
        case filterInternationalByInterests
        case showUntaggedPosts
        case mutedCountries
        case notifications
    }

    /// Tolerant decoder.
    ///
    /// A missing key falls back to the server's own default rather than
    /// failing, because a preferences screen that refuses to open is strictly
    /// worse than one that opens showing the backend's defaults. Unrecognised
    /// topic ids are kept here — dropping them is the *view model's* job, once
    /// it knows the taxonomy to compare against.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interests = ((try? container.decode([String].self, forKey: .interests)) ?? []).sorted()
        mutedTopics = ((try? container.decode([String].self, forKey: .mutedTopics)) ?? []).sorted()
        filterInternationalByInterests =
            (try? container.decode(Bool.self, forKey: .filterInternationalByInterests)) ?? false
        showUntaggedPosts =
            (try? container.decode(Bool.self, forKey: .showUntaggedPosts)) ?? true
        mutedCountries = MutedCountries.normalised(
            (try? container.decode([String].self, forKey: .mutedCountries)) ?? []
        )
        // An absent `notifications` object means every kind is on, which is the
        // server's default for an account that has never touched them.
        notifications =
            ((try? container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications)) ?? nil)
            ?? NotificationPreferences()
    }

    // MARK: Stances

    /// The stance recorded for a topic.
    /// - Parameter topicId: A taxonomy id.
    public func stance(for topicId: String) -> TopicStance {
        if interests.contains(topicId) { return .interested }
        if mutedTopics.contains(topicId) { return .muted }
        return .none
    }

    /// A copy with `topicId` moved to `stance`.
    ///
    /// A topic never appears in both lists, which is what makes the round trip
    /// through ``topicPayload`` lossless.
    public func setting(_ stance: TopicStance, for topicId: String) -> FeedPreferences {
        var copy = self
        copy.interests.removeAll { $0 == topicId }
        copy.mutedTopics.removeAll { $0 == topicId }
        switch stance {
        case .interested: copy.interests = (copy.interests + [topicId]).sorted()
        case .muted: copy.mutedTopics = (copy.mutedTopics + [topicId]).sorted()
        case .none: break
        }
        return copy
    }

    /// A copy holding only topic ids the given taxonomy knows about.
    ///
    /// The server can hand back an id this build has never heard of — a topic
    /// added after the app shipped, or a stale row. It is dropped rather than
    /// echoed back, because `PUT /me/preferences` rejects the whole request
    /// with `unknown_topic` if one slips into the array.
    /// - Parameter knownTopicIds: Ids from `GET /topics`.
    public func limited(to knownTopicIds: Set<String>) -> FeedPreferences {
        var copy = self
        copy.interests = interests.filter(knownTopicIds.contains)
        copy.mutedTopics = mutedTopics.filter(knownTopicIds.contains)
        return copy
    }

    /// Topic ids the server sent that this build does not recognise.
    public func unknownTopicIds(against knownTopicIds: Set<String>) -> [String] {
        (interests + mutedTopics).filter { !knownTopicIds.contains($0) }.sorted()
    }

    /// The `topics` array for a `PUT`, in a stable order.
    ///
    /// Only topics with an actual stance appear: `topics` is a **full
    /// replacement**, so a topic left out is exactly how "no opinion" is said.
    public var topicPayload: [TopicStancePayload] {
        let interested = interests.map { TopicStancePayload(topic: $0, stance: "interested") }
        let muted = mutedTopics.map { TopicStancePayload(topic: $0, stance: "muted") }
        return (interested + muted).sorted { $0.topic < $1.topic }
    }

    // MARK: Derived truth

    /// Whether an allow-list is genuinely in force.
    ///
    /// Mirrors the backend's own rule: the toggle alone narrows nothing,
    /// because with no interests chosen there is nothing to narrow *to*. Every
    /// sentence the UI shows is derived from this rather than from the toggle.
    public var narrowsToInterests: Bool {
        filterInternationalByInterests && !interests.isEmpty
    }

    /// The dishonest-looking state the screen has to call out: the switch is
    /// on, and it is doing nothing.
    public var isFilterOnButUnused: Bool {
        filterInternationalByInterests && interests.isEmpty
    }

    /// Whether anything at all changes the International feed.
    public var changesInternationalFeed: Bool {
        narrowsToInterests || !mutedTopics.isEmpty || !mutedCountries.isEmpty
    }

    /// Whether ``showUntaggedPosts`` currently has any effect.
    ///
    /// It is only consulted while the feed is narrowed to interests; outside
    /// that, untagged posts are shown regardless of what the switch says.
    public var showUntaggedPostsHasEffect: Bool { narrowsToInterests }
}

// MARK: - Update body

/// One `{"topic": …, "stance": …}` entry in a `PUT` body.
public struct TopicStancePayload: Encodable, Equatable, Sendable {
    /// Taxonomy id.
    public let topic: String
    /// `"interested"` or `"muted"` — never `nil`, never `"none"`.
    public let stance: String

    public init(topic: String, stance: String) {
        self.topic = topic
        self.stance = stance
    }
}

/// The `PUT /me/preferences` body.
///
/// Every field is optional and the synthesised encoder omits the `nil`s, which
/// is what makes the call a partial update. `topics`, when present, replaces
/// the entire stance set.
public struct PreferencesUpdate: Encodable, Equatable, Sendable {

    /// Full replacement of the stance set, or `nil` to leave stances alone.
    public var topics: [TopicStancePayload]?
    /// New value for the International narrowing switch.
    public var filterInternationalByInterests: Bool?
    /// New value for the untagged-post switch.
    public var showUntaggedPosts: Bool?
    /// Full replacement of the muted-country list.
    public var mutedCountries: [String]?
    /// Full replacement of the per-kind notification switches.
    ///
    /// Like `topics` and `mutedCountries` this **replaces** what is stored, so
    /// ``NotificationPreferences/payload`` always states every kind rather than
    /// only the one that changed.
    public var notifications: [String: Bool]?

    public init(
        topics: [TopicStancePayload]? = nil,
        filterInternationalByInterests: Bool? = nil,
        showUntaggedPosts: Bool? = nil,
        mutedCountries: [String]? = nil,
        notifications: [String: Bool]? = nil
    ) {
        self.topics = topics
        self.filterInternationalByInterests = filterInternationalByInterests
        self.showUntaggedPosts = showUntaggedPosts
        self.mutedCountries = mutedCountries
        self.notifications = notifications
    }

    /// A body that makes the server's state equal `preferences` exactly.
    ///
    /// Sends every field the **feed-preferences screen** edits, because that
    /// screen edits all of them and a partial body would leave the user unable
    /// to tell what actually got stored.
    ///
    /// `notifications` is deliberately **not** among them: those five switches
    /// live on their own surface and save themselves, and re-asserting a copy
    /// this screen loaded minutes ago would quietly undo a change made there.
    /// - Parameter preferences: The edited working copy.
    public static func replacing(_ preferences: FeedPreferences) -> PreferencesUpdate {
        PreferencesUpdate(
            topics: preferences.topicPayload,
            filterInternationalByInterests: preferences.filterInternationalByInterests,
            showUntaggedPosts: preferences.showUntaggedPosts,
            mutedCountries: preferences.mutedCountries
        )
    }
}

// MARK: - Muted countries

/// Why a typed country code was refused.
public enum CountryEntryError: Error, Equatable, Sendable {
    /// Nothing was typed.
    case empty
    /// Not a real ISO-3166 alpha-2 code.
    case notACountry
    /// Already on the list.
    case alreadyMuted

    /// A sentence safe to put under the field.
    public var message: String {
        switch self {
        case .empty:
            return "Type a two-letter country code first."
        case .notACountry:
            return "That isn't a country code. Use two letters, like SA or JP."
        case .alreadyMuted:
            return "That country is already muted."
        }
    }
}

/// Validation and normalisation for the muted-country list.
///
/// The server accepts any two letters and only uppercases them, so `"XX"`
/// would be stored happily and then match nobody. This client refuses codes
/// that are not real ISO regions — the same rule ``CountryCode`` already
/// applies to the verified country badge, so a muted country is always a
/// country that can actually appear on a post.
public enum MutedCountries {

    /// Uppercases, validates, de-duplicates and sorts — the shape the server
    /// stores, so a round trip does not look like an edit.
    /// - Parameter codes: Raw codes, in any case and any order.
    public static func normalised(_ codes: [String]) -> [String] {
        Array(Set(codes.compactMap { CountryCode.normalised($0) })).sorted()
    }

    /// Validates one typed code against the list it would join.
    /// - Parameters:
    ///   - raw: Exactly what the user typed.
    ///   - existing: Codes already muted.
    /// - Returns: The canonical code, or why it was refused.
    public static func validate(
        _ raw: String,
        existing: [String]
    ) -> Result<String, CountryEntryError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let code = CountryCode.normalised(trimmed) else { return .failure(.notACountry) }
        guard !existing.contains(code) else { return .failure(.alreadyMuted) }
        return .success(code)
    }

    /// `"Japan (JP)"`, or just the code when the device has no name for it.
    public static func displayName(_ code: String) -> String {
        guard let name = CountryCode.name(code) else { return code }
        return "\(name) (\(code))"
    }
}

// MARK: - The honest summary

/// The sentences the screen uses to describe what the settings actually do.
///
/// Pure functions on purpose: the exact wording is the part of this feature
/// most likely to drift away from the backend's behaviour, so it is asserted
/// directly in tests rather than only through a view.
public enum PreferencesSummary {

    /// One sentence describing what the International feed will show.
    ///
    /// Derived from ``FeedPreferences/narrowsToInterests``, not from the
    /// toggle — the filter switched on with nothing selected narrows nothing,
    /// and this sentence says so by describing the feed as unfiltered.
    /// - Parameter preferences: The settings to describe.
    public static func sentence(for preferences: FeedPreferences) -> String {
        let hidden = hiddenClauses(preferences)

        guard preferences.narrowsToInterests else {
            if hidden.isEmpty {
                return "Your International feed shows everything."
            }
            return "Your International feed shows everything except \(list(hidden))."
        }

        let count = preferences.interests.count
        let topics = "\(count) topic\(count == 1 ? "" : "s") you chose"
        var sentence: String
        if preferences.showUntaggedPosts {
            sentence = "Your International feed shows posts about \(topics), "
                + "plus posts that haven't been labelled yet."
        } else {
            sentence = "Your International feed shows only posts about \(topics); "
                + "posts that haven't been labelled yet are hidden."
        }
        if !hidden.isEmpty {
            sentence += " It also hides \(list(hidden))."
        }
        return sentence
    }

    /// The warning shown when the filter is on and does nothing, or `nil`.
    /// - Parameter preferences: The settings to check.
    public static func unusedFilterWarning(for preferences: FeedPreferences) -> String? {
        guard preferences.isFilterOnButUnused else { return nil }
        return "This switch is on, but you haven't marked any topic as Interested — "
            + "so nothing is being filtered and your International feed still shows "
            + "everything. Mark at least one topic Interested below, or turn this off."
    }

    /// The clauses describing what is hidden, in a fixed order.
    private static func hiddenClauses(_ preferences: FeedPreferences) -> [String] {
        var clauses: [String] = []
        let topics = preferences.mutedTopics.count
        if topics > 0 {
            clauses.append("posts about \(topics) muted topic\(topics == 1 ? "" : "s")")
        }
        let countries = preferences.mutedCountries.count
        if countries > 0 {
            clauses.append("posts from \(countries) muted \(countries == 1 ? "country" : "countries")")
        }
        return clauses
    }

    /// `["a"]` → `"a"`, `["a", "b"]` → `"a and b"`.
    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and \(parts[parts.count - 1])"
    }
}

// MARK: - Wire shapes

/// `GET /topics` → `{"topics": [{"id", "description"}]}`.
struct TopicsResponse: Decodable {
    let topics: [TopicOption]

    private enum CodingKeys: String, CodingKey {
        case topics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A row with no id could never be selected or sent back, so it is
        // dropped rather than rendered as a nameless switch.
        topics = ((try? container.decode([TopicOption].self, forKey: .topics)) ?? [])
            .filter(\.isValid)
    }

    init(topics: [TopicOption]) {
        self.topics = topics
    }
}
