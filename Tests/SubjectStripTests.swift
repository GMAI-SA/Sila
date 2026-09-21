import XCTest
@testable import Sila

/// A scripted catalogue, so the ordering and the muting rules can be driven
/// exactly rather than inferred from whatever the taxonomy happens to hold.
struct StubSubjects: SubjectCatalogProviding {
    var catalog: SubjectCatalog
    var error: Error?

    func loadSubjects() async throws -> SubjectCatalog {
        if let error { throw error }
        return catalog
    }
}

/// The subject strip: the row above the timeline that narrows every tab.
@MainActor
final class SubjectStripTests: XCTestCase {

    private func option(_ id: String) -> TopicOption {
        TopicOption(id: id, detail: id)
    }

    private func catalog(
        _ ids: [String],
        interests: Set<String> = [],
        muted: Set<String> = []
    ) -> StubSubjects {
        StubSubjects(catalog: SubjectCatalog(
            topics: ids.map(option),
            interests: interests,
            muted: muted
        ))
    }

    private func makeViewModel(
        service: FeedServiceMock = FeedServiceMock(scenario: .populated),
        subjects: SubjectCatalogProviding? = nil,
        storage: StorageClient? = nil
    ) -> HomeViewModel {
        HomeViewModel(
            service: service,
            analytics: RecordingAnalyticsClient(),
            subjects: subjects,
            storage: storage,
            subjectDebounce: 0
        )
    }

    // MARK: - Ordering

    func testChosenInterestsLeadTheStrip() {
        let strip = SubjectOrder.strip(
            topics: ["business", "art", "science"].map(option),
            interests: ["science"],
            muted: []
        )
        XCTAssertEqual(strip.map(\.id), ["science", "art", "business"])
    }

    func testHiddenSubjectsAreNeverOffered() {
        let strip = SubjectOrder.strip(
            topics: ["business", "politics", "art"].map(option),
            interests: [],
            muted: ["politics"]
        )
        XCTAssertFalse(strip.contains { $0.id == "politics" },
                       "A subject somebody hid must not be one tap from coming back.")
    }

    func testRowsWithNoIdAreDropped() {
        let strip = SubjectOrder.strip(topics: [TopicOption(id: "", detail: "")], interests: [], muted: [])
        XCTAssertTrue(strip.isEmpty)
    }

    // MARK: - Loading the vocabulary

    func testStripLoadsOnce() async {
        let viewModel = makeViewModel(subjects: catalog(["art", "science"], interests: ["science"]))
        await viewModel.loadSubjectsIfNeeded()
        XCTAssertEqual(viewModel.subjects.map(\.id), ["science", "art"])
    }

    func testAFailedVocabularyLeavesTheTimelineAlone() async {
        let viewModel = makeViewModel(
            subjects: StubSubjects(catalog: SubjectCatalog(), error: APIError.transport("offline"))
        )
        await viewModel.loadSubjectsIfNeeded()
        XCTAssertTrue(viewModel.subjects.isEmpty, "No vocabulary means no strip.")
        XCTAssertNil(viewModel.toast, "The strip failing is not worth interrupting reading for.")
    }

    // MARK: - Pinning

    func testPinningASubjectNarrowsEveryTab() async {
        let service = FeedServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)
        await viewModel.loadIfNeeded(.forYou)
        XCTAssertTrue(viewModel.state(for: .forYou).isPopulated)

        await viewModel.pin("sila")

