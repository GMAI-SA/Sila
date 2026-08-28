import XCTest
@testable import Sila

/// ``PreferencesServiceProtocol`` whose every answer the test chooses.
///
/// The view-model tests are about *honesty* — whether the screen ever claims
/// something it has not stored — so the service has to be able to fail on
/// demand and to record exactly what it was asked to write.
final class ScriptedPreferencesService: PreferencesServiceProtocol, @unchecked Sendable {

    var topics: [TopicOption] = [
        TopicOption(id: "technology", detail: "Software, hardware, AI, startups, engineering"),
        TopicOption(id: "science", detail: "Research, space, physics, biology, discovery"),
        TopicOption(id: "politics", detail: "Government, policy, elections, public affairs"),
        TopicOption(id: "real_estate", detail: "Property, housing, construction, land")
    ]
    var preferences = FeedPreferences()
    /// When set, loads fail.
    var loadError: APIError?
    /// When set, saves fail.
    var saveError: APIError?
    /// Overrides what a successful save reports back, to simulate the server
    /// normalising or rejecting part of a request.
    var savedResponse: FeedPreferences?
    /// Every body received, in order.
    private(set) var updates: [PreferencesUpdate] = []

    func fetchTopics() async throws -> [TopicOption] {
        if let loadError { throw loadError }
        return topics
    }

    func fetchPreferences() async throws -> FeedPreferences {
        if let loadError { throw loadError }
        return preferences
    }

    func updatePreferences(_ update: PreferencesUpdate) async throws -> FeedPreferences {
        updates.append(update)
        if let saveError { throw saveError }
        if let savedResponse {
            preferences = savedResponse
            return savedResponse
        }
        preferences = FeedPreferences(
            interests: update.topics?.filter { $0.stance == "interested" }.map(\.topic)
                ?? preferences.interests,
            mutedTopics: update.topics?.filter { $0.stance == "muted" }.map(\.topic)
                ?? preferences.mutedTopics,
            filterInternationalByInterests: update.filterInternationalByInterests
                ?? preferences.filterInternationalByInterests,
            showUntaggedPosts: update.showUntaggedPosts ?? preferences.showUntaggedPosts,
            mutedCountries: update.mutedCountries ?? preferences.mutedCountries
        )
        return preferences
    }
}

// MARK: - The summary sentences

/// The wording the screen shows for what the settings actually do.
///
/// Asserted directly, because this is the feature's whole obligation: someone
/// must never believe their feed is filtered when it is not, or the reverse.
final class PreferencesSummaryTests: XCTestCase {

    private func sentence(_ preferences: FeedPreferences) -> String {
        PreferencesSummary.sentence(for: preferences)
    }

    func testNothingChosenSaysTheFeedShowsEverything() {
        XCTAssertEqual(
            sentence(FeedPreferences()),
            "Your International feed shows everything."
        )
    }

    func testTheFilterOnWithNothingSelectedStillSaysTheFeedShowsEverything() {
        let preferences = FeedPreferences(filterInternationalByInterests: true)

        XCTAssertEqual(
            sentence(preferences),
            "Your International feed shows everything.",
            "The backend does not narrow in this state, so neither may the sentence"
        )
        XCTAssertTrue(preferences.isFilterOnButUnused)
        XCTAssertFalse(preferences.narrowsToInterests)
    }

    func testTheFilterOnWithNothingSelectedProducesTheHonestWarning() throws {
        let text = try XCTUnwrap(
            PreferencesSummary.unusedFilterWarning(
                for: FeedPreferences(filterInternationalByInterests: true)
            ),
            "A switch that is on and doing nothing has to say so"
        )

        XCTAssertTrue(text.contains("nothing is being filtered"), text)
        XCTAssertTrue(text.contains("still shows everything"), text)
        XCTAssertTrue(
            text.contains("Mark at least one topic Interested"),
            "Saying the control does nothing is only half the job; it has to say what to do: \(text)"
        )
    }

    func testTheWarningIsAbsentAsSoonAsAnInterestExists() {
        XCTAssertNil(PreferencesSummary.unusedFilterWarning(for: FeedPreferences(
            interests: ["technology"],
            filterInternationalByInterests: true
        )))
        XCTAssertNil(PreferencesSummary.unusedFilterWarning(for: FeedPreferences(
            interests: ["technology"],
            filterInternationalByInterests: false
        )))
    }

