import XCTest
@testable import Sila

/// A cancelled load changes nothing.
///
/// SwiftUI cancels a screen's task whenever the screen goes away or its
/// parent rebuilds it, and runs the task again on the next appearance. The
/// first fix for "Network problem: cancelled" silenced the message; these
/// are the cases where silence alone left a spinner up, a pager dead, or a
/// list wiped — and the next appearance found a guard that said "already
/// loading" and did nothing.
final class CancelledLoadTests: XCTestCase {

    // MARK: Home

    @MainActor
    func testACancelledFirstLoadIsAskedForAgainOnTheNextAppearance() async {
        let service = ScriptedFeedService()
        service.feedError = .cancelled
        let viewModel = HomeViewModel(service: service, analytics: RecordingAnalyticsClient())

        await viewModel.loadIfNeeded(.forYou)
        let state = viewModel.state(for: .forYou)
        XCTAssertFalse(state.hasLoaded, "cut short is not loaded")
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.emptyKind, "and it is not a failure either")
        XCTAssertNil(viewModel.toast)

        service.feedError = nil
        service.pages[.forYou] = [FeedPage(posts: [FeedServiceMock.internationalRoot])]
        await viewModel.loadIfNeeded(.forYou)
        XCTAssertTrue(viewModel.state(for: .forYou).hasLoaded)
        XCTAssertEqual(viewModel.state(for: .forYou).posts.count, 1, "the second appearance fetched")
    }

    @MainActor
    func testACancelledPageDoesNotEndTheFeed() async {
        let service = ScriptedFeedService()
        service.pages[.forYou] = [FeedPage(posts: [FeedServiceMock.internationalRoot], nextCursor: "c2", hasMore: true)]
        let viewModel = HomeViewModel(service: service, analytics: RecordingAnalyticsClient())
        await viewModel.loadIfNeeded(.forYou)
        XCTAssertTrue(viewModel.state(for: .forYou).hasMore)

        service.feedError = .cancelled
        await viewModel.loadMore(.forYou)
        XCTAssertTrue(viewModel.state(for: .forYou).hasMore, "the row that asked scrolled away; the next row asks again")
        XCTAssertFalse(viewModel.state(for: .forYou).isLoadingMore)
        XCTAssertNil(viewModel.toast)

        service.feedError = .transport("no network")
        await viewModel.loadMore(.forYou)
        XCTAssertFalse(viewModel.state(for: .forYou).hasMore, "a real failure still stops the pager")
    }

    // MARK: Saved posts

    @MainActor
    func testACancelledSavedPostsLoadLeavesTheScreenReadyToLoad() async {
        let service = ScriptedFeedService()
        service.feedError = .cancelled
        let viewModel = SavedPostsViewModel(service: service, analytics: RecordingAnalyticsClient())
        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .idle)
        XCTAssertNil(viewModel.toast)

        service.feedError = nil
        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .loaded, "the guard let the second appearance through")
    }

    // MARK: Notifications

    @MainActor
    func testACancelledNotificationsLoadIsNotAnEmptyList() async {
        let service = ScriptedNotificationsService()
        service.fetchError = .cancelled
        let viewModel = NotificationsViewModel(service: service, feed: ScriptedFeedService(), analytics: RecordingAnalyticsClient())
        await viewModel.load()
        XCTAssertFalse(viewModel.hasLoaded, "cut short is not loaded, so no empty state is drawn")
        XCTAssertNil(viewModel.loadError)
        XCTAssertFalse(viewModel.isLoading)

        service.fetchError = nil
        await viewModel.load()
        XCTAssertTrue(viewModel.hasLoaded, "the next appearance fetched")
    }

    // MARK: GIF picker

    @MainActor
    func testACancelledPickerLoadIsAskedForAgain() async {
        let service = GifServiceMock(scenario: .offline)
        let viewModel = GifPickerViewModel(service: service, country: "SA", debounce: 0)
        // The offline scenario throws a transport error; a cancellation is
        // the one error the picker must not treat as a failure.
        await viewModel.load()
        if case .failed = viewModel.loadState {} else { XCTFail("a real failure is a failure") }

        let cancelling = CancellingGifService()
        let quiet = GifPickerViewModel(service: cancelling, country: "SA", debounce: 0)
        await quiet.load()
        XCTAssertEqual(quiet.loadState, .idle)
        cancelling.cancel = false
        await quiet.load()
        XCTAssertEqual(quiet.loadState, .loaded)
    }
}

/// A GIF library whose first answer is a cancellation.
private final class CancellingGifService: GifServiceProtocol, @unchecked Sendable {
    var cancel = true
    func trending(country: String?, cursor: String?) async throws -> GifList {
        if cancel { throw APIError.cancelled }
        return GifList(gifs: GifServiceMock.samples, source: "library", providerConfigured: false)
    }
    func search(_ query: String, country: String?, cursor: String?) async throws -> GifList {
        if cancel { throw APIError.cancelled }
        return GifList(gifs: [], source: "library", providerConfigured: false)
    }
}
