import XCTest
@testable import Sila

/// ``CreateRoomViewModel``: the audience rule it reuses rather than reinvents,
/// the taxonomy it reads rather than hard-codes, and the two things it refuses.
@MainActor
final class CreateRoomViewModelTests: XCTestCase {

    private func makeViewModel(
        author: ComposerAuthor,
        service: RoomsServiceProtocol? = nil,
        preferences: PreferencesServiceProtocol? = nil
    ) -> CreateRoomViewModel {
        CreateRoomViewModel(
            author: author,
            service: service ?? RoomsServiceMock(scenario: .populated),
            preferences: preferences ?? PreferencesServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let saudi = ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true)
    private static let japanese = ComposerAuthor(handle: "yuki", countryCode: "JP", isVerified: true)
    private static let unverified = ComposerAuthor(handle: "newcomer", countryCode: nil, isVerified: false)

    // MARK: - Audience

    /// **The scope rule is the composer's, reused.** A country room may only
    /// ever name the author's own verified country — the same rule, from the
    /// same implementation, as a country thread.
    func testTheAudiencePickerIsTheComposersAndNamesOnlyYourOwnCountry() {
        let viewModel = makeViewModel(author: Self.saudi)

        let country = viewModel.scopeOptions.first { option in
            if case .country = option.scope { return true }
            return false
        }
        XCTAssertEqual(country?.scope, .country("SA"))
        XCTAssertEqual(country?.isAvailable, true)
        XCTAssertEqual(
            viewModel.scopeOptions.map(\.id),
            ScopePicker.options(for: Self.saudi).map(\.id),
            "the room picker grew a second implementation of the scope rule"
        )
    }

    /// A region you are not verified inside is **shown and explained**, not
    /// hidden: a blank space teaches nobody what verification buys.
    func testARegionYouAreOutsideIsOfferedAndExplained() throws {
        let viewModel = makeViewModel(author: Self.japanese)

        let gcc = try XCTUnwrap(viewModel.scopeOptions.first { $0.scope == .region(.gcc) })
        XCTAssertFalse(gcc.isAvailable)
        XCTAssertNotNil(gcc.unavailableReason)
        XCTAssertTrue(gcc.unavailableReason?.contains("GCC") == true)
    }

    /// Tapping an unavailable audience says why rather than doing nothing.
    func testSelectingAnUnavailableAudienceExplainsItselfAndChangesNothing() throws {
        let viewModel = makeViewModel(author: Self.japanese)
        let before = viewModel.scope

        let gcc = try XCTUnwrap(viewModel.scopeOptions.first { $0.scope == .region(.gcc) })
        viewModel.select(gcc)

        XCTAssertEqual(viewModel.scope, before, "an unavailable audience was selected anyway")
        XCTAssertEqual(viewModel.toast?.text, gcc.unavailableReason)
    }

    func testTheDefaultAudienceIsTheWidestOne() {
        XCTAssertEqual(makeViewModel(author: Self.saudi).scope, .international)
        XCTAssertEqual(makeViewModel(author: Self.unverified).scope, .international)
    }

    // MARK: - Topics

    /// **The taxonomy comes from the server**, the same `GET /topics` the feed
    /// preferences screen reads. A hard-coded copy goes stale the day the list
    /// moves, and the failure lands as `unknown_topic` on a room somebody just
    /// spent a minute naming.
    func testTheTopicListIsTheServersTwenty() async {
        let viewModel = makeViewModel(author: Self.saudi)
        await viewModel.loadTopics()

        XCTAssertEqual(viewModel.topics.count, 20)
        XCTAssertTrue(viewModel.topics.contains { $0.id == "technology" })
        XCTAssertTrue(viewModel.topics.contains { $0.id == "real_estate" })
        // Labels are derived locally, because the contract does not promise them.
        XCTAssertEqual(viewModel.topics.first { $0.id == "real_estate" }?.label, "Real estate")
    }

    /// A taxonomy that does not arrive costs a picker, never the room. A client
    /// that refused to open one because a list of labels failed would be
    /// inventing a requirement the server does not have.
    func testAFailedTaxonomyStillLetsYouOpenARoom() async {
        let viewModel = makeViewModel(
            author: Self.saudi,
            preferences: PreferencesServiceMock(scenario: .offline)
        )
        viewModel.title = "No topic needed"
        await viewModel.loadTopics()

        XCTAssertTrue(viewModel.topics.isEmpty)
        XCTAssertTrue(viewModel.canCreate)
    }

    func testPickingTheSameTopicTwiceClearsIt() async {
        let viewModel = makeViewModel(author: Self.saudi)
        await viewModel.loadTopics()

        viewModel.select(topic: "science")
        XCTAssertEqual(viewModel.topic, "science")
        viewModel.select(topic: "science")
        XCTAssertNil(viewModel.topic, "a topic could not be unpicked")
    }

    // MARK: - Refusals

    /// Hosting needs verification. **Listening never does** — and the sentence
    /// says both, so nobody reads this as "Sila is closed to me".
    func testAnUnverifiedAccountCannotHostAndIsToldWhy() async {
        let viewModel = makeViewModel(author: Self.unverified)
        viewModel.title = "My first room"

        XCTAssertFalse(viewModel.canHost)
        XCTAssertFalse(viewModel.canCreate)

        let room = await viewModel.create()

        XCTAssertNil(room)
        XCTAssertEqual(viewModel.createError, RoomCopy.unverifiedCannotOpen)
        XCTAssertTrue(viewModel.createError?.lowercased().contains("everyone can listen") == true)
    }

    func testAnEmptyTitleIsRefusedBeforeAnyRequest() async {
        let service = RoomsServiceMock(scenario: .populated)
        let viewModel = makeViewModel(author: Self.saudi, service: service)
        viewModel.title = "   "

        let room = await viewModel.create()

        XCTAssertNil(room)
        XCTAssertEqual(viewModel.titleError, RoomCopy.titleMissing)
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains { $0.hasPrefix("create") }, "an empty title reached the server")
    }