    func testNarrowingWithUntaggedPostsShownNamesBothHalves() {
        XCTAssertEqual(
            sentence(FeedPreferences(
                interests: ["science", "technology", "art"],
                filterInternationalByInterests: true,
                showUntaggedPosts: true
            )),
            "Your International feed shows posts about 3 topics you chose, "
            + "plus posts that haven't been labelled yet."
        )
    }

    func testNarrowingWithUntaggedPostsHiddenSaysTheyAreHidden() {
        XCTAssertEqual(
            sentence(FeedPreferences(
                interests: ["technology"],
                filterInternationalByInterests: true,
                showUntaggedPosts: false
            )),
            "Your International feed shows only posts about 1 topic you chose; "
            + "posts that haven't been labelled yet are hidden."
        )
    }

    func testMutedTopicsApplyEvenWithTheFilterOffBecauseTheBackendAppliesThem() {
        XCTAssertEqual(
            sentence(FeedPreferences(
                mutedTopics: ["politics", "sports"],
                filterInternationalByInterests: false
            )),
            "Your International feed shows everything except posts about 2 muted topics."
        )
    }

    func testMutedCountriesAloneAreDescribedInTheSingular() {
        XCTAssertEqual(
            sentence(FeedPreferences(mutedCountries: ["JP"])),
            "Your International feed shows everything except posts from 1 muted country."
        )
    }

    func testMutedTopicsAndCountriesTogetherReadAsOneList() {
        XCTAssertEqual(
            sentence(FeedPreferences(
                mutedTopics: ["politics"],
                mutedCountries: ["JP", "SA"]
            )),
            "Your International feed shows everything except posts about 1 muted topic "
            + "and posts from 2 muted countries."
        )
    }

    func testNarrowingAndMutingTogetherKeepBothFacts() {
        XCTAssertEqual(
            sentence(FeedPreferences(
                interests: ["technology", "science"],
                mutedTopics: ["politics"],
                filterInternationalByInterests: true,
                showUntaggedPosts: true,
                mutedCountries: ["JP"]
            )),
            "Your International feed shows posts about 2 topics you chose, "
            + "plus posts that haven't been labelled yet. "
            + "It also hides posts about 1 muted topic and posts from 1 muted country."
        )
    }

    func testEverySentenceNamesTheInternationalFeedAndNoOther() {
        let cases = [
            FeedPreferences(),
            FeedPreferences(filterInternationalByInterests: true),
            FeedPreferences(interests: ["technology"], filterInternationalByInterests: true),
            FeedPreferences(mutedTopics: ["politics"]),
            FeedPreferences(mutedCountries: ["SA"])
        ]

        for preferences in cases {
            let text = sentence(preferences)
            XCTAssertTrue(text.hasPrefix("Your International feed"), text)
            XCTAssertFalse(text.contains("Following"), text)
            XCTAssertFalse(text.contains("For You"), text)
        }
    }

    func testShowUntaggedOnlyMattersWhileTheFeedIsNarrowed() {
        XCTAssertFalse(
            FeedPreferences(showUntaggedPosts: false).showUntaggedPostsHasEffect,
            "Nothing narrows the feed, so the switch changes nothing — and the UI says so"
        )
        XCTAssertFalse(
            FeedPreferences(filterInternationalByInterests: true, showUntaggedPosts: false)
                .showUntaggedPostsHasEffect
        )
        XCTAssertTrue(
            FeedPreferences(
                interests: ["technology"],
                filterInternationalByInterests: true,
                showUntaggedPosts: false
            ).showUntaggedPostsHasEffect
        )
    }
}

// MARK: - Country entry

/// Validation and normalisation of the muted-country list.
final class MutedCountriesTests: XCTestCase {

    func testALowercaseCodeIsAcceptedAndUppercased() {
        XCTAssertEqual(try? MutedCountries.validate("jp", existing: []).get(), "JP")
        XCTAssertEqual(try? MutedCountries.validate("  sa  ", existing: []).get(), "SA")
    }

    func testAnEmptyFieldIsRefusedWithoutAddingAnything() {
        XCTAssertEqual(MutedCountries.validate("   ", existing: []), .failure(.empty))
    }

