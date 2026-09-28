import XCTest
@testable import Sila

/// The GIF picker steps aside when the server has no GIF anybody could post
/// (contract v27 §5): no provider key and nothing in the library. Production
/// is exactly that today, so the composer's GIF button and the floating
/// button's GIF option are hidden, and come back once the server offers a
/// provider or a library.
@MainActor
final class GifAvailabilityTests: XCTestCase {

    /// A clock a test moves by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// Answers every GIF route with one refusal.
    private actor RefusingGifService: GifServiceProtocol {
        let error: APIError
        init(_ error: APIError) { self.error = error }
        func trending(country: String?, cursor: String?) async throws -> GifList { throw error }
        func search(_ query: String, country: String?, cursor: String?) async throws -> GifList { throw error }
    }

    private static let unavailable = APIError.api(code: .gifUnavailable, message: "GIFs are unavailable right now", status: 503)

    private func availability(_ service: GifServiceProtocol, clock: Clock = Clock()) -> GifAvailability {
        GifAvailability(service: service, now: { clock.now })
    }

    // MARK: - What counts as something to offer

    func testAProviderOrALibraryIsSomethingToOfferAndNeitherIsNothing() {
        let gif = GifServiceMock.samples[0]
        XCTAssertTrue(GifAvailability.offers(GifList(gifs: [], providerConfigured: true)), "a provider to search")
        XCTAssertTrue(GifAvailability.offers(GifList(gifs: [gif], providerConfigured: false)), "GIFs the library holds")
        XCTAssertTrue(GifAvailability.offers(GifList(gifs: [], sharedHere: [gif], providerConfigured: false)))
        XCTAssertFalse(GifAvailability.offers(GifList(gifs: [], providerConfigured: false)), "production today")
    }

    // MARK: - Asking the server

    func testNoProviderAndNoLibraryHidesTheWaysIn() async {
        let gifs = availability(GifServiceMock(scenario: .empty))
        XCTAssertTrue(gifs.isOffered, "until the server answers, the ways in stay")

        await gifs.check(country: "SA")

        XCTAssertEqual(gifs.offer, .unavailable)
        XCTAssertFalse(gifs.isOffered)
    }

    func testAProviderOrALibraryKeepsThem() async {
        for scenario in [GifServiceMock.MockScenario.populated, .libraryOnly] {
            let gifs = availability(GifServiceMock(scenario: scenario))
            await gifs.check(country: "SA")
            XCTAssertEqual(gifs.offer, .offered, "\(scenario)")
        }
    }

    /// A request that fails says nothing about GIFs.
    func testAFailedRequestDecidesNothing() async {
        let gifs = availability(GifServiceMock(scenario: .offline))
        await gifs.check(country: "SA")
        XCTAssertEqual(gifs.offer, .unknown)
        XCTAssertTrue(gifs.isOffered)
    }

    /// `503 gif_unavailable` is an answer.
    func testTheServerSayingGifsAreUnavailableIsAnAnswer() async {
        let gifs = availability(RefusingGifService(Self.unavailable))
        await gifs.check(country: "SA")
        XCTAssertEqual(gifs.offer, .unavailable)
    }

    func testOneAnswerStandsForTenMinutesAndThenIsAskedAgain() async {
        let service = GifServiceMock(scenario: .empty)
        let clock = Clock()
        let gifs = availability(service, clock: clock)

        await gifs.check(country: "SA")
        clock.now += 9 * 60
        await gifs.check(country: "SA")
        var calls = await service.recordedCalls
        XCTAssertEqual(calls.count, 1, "asked again inside ten minutes")

        // The day a provider is configured, the ways in come back by themselves.
        await service.setScenario(.populated)
        clock.now += 2 * 60
        await gifs.check(country: "SA")
        calls = await service.recordedCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(gifs.offer, .offered)
    }

    func testChecksThatArriveTogetherShareOneRequest() async {
        let service = GifServiceMock(scenario: .empty, latency: 0.1)
        let gifs = availability(service)

        async let first: Void = gifs.check(country: "SA")
        async let second: Void = gifs.check(country: "SA")
        _ = await (first, second)

        let calls = await service.recordedCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(gifs.offer, .unavailable)
    }

    // MARK: - The composer