    func testATooLongTitleIsRefusedWithACount() async {
        let viewModel = makeViewModel(author: Self.saudi)
        viewModel.title = String(repeating: "a", count: RoomConstants.maximumTitleLength + 5)

        XCTAssertEqual(viewModel.remainingTitleCharacters, -5)
        XCTAssertFalse(viewModel.canCreate)

        let room = await viewModel.create()
        XCTAssertNil(room)
        XCTAssertNotNil(viewModel.titleError)
    }

    // MARK: - Creating

    func testCreatingOpensALiveRoomHostedByTheAuthor() async throws {
        let viewModel = makeViewModel(author: Self.saudi)
        await viewModel.loadTopics()
        viewModel.title = "  What verification actually changes  "
        viewModel.select(topic: "technology")

        let created = await viewModel.create()

        let room = try XCTUnwrap(created)
        XCTAssertEqual(room.title, "What verification actually changes")
        XCTAssertEqual(room.topic, "technology")
        XCTAssertEqual(room.status, .live)
        XCTAssertTrue(room.isHost)
        XCTAssertTrue(room.canSpeak)
        XCTAssertNil(viewModel.createError)
    }

    /// Scheduling puts it on the list instead of opening it, and the room comes
    /// back `scheduled` rather than `live`.
    func testSchedulingProducesAScheduledRoom() async throws {
        let viewModel = makeViewModel(author: Self.saudi)
        viewModel.title = "Weekly reading group"
        viewModel.isScheduled = true
        viewModel.scheduledFor = Date().addingTimeInterval(3_600)

        let created = await viewModel.create()

        let room = try XCTUnwrap(created)
        XCTAssertEqual(room.status, .scheduled)
        XCTAssertNotNil(room.scheduledFor)
    }

    func testACountryRoomCarriesTheAuthorsOwnCountry() async throws {
        let viewModel = makeViewModel(author: Self.saudi)
        viewModel.title = "Riyadh morning"
        let country = try XCTUnwrap(
            viewModel.scopeOptions.first { $0.scope == .country("SA") }
        )
        viewModel.select(country)

        let created = await viewModel.create()

        let room = try XCTUnwrap(created)
        XCTAssertEqual(room.scope, .country)
        XCTAssertEqual(room.scopeCountry, "SA")
    }

    func testAServerRefusalIsShownRatherThanSwallowed() async {
        let viewModel = makeViewModel(
            author: Self.saudi,
            service: RoomsServiceMock(scenario: .writesFail)
        )
        viewModel.title = "Throttled"

        let room = await viewModel.create()

        XCTAssertNil(room)
        XCTAssertNotNil(viewModel.createError)
    }

    /// The created room is handed to the list behind the sheet, so it is on
    /// screen without waiting for a refresh.
    func testTheCreatedRoomReachesTheListBehindTheSheet() async {
        var delivered: VoiceRoom?
        let viewModel = CreateRoomViewModel(
            author: Self.saudi,
            service: RoomsServiceMock(scenario: .populated),
            preferences: PreferencesServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            onCreated: { delivered = $0 }
        )
        viewModel.title = "Handed over"

        _ = await viewModel.create()

        XCTAssertEqual(delivered?.title, "Handed over")
    }
}