    func testACountryNameIsNotACountryCode() {
        XCTAssertEqual(MutedCountries.validate("Japan", existing: []), .failure(.notACountry))
        XCTAssertEqual(MutedCountries.validate("JPN", existing: []), .failure(.notACountry))
        XCTAssertEqual(MutedCountries.validate("1", existing: []), .failure(.notACountry))
    }

    func testCLDRPlaceholdersAreRefusedEvenThoughTheServerWouldStoreThem() {
        // The server only checks "two letters"; ZZ, EU and UK would all be
        // stored and then match nobody's verified badge.
        for placeholder in ["ZZ", "EU", "UK"] {
            XCTAssertEqual(
                MutedCountries.validate(placeholder, existing: []),
                .failure(.notACountry),
                "\(placeholder) is not an ISO-3166 country"
            )
        }
    }

    func testADuplicateIsRefusedRatherThanSilentlyIgnored() {
        XCTAssertEqual(MutedCountries.validate("jp", existing: ["JP"]), .failure(.alreadyMuted))
    }

    func testNormalisationUppercasesDeduplicatesAndSorts() {
        XCTAssertEqual(
            MutedCountries.normalised(["sa", "JP", "jp", "  br "]),
            ["BR", "JP", "SA"]
        )
    }

    func testNormalisationDropsAnythingThatIsNotACountry() {
        XCTAssertEqual(MutedCountries.normalised(["JP", "ZZ", "", "XYZ"]), ["JP"])
    }

    func testTheDisplayNameShowsTheCountryNotJustTheCode() {
        let japan = MutedCountries.displayName("JP")
        XCTAssertTrue(japan.contains("(JP)"))
        XCTAssertTrue(japan.count > 4, "A bare code is not a country name: \(japan)")
    }
}

// MARK: - The view model

@MainActor
final class PreferencesViewModelTests: XCTestCase {

    private func makeViewModel(
        _ service: ScriptedPreferencesService,
        onFilteringChanged: (@MainActor () -> Void)? = nil
    ) -> PreferencesViewModel {
        PreferencesViewModel(
            service: service,
            analytics: RecordingAnalyticsClient(),
            onFilteringChanged: onFilteringChanged
        )
    }

    // MARK: Loading