        let lastTopics = await service.lastTopics
        XCTAssertEqual(lastTopics, ["sila"])
        // Everything loaded under the old subject is gone, on every tab.
        for tab in FeedTab.allCases where tab != viewModel.selectedTab {
            XCTAssertFalse(viewModel.state(for: tab).hasLoaded,
                           "\(tab) still holds a page chosen under the previous subject.")
        }
    }

    func testTappingThePinnedSubjectAgainShowsEverything() async {
        let viewModel = makeViewModel()
        await viewModel.pin("sila")
        await viewModel.pin("sila")
        XCTAssertTrue(viewModel.pinnedSubjects.isEmpty)
        XCTAssertTrue(viewModel.state(for: .forYou).isPopulated,
                      "Clearing the subject has to bring the whole timeline back.")
    }

    func testThePinnedSubjectSurvivesRelaunch() async {
        let storage = InMemoryStorageClient()
        let first = makeViewModel(storage: storage)
        await first.pin("riyadh")

        let second = makeViewModel(service: FeedServiceMock(scenario: .populated), storage: storage)
        XCTAssertEqual(second.pinnedSubjects, ["riyadh"],
                       "A subject somebody pinned must still be pinned when they come back.")
    }

    func testClearingTheSubjectForgetsIt() async {
        let storage = InMemoryStorageClient()
        let viewModel = makeViewModel(storage: storage)
        await viewModel.pin("riyadh")
        await viewModel.pin(nil)
        XCTAssertNil(storage.value(for: .pinnedSubject, as: [String].self))
    }

    // MARK: - Two at once

    func testTwoSubjectsMeanBothConversations() async {
        let service = FeedServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service)

        await viewModel.pin("sila")
        await viewModel.pin("riyadh")

        let lastTopics = await service.lastTopics
        XCTAssertEqual(lastTopics, ["sila", "riyadh"],
                       "Tapping a second subject must add it, not replace the first.")
        XCTAssertEqual(viewModel.pinnedSubjects, ["sila", "riyadh"])
    }

    func testTappingAPinnedSubjectTakesOnlyThatOneOut() async {
        let viewModel = makeViewModel()
        await viewModel.pin("sila")
        await viewModel.pin("riyadh")

        await viewModel.pin("sila")

        XCTAssertEqual(viewModel.pinnedSubjects, ["riyadh"],
                       "Unpinning one subject must leave the other alone.")
    }

    func testThereIsALimitAndItIsSaidOutLoud() async {
        let viewModel = makeViewModel()
        for index in 0..<HomeViewModel.maximumPinnedSubjects {
            await viewModel.pin("subject\(index)")
        }
        XCTAssertNil(viewModel.toast)

        await viewModel.pin("one-too-many")

        XCTAssertEqual(viewModel.pinnedSubjects.count, HomeViewModel.maximumPinnedSubjects)
        XCTAssertNotNil(viewModel.toast, "A chip that silently does nothing reads as broken.")
    }

    func testAllOfThemSurviveRelaunch() async {
        let storage = InMemoryStorageClient()
        let first = makeViewModel(storage: storage)
        await first.pin("sila")
        await first.pin("riyadh")

        let second = makeViewModel(service: FeedServiceMock(scenario: .populated), storage: storage)
        XCTAssertEqual(second.pinnedSubjects, ["sila", "riyadh"])
    }

    func testASingleRememberedSubjectFromAnOlderBuildStillReads() async {
        let storage = InMemoryStorageClient()
        // What the previous build wrote: one id, not a list.
        storage.set("riyadh", for: .pinnedSubject)

        let viewModel = makeViewModel(storage: storage)

        XCTAssertEqual(viewModel.pinnedSubjects, ["riyadh"],
                       "An update must not silently drop the subject somebody was reading.")
    }

    func testTheFirstPageIsAlreadyNarrowed() async {
        let storage = InMemoryStorageClient()
        storage.set("sila", for: .pinnedSubject)
        let service = FeedServiceMock(scenario: .populated)
        let viewModel = makeViewModel(service: service, storage: storage)

        await viewModel.loadIfNeeded(.forYou)

        let lastTopics = await service.lastTopics
        XCTAssertEqual(lastTopics, ["sila"],
                       "A remembered subject must apply to the very first request, not after a flash of everything.")
    }

    // MARK: - When the subject goes away

    func testASubjectHiddenElsewhereIsUnpinned() async {
        let service = FeedServiceMock(scenario: .populated)
        await service.setRefusedTopic("politics")
        let viewModel = makeViewModel(service: service)

        await viewModel.pin("politics")

        XCTAssertTrue(viewModel.pinnedSubjects.isEmpty)
        XCTAssertNotNil(viewModel.toast, "Being given the whole timeline back needs a word of explanation.")
        XCTAssertTrue(viewModel.state(for: .forYou).isPopulated)
    }

    func testAPinnedSubjectMissingFromTheVocabularyIsDropped() async {
        let storage = InMemoryStorageClient()
        storage.set("politics", for: .pinnedSubject)
        let viewModel = makeViewModel(
            // Hidden since the pin was made, on another device.
            subjects: catalog(["art", "science"], muted: ["politics"]),
            storage: storage
        )
        XCTAssertEqual(viewModel.pinnedSubjects, ["politics"])

        await viewModel.loadSubjectsIfNeeded()

        XCTAssertTrue(viewModel.pinnedSubjects.isEmpty,
                      "The timeline must not stay narrowed by a subject the strip does not show.")
        XCTAssertNil(storage.value(for: .pinnedSubject, as: String.self))
    }

    // MARK: - Empty

    func testAnEmptySubjectNamesItself() async {
        let viewModel = makeViewModel(subjects: catalog(["science"]))
        await viewModel.loadSubjectsIfNeeded()
        await viewModel.pin("science")
        XCTAssertEqual(viewModel.state(for: .forYou).emptyKind, .noPosts)
        XCTAssertEqual(viewModel.pinnedSubjectLabel, "Science")
    }

    // MARK: - Guests

    func testAGuestGetsTheVocabularyAndNoOpinions() async throws {
        let catalog = try await GuestSubjects(StubTopics(topics: ["art", "science"].map(option))).loadSubjects()
        XCTAssertEqual(catalog.topics.count, 2)
        XCTAssertTrue(catalog.interests.isEmpty)
        XCTAssertTrue(catalog.muted.isEmpty, "There is no account yet to have hidden anything.")
    }

    func testAnAccountsOpinionsReachTheStrip() async throws {
        let catalog = try await AccountSubjects(PreferencesServiceMock(scenario: .populated)).loadSubjects()
        XCTAssertFalse(catalog.topics.isEmpty)
        XCTAssertFalse(catalog.interests.isEmpty, "A populated account has chosen subjects.")
    }
}

/// The taxonomy alone, which is all a guest can read.
struct StubTopics: TopicCatalogProviding {
    var topics: [TopicOption]
    func fetchTopics() async throws -> [TopicOption] { topics }
}
