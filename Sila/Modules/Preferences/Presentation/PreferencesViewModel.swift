import Foundation
import Observation

/// Which slice of the 20-topic list is on screen.
///
/// Twenty rows is too many to scan for "what did I actually choose?", and
/// re-ordering rows as stances change would move a row out from under the
/// finger that just tapped it. So the order is fixed and alphabetical, and
/// this narrows the list instead.
public enum TopicListFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, interested, muted, noOpinion

    public var id: String { rawValue }

    /// Segment label, without the count.
    public var title: String {
        switch self {
        case .all: return "All"
        case .interested: return "Interested"
        case .muted: return "Muted"
        case .noOpinion: return "No opinion"
        }
    }

    /// Accessibility hint for the segmented control.
    public var accessibilityHint: String {
        switch self {
        case .all: return "Shows every topic"
        case .interested: return "Shows only topics you marked interested"
        case .muted: return "Shows only topics you muted"
        case .noOpinion: return "Shows only topics you have no opinion about"
        }
    }

    /// The stance a segment corresponds to, or `nil` for ``all``.
    var stance: TopicStance? {
        switch self {
        case .all: return nil
        case .interested: return .interested
        case .muted: return .muted
        case .noOpinion: return TopicStance.none
        }
    }
}

/// Drives ``PreferencesScreen``.
///
/// Holds two copies of the preferences: ``draft``, which the controls edit, and
/// ``saved``, which is the last thing the *server* confirmed. Every "saved"
/// affordance on the screen is derived from a comparison of the two, so the UI
/// cannot claim a state it has not stored — and a failed save leaves ``draft``
/// untouched, because throwing away someone's edits to make a screen tidy is
/// the worse of the two failures.
@MainActor
@Observable
public final class PreferencesViewModel {

    /// The taxonomy, sorted by the label the user actually reads.
    public private(set) var topics: [TopicOption] = []
    /// The working copy every control edits.
    public private(set) var draft = FeedPreferences()
    /// The last state the server confirmed. Never written optimistically.
    public private(set) var saved = FeedPreferences()
    /// `true` during the initial load.
    public private(set) var isLoading = false
    /// `true` while a save is in flight.
    public private(set) var isSaving = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the screen could not load, when it could not.
    public private(set) var loadError: String?
    /// Why the last save failed. Cleared by the next successful save.
    public private(set) var saveError: String?
    /// Topic ids the server sent that this build does not recognise.
    ///
    /// Surfaced rather than swallowed: they are dropped from the next save, and
    /// a user whose stored choice silently vanishes deserves to be told.
    public private(set) var unknownTopicIds: [String] = []
    /// Which slice of the topic list is shown.
    public var listFilter: TopicListFilter = .all
    /// Contents of the "add a country" field.
    public var countryDraft = "" {
        didSet { if countryDraft != oldValue { countryError = nil } }
    }
    /// Why the typed country code was refused, when it was.
    public private(set) var countryError: String?
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: PreferencesServiceProtocol
    private let analytics: AnalyticsClient
    private let onFilteringChanged: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - service: Preferences backend.
    ///   - analytics: Event sink.
    ///   - onFilteringChanged: Called after a save the server accepted that
    ///     changed anything the International feed filters on, so the feed can
    ///     drop the page it loaded under the old rules.
    public init(
        service: PreferencesServiceProtocol,
        analytics: AnalyticsClient,
        onFilteringChanged: (@MainActor () -> Void)? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.onFilteringChanged = onFilteringChanged
    }

    // MARK: - Derived state

    /// Ids the server currently offers.
    public var knownTopicIds: Set<String> { Set(topics.map(\.id)) }

    /// `true` when the draft differs from what the server holds.
    public var hasUnsavedChanges: Bool { draft != saved }

    /// `true` only when everything on screen is genuinely stored.
    ///
    /// The single guard behind every "saved" affordance.
    public var isFullySaved: Bool { hasLoaded && loadError == nil && !hasUnsavedChanges }

    /// The live sentence describing what the *draft* would do.
    public var summary: String { PreferencesSummary.sentence(for: draft) }

    /// Whether ``summary`` describes the feed as it is right now, rather than
    /// as it would be after saving.
    public var summaryIsInEffect: Bool { isFullySaved }

    /// The warning for "filter on, nothing selected", or `nil`.
    public var unusedFilterWarning: String? {
        PreferencesSummary.unusedFilterWarning(for: draft)
    }