    func testLoadingSortsTopicsByTheLabelPeopleActuallyRead() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.topics.map(\.label),
            ["Politics", "Real estate", "Science", "Technology"]
        )
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.loadError)
    }

    func testASecondAppearanceDoesNotRefetchAndDoesNotDiscardEdits() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)

        await viewModel.load()
        viewModel.setStance(.interested, for: "technology")
        await viewModel.load()

        XCTAssertEqual(viewModel.draft.interests, ["technology"])
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    func testAFailedLoadSaysSoInsteadOfShowingAnEmptyPicker() async {
        let service = ScriptedPreferencesService()
        service.loadError = .transport("offline")
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasLoaded)
        XCTAssertNotNil(viewModel.loadError)
        XCTAssertTrue(viewModel.topics.isEmpty)
        XCTAssertFalse(
            viewModel.isFullySaved,
            "A screen that never loaded must not read as saved"
        )
    }

    func testUnknownStoredTopicsAreSurfacedAndKeptOutOfThePicker() async {
        let service = ScriptedPreferencesService()
        service.preferences = FeedPreferences(
            interests: ["technology", "quantum_basketry"],
            filterInternationalByInterests: true
        )
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.unknownTopicIds, ["quantum_basketry"])
        XCTAssertEqual(viewModel.draft.interests, ["technology"])
        XCTAssertFalse(
            viewModel.hasUnsavedChanges,
            "Dropping an unrenderable id is not an edit the user made"
        )
    }

    // MARK: Saved-state honesty

    func testAFreshlyLoadedScreenHasNothingToSave() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertTrue(viewModel.isFullySaved)
        XCTAssertTrue(viewModel.summaryIsInEffect)
    }

    func testAnEditIsNeverDescribedAsInEffectBeforeItIsStored() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.setStance(.interested, for: "technology")
        viewModel.setFilterEnabled(true)

        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertFalse(viewModel.isFullySaved)
        XCTAssertFalse(
            viewModel.summaryIsInEffect,
            "The sentence describes the draft, so it must be labelled as not yet applied"
        )
        XCTAssertEqual(
            viewModel.summary,
            "Your International feed shows posts about 1 topic you chose, "
            + "plus posts that haven't been labelled yet."
        )
    }

    func testTheSummaryUpdatesLiveAsControlsChange() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        XCTAssertEqual(viewModel.summary, "Your International feed shows everything.")

        viewModel.setFilterEnabled(true)
        XCTAssertEqual(
            viewModel.summary,
            "Your International feed shows everything.",
            "Nothing is selected, so the switch alone changes nothing"
        )
        XCTAssertNotNil(viewModel.unusedFilterWarning)

        viewModel.setStance(.interested, for: "science")
        XCTAssertEqual(
            viewModel.summary,
            "Your International feed shows posts about 1 topic you chose, "
            + "plus posts that haven't been labelled yet."
        )
        XCTAssertNil(viewModel.unusedFilterWarning)

        viewModel.setStance(.muted, for: "politics")
        XCTAssertTrue(viewModel.summary.hasSuffix("It also hides posts about 1 muted topic."))
    }

    // MARK: Stances

    func testAStanceMovesBetweenListsRatherThanAppearingInBoth() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.setStance(.interested, for: "technology")
        viewModel.setStance(.muted, for: "technology")

        XCTAssertTrue(viewModel.draft.interests.isEmpty)
        XCTAssertEqual(viewModel.draft.mutedTopics, ["technology"])
        XCTAssertEqual(viewModel.draft.stance(for: "technology"), .muted)
    }

    func testClearingAStanceLeavesTheTopicOutOfBothLists() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.setStance(.interested, for: "technology")
        viewModel.setStance(TopicStance.none, for: "technology")

        XCTAssertEqual(viewModel.draft.stance(for: "technology"), TopicStance.none)
        XCTAssertTrue(viewModel.draft.topicPayload.isEmpty)
    }

    func testAnUnknownTopicIdCannotBeGivenAStance() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.setStance(.interested, for: "quantum_basketry")

        XCTAssertTrue(viewModel.draft.interests.isEmpty)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testTheListCanBeNarrowedToOneStanceWithoutReorderingTheRows() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()
        viewModel.setStance(.interested, for: "technology")
        viewModel.setStance(.muted, for: "politics")

        viewModel.listFilter = .interested
        XCTAssertEqual(viewModel.visibleTopics.map(\.id), ["technology"])

        viewModel.listFilter = .muted
        XCTAssertEqual(viewModel.visibleTopics.map(\.id), ["politics"])

        viewModel.listFilter = .all
        XCTAssertEqual(
            viewModel.visibleTopics.map(\.label),
            ["Politics", "Real estate", "Science", "Technology"],
            "The order never depends on the stance, so a tapped row stays put"
        )
        XCTAssertEqual(viewModel.title(for: .interested), "Interested (1)")
        XCTAssertEqual(viewModel.title(for: .noOpinion), "No opinion (2)")
    }

    // MARK: Countries

    func testAddingACountryNormalisesItAndClearsTheField() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.countryDraft = "jp"
        viewModel.addCountry()

        XCTAssertEqual(viewModel.draft.mutedCountries, ["JP"])
        XCTAssertEqual(viewModel.countryDraft, "")
        XCTAssertNil(viewModel.countryError)
    }

    func testARefusedCountryKeepsWhatWasTypedAndExplainsWhy() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.countryDraft = "Japan"
        viewModel.addCountry()

        XCTAssertTrue(viewModel.draft.mutedCountries.isEmpty)
        XCTAssertEqual(viewModel.countryDraft, "Japan", "Clearing it would look like it worked")
        XCTAssertEqual(viewModel.countryError, CountryEntryError.notACountry.message)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testTypingAgainClearsTheStaleValidationMessage() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.countryDraft = "Japan"
        viewModel.addCountry()
        XCTAssertNotNil(viewModel.countryError)

        viewModel.countryDraft = "JP"
        XCTAssertNil(viewModel.countryError)
    }

    func testRemovingACountryTakesItOutOfTheDraft() async {
        let service = ScriptedPreferencesService()
        service.preferences = FeedPreferences(mutedCountries: ["JP", "SA"])
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.removeCountry("JP")

        XCTAssertEqual(viewModel.draft.mutedCountries, ["SA"])
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    // MARK: Saving

    func testSavingSendsTheFullReplacementAndAdoptsTheServersAnswer() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()
        viewModel.setStance(.interested, for: "technology")
        viewModel.setStance(.muted, for: "politics")
        viewModel.setFilterEnabled(true)

        await viewModel.save()

        let update = service.updates.last
        XCTAssertEqual(
            update?.topics,
            [
                TopicStancePayload(topic: "politics", stance: "muted"),
                TopicStancePayload(topic: "technology", stance: "interested")
            ]
        )
        XCTAssertEqual(update?.filterInternationalByInterests, true)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertTrue(viewModel.isFullySaved)
        XCTAssertTrue(viewModel.summaryIsInEffect)
        XCTAssertEqual(viewModel.toast?.kind, .success)
    }

    func testSavingWithNothingChangedIssuesNoRequest() async {
        let service = ScriptedPreferencesService()
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.save()

        XCTAssertTrue(service.updates.isEmpty)
    }

    func testAFailedSaveKeepsEveryEditAndSaysItIsNotSaved() async {
        let service = ScriptedPreferencesService()
        service.saveError = .api(
            code: .unknownTopic,
            message: "Not topics in this taxonomy: nope",
            status: 400
        )
        let viewModel = makeViewModel(service)
        await viewModel.load()
        viewModel.setStance(.interested, for: "technology")
        viewModel.setFilterEnabled(true)
        viewModel.countryDraft = "JP"
        viewModel.addCountry()

        await viewModel.save()

        XCTAssertEqual(viewModel.draft.interests, ["technology"], "Edits survive a failed save")
        XCTAssertTrue(viewModel.draft.filterInternationalByInterests)
        XCTAssertEqual(viewModel.draft.mutedCountries, ["JP"])
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertFalse(viewModel.isFullySaved, "Nothing may read as saved after a rejection")
        XCTAssertFalse(viewModel.summaryIsInEffect)
        XCTAssertNotNil(viewModel.saveError)
        XCTAssertEqual(viewModel.toast?.kind, .error)
        XCTAssertEqual(viewModel.saved, FeedPreferences(), "The stored copy is untouched")
    }

    func testASaveThatFailsThenSucceedsClearsTheError() async {
        let service = ScriptedPreferencesService()
        service.saveError = .transport("offline")
        let viewModel = makeViewModel(service)
        await viewModel.load()
        viewModel.setStance(.interested, for: "science")

        await viewModel.save()
        XCTAssertNotNil(viewModel.saveError)

        service.saveError = nil
        await viewModel.save()

        XCTAssertNil(viewModel.saveError)
        XCTAssertTrue(viewModel.isFullySaved)
    }

    func testTheServersNormalisationWinsOverTheDraft() async {
        let service = ScriptedPreferencesService()
        // The server stores something different from what was asked for.
        service.savedResponse = FeedPreferences(
            interests: ["science"],
            filterInternationalByInterests: true
        )
        let viewModel = makeViewModel(service)
        await viewModel.load()
        viewModel.setStance(.interested, for: "technology")

        await viewModel.save()

        XCTAssertEqual(viewModel.draft.interests, ["science"])
        XCTAssertEqual(viewModel.saved.interests, ["science"])
        XCTAssertFalse(
            viewModel.hasUnsavedChanges,
            "The screen shows what is stored, not what was asked for"
        )
    }

    func testAnAcceptedChangeAsksTheInternationalFeedToDropItsStalePage() async {
        let service = ScriptedPreferencesService()
        var invalidations = 0
        let viewModel = makeViewModel(service, onFilteringChanged: { invalidations += 1 })
        await viewModel.load()
        viewModel.setStance(.muted, for: "politics")

        await viewModel.save()

        XCTAssertEqual(invalidations, 1)
    }

    func testARejectedChangeNeverInvalidatesTheFeed() async {
        let service = ScriptedPreferencesService()
        service.saveError = .transport("offline")
        var invalidations = 0
        let viewModel = makeViewModel(service, onFilteringChanged: { invalidations += 1 })
        await viewModel.load()
        viewModel.setStance(.muted, for: "politics")

        await viewModel.save()

        XCTAssertEqual(invalidations, 0, "Nothing changed server-side, so nothing is stale")
    }

    func testDiscardingReturnsToTheStoredStateExactly() async {
        let service = ScriptedPreferencesService()
        service.preferences = FeedPreferences(interests: ["science"], mutedCountries: ["JP"])
        let viewModel = makeViewModel(service)
        await viewModel.load()

        viewModel.setStance(.muted, for: "technology")
        viewModel.removeCountry("JP")
        viewModel.countryDraft = "Japan"
        viewModel.addCountry()
        viewModel.discardChanges()

        XCTAssertEqual(viewModel.draft, viewModel.saved)
        XCTAssertEqual(viewModel.draft.interests, ["science"])
        XCTAssertEqual(viewModel.draft.mutedCountries, ["JP"])
        XCTAssertNil(viewModel.countryError)
        XCTAssertTrue(viewModel.isFullySaved)
    }
}