    private func composer(_ gifs: GifAvailability?, openGifPicker: Bool = false) -> ComposerViewModel {
        ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(countryCode: "SA", isVerified: true),
            composer: ScriptedComposerService(),
            gifs: GifServiceMock(),
            gifAvailability: gifs,
            analytics: RecordingAnalyticsClient(),
            openGifPicker: openGifPicker
        )
    }

    func testTheComposerHidesItsGifButtonOnceTheServerSaysThereIsNothing() async {
        let gifs = availability(GifServiceMock(scenario: .empty))
        let viewModel = composer(gifs)
        XCTAssertTrue(viewModel.offersGifs, "not yet answered: the button stays")

        await gifs.check(country: "SA")

        XCTAssertFalse(viewModel.offersGifs)
        viewModel.openGifPicker()
        XCTAssertFalse(viewModel.isShowingGifPicker, "opened onto nothing")
    }

    /// The floating button's GIF choice opens the composer with the picker
    /// up — but not onto a library the server said is empty.
    func testTheGifChoiceDoesNotOpenAPickerWithNothingInIt() async {
        let gifs = availability(GifServiceMock(scenario: .empty))
        await gifs.check(country: "SA")
        let empty = composer(gifs, openGifPicker: true)
        empty.presentRequestedGifPicker()
        XCTAssertFalse(empty.isShowingGifPicker)

        let offered = availability(GifServiceMock(scenario: .populated))
        await offered.check(country: "SA")
        let viewModel = composer(offered, openGifPicker: true)
        XCTAssertFalse(viewModel.isShowingGifPicker, "not on the first frame, where it could never appear")
        viewModel.presentRequestedGifPicker()
        XCTAssertTrue(viewModel.isShowingGifPicker)
        viewModel.isShowingGifPicker = false
        viewModel.presentRequestedGifPicker()
        XCTAssertFalse(viewModel.isShowingGifPicker, "brought up once, not every time it is asked")
    }

    /// The flag the floating button's GIF choice sets is for that one
    /// composer: the next one, opened with the pencil, opens on the editor.
    func testOnlyTheComposerOpenedForAGifOpensOnThePicker() {
        let router = AppRouter()
        router.openComposerWithGif()
        XCTAssertTrue(router.composerOpensGifPicker)
        router.dismissComposer()
        XCTAssertFalse(router.composerOpensGifPicker)

        router.openComposerWithGif()
        router.openComposer(.newPost)
        XCTAssertFalse(router.composerOpensGifPicker)
    }

    // MARK: - The picker

    func testThePickerSaysGifsAreUnavailableAndTellsTheComposer() async {
        let service = GifServiceMock(scenario: .empty)
        let gifs = availability(service)
        let picker = GifPickerViewModel(service: service, country: "SA", debounce: 0, availability: gifs)

        await picker.load()

        XCTAssertTrue(picker.isUnavailable)
        XCTAssertEqual(gifs.offer, .unavailable, "the picker's answer hides the ways in next time")
    }

    func testAPickerRefusedGifUnavailableSaysSoRatherThanFailing() async {
        let gifs = availability(RefusingGifService(Self.unavailable))
        let picker = GifPickerViewModel(service: RefusingGifService(Self.unavailable), country: "SA", debounce: 0, availability: gifs)

        await picker.load()

        XCTAssertEqual(picker.loadState, .loaded)
        XCTAssertTrue(picker.isUnavailable)
        XCTAssertEqual(gifs.offer, .unavailable)
    }

    /// A search that finds nothing says nothing about the library.
    func testASearchWithNoResultsIsNotUnavailability() async throws {
        let service = GifServiceMock(scenario: .populated)
        let gifs = availability(service)
        let picker = GifPickerViewModel(service: service, country: "SA", debounce: 0, availability: gifs)
        await picker.load()

        picker.updateQuery("nothing matches this", immediately: true)
        for _ in 0..<50 where !picker.gifs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(picker.gifs.isEmpty)
        XCTAssertFalse(picker.isUnavailable)
        XCTAssertEqual(gifs.offer, .offered)
    }

    func testALibraryWithoutAProviderIsStillAPicker() async {
        let service = GifServiceMock(scenario: .libraryOnly)
        let picker = GifPickerViewModel(service: service, country: "SA", debounce: 0, availability: availability(service))
        await picker.load()
        XCTAssertFalse(picker.isUnavailable)
        XCTAssertFalse(picker.gifs.isEmpty)
    }

    // MARK: - Launch arguments

    func testTheMockLibraryCanBeChosenForAJourney() {
        XCTAssertEqual(FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"]).mockGifScenario, .populated)
        XCTAssertEqual(FeatureFlags.resolved(arguments: ["Sila", "-mockAuth", "-mockGifScenario", "empty"]).mockGifScenario, .empty)
        XCTAssertEqual(FeatureFlags.resolved(arguments: ["Sila", "-mockGifScenario", "banana"]).mockGifScenario, .populated)
    }
}