    /// The rows to render, in the current slice.
    public var visibleTopics: [TopicOption] {
        guard let stance = listFilter.stance else { return topics }
        return topics.filter { draft.stance(for: $0.id) == stance }
    }

    /// How many topics carry a given stance in the draft.
    public func count(of stance: TopicStance) -> Int {
        topics.filter { draft.stance(for: $0.id) == stance }.count
    }

    /// Segment label with its count, e.g. `"Muted (1)"`.
    public func title(for filter: TopicListFilter) -> String {
        guard let stance = filter.stance else { return "\(filter.title) (\(topics.count))" }
        return "\(filter.title) (\(count(of: stance)))"
    }

    // MARK: - Loading

    /// Loads the taxonomy and the stored preferences. Safe to call on every
    /// appearance — it does nothing once loaded.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry path.
    public func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            async let taxonomy = service.fetchTopics()
            async let stored = service.fetchPreferences()
            let options = try await taxonomy
            let preferences = try await stored

            topics = options.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            let known = Set(options.map(\.id))
            unknownTopicIds = preferences.unknownTopicIds(against: known)
            // Unknown ids are dropped from both copies, so the screen never
            // shows a stance it cannot render and never sends one back.
            saved = preferences.limited(to: known)
            draft = saved
            hasLoaded = true
            analytics.track(.preferencesLoaded, properties: [
                "topics": String(options.count),
                "narrows": String(saved.narrowsToInterests)
            ])
        } catch {
            loadError = APIError.wrapping(error).userMessage
        }
    }

    // MARK: - Editing

    /// Sets a topic's stance in the draft.
    /// - Parameters:
    ///   - stance: The new stance.
    ///   - topicId: A taxonomy id.
    public func setStance(_ stance: TopicStance, for topicId: String) {
        guard knownTopicIds.contains(topicId) else { return }
        guard draft.stance(for: topicId) != stance else { return }
        draft = draft.setting(stance, for: topicId)
        analytics.track(.topicStanceChanged, properties: [
            "topic": topicId,
            "stance": stance.rawValue
        ])
    }

    /// Turns the International narrowing switch on or off in the draft.
    public func setFilterEnabled(_ enabled: Bool) {
        draft.filterInternationalByInterests = enabled
    }

    /// Turns "show posts that haven't been labelled" on or off in the draft.
    public func setShowUntaggedPosts(_ show: Bool) {
        draft.showUntaggedPosts = show
    }

    /// Validates ``countryDraft`` and adds it to the muted list.
    ///
    /// Refused codes stay in the field with a reason under it, rather than
    /// being cleared as though something happened.
    public func addCountry() {
        switch MutedCountries.validate(countryDraft, existing: draft.mutedCountries) {
        case let .success(code):
            draft.mutedCountries = (draft.mutedCountries + [code]).sorted()
            countryDraft = ""
            countryError = nil
        case let .failure(reason):
            countryError = reason.message
        }
    }

    /// Removes a muted country from the draft.
    public func removeCountry(_ code: String) {
        draft.mutedCountries.removeAll { $0 == code }
    }

    /// Throws the unsaved edits away and returns to the stored state.
    public func discardChanges() {
        draft = saved
        countryDraft = ""
        countryError = nil
        saveError = nil
    }

    // MARK: - Saving

    /// Writes the draft and adopts whatever the server says it stored.
    ///
    /// The screen's state after a success comes from the response, not from the
    /// draft — if the server normalises something, the user sees the real
    /// stored value rather than their own guess at it.
    public func save() async {
        guard hasLoaded, hasUnsavedChanges, !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let known = knownTopicIds
        let update = PreferencesUpdate.replacing(draft.limited(to: known))

        do {
            let confirmed = try await service.updatePreferences(update).limited(to: known)
            let changedFiltering = confirmed != saved
            saved = confirmed
            draft = confirmed
            unknownTopicIds = []
            toast = .success("Preferences saved.")
            if changedFiltering {
                // Every field on this screen feeds the International query, so
                // any accepted change makes a loaded page stale.
                onFilteringChanged?()
            }
        } catch {
            // The edits stay exactly where they were. Resetting them would lose
            // work in order to make the screen agree with the server.
            saveError = APIError.wrapping(error).userMessage
            toast = .error(saveError ?? "Couldn't save your preferences.")
            analytics.track(.preferencesSaveFailed, properties: [
                "code": (error as? APIError)?.code?.rawValue ?? "transport"
            ])
        }
    }
}