// MARK: - The feed's reaction

@MainActor
final class InternationalFeedInvalidationTests: XCTestCase {

    func testInvalidatingDropsTheInternationalPageAndLeavesTheOtherFeedsAlone() async {
        let viewModel = HomeViewModel(
            service: FeedServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            initialTab: .forYou
        )
        await viewModel.loadIfNeeded(.forYou)
        await viewModel.select(.international)
        XCTAssertFalse(viewModel.state(for: .international).posts.isEmpty)
        let forYouBefore = viewModel.state(for: .forYou).posts

        await viewModel.invalidateInternationalFeed()

        XCTAssertTrue(
            viewModel.state(for: .international).hasLoaded,
            "The visible feed refetches immediately rather than blanking"
        )
        XCTAssertEqual(
            viewModel.state(for: .forYou).posts,
            forYouBefore,
            "Only International is filtered by topic, so only International is stale"
        )
    }

    func testInvalidatingAFeedThatIsNotOnScreenDefersTheReloadToItsNextVisit() async {
        let viewModel = HomeViewModel(
            service: FeedServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            initialTab: .forYou
        )
        await viewModel.select(.international)
        await viewModel.select(.forYou)

        await viewModel.invalidateInternationalFeed()

        XCTAssertFalse(viewModel.state(for: .international).hasLoaded)
        XCTAssertTrue(
            viewModel.state(for: .international).posts.isEmpty,
            "Nothing selected under the old rules may survive"
        )

        await viewModel.select(.international)
        XCTAssertTrue(viewModel.state(for: .international).hasLoaded)
    }
}

// MARK: - Feature flag

final class PreferencesFeatureFlagTests: XCTestCase {

    func testThePreferencesPhaseShipsOnByDefault() {
        XCTAssertTrue(FeatureFlags.resolved(arguments: ["Sila"]).preferences)
        XCTAssertFalse(FeatureFlags.resolved(arguments: ["Sila"]).useMockPreferences)
    }

    func testMockPreferencesArgumentSwitchesToTheMockService() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockPreferences"])
        XCTAssertTrue(flags.useMockPreferences)
        XCTAssertEqual(flags.mockPreferencesScenario, .populated)
    }

    func testMockPreferencesScenarioSelectsAWorldAndImpliesTheMock() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockPreferencesScenario", "saveFails"]
        )
        XCTAssertTrue(flags.useMockPreferences)
        XCTAssertEqual(flags.mockPreferencesScenario, .saveFails)
    }

    func testAnUnknownPreferencesScenarioNameIsIgnored() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockPreferencesScenario", "banana"]
        )
        XCTAssertFalse(flags.useMockPreferences)
    }

    func testMockingAuthAlsoMocksPreferencesBecauseThereIsNoRealToken() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"])
        XCTAssertTrue(flags.useMockPreferences)
    }

    func testAnExplicitPreferencesScenarioWinsOverTheMockAuthDefault() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockAuth", "-mockPreferencesScenario", "empty"]
        )
        XCTAssertEqual(flags.mockPreferencesScenario, .empty)
    }
}

// MARK: - The disclosure itself

@MainActor
final class TaggingDisclosureTests: XCTestCase {

    /// The screen's obligation, asserted so it cannot quietly soften.
    func testTheDisclosureSaysWhatIsHappeningWithoutEuphemism() {
        let text = PreferencesScreen.taggingDisclosure

        XCTAssertTrue(text.contains("automatically labelled"), text)
        XCTAssertTrue(text.contains("software"), text)
        XCTAssertTrue(text.contains("sometimes wrong"), text)
        XCTAssertTrue(
            text.contains("these settings are the only thing"),
            "It has to say what the labels are used for: \(text)"
        )
        XCTAssertTrue(
            text.contains("never shown on the post itself"),
            "Tags are hidden from posts, and the person affected should know: \(text)"
        )
    }
}
