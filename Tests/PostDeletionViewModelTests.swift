import XCTest
@testable import Sila

/// Deleting your own post.
///
/// The rules that matter are about *whose* post it is and how much intent the
/// action takes — a mistaken delete cannot be undone, because the server has
/// no undo for it.
@MainActor
final class PostDeletionViewModelTests: XCTestCase {

    private func makeModel(
        handle: String? = "aziz",
        scenario: FeedServiceMock.MockScenario = .populated
    ) -> (PostDeletionViewModel, FeedServiceMock, RecordingAnalyticsClient) {
        let service = FeedServiceMock(scenario: scenario)
        let analytics = RecordingAnalyticsClient()
        return (
            PostDeletionViewModel(service: service, analytics: analytics, viewerHandle: handle),
            service,
            analytics
        )
    }

    private func post(by author: UserSummary) -> Post {
        Post(
            id: UUID(),
            author: author,
            text: "a post",
            createdAt: Date(),
            scope: .international,
            scopeCountry: nil,
            scopeRegion: nil,
            metrics: PostMetrics(likes: 0, reposts: 0, replies: 0, views: 0, bookmarks: 0),
            viewer: PostViewerState()
        )
    }

    // MARK: - Whose post it is

    func testDeleteIsOfferedOnYourOwnPost() {
        let (model, _, _) = makeModel(handle: "aziz")
        XCTAssertNotNil(model.actions(for: post(by: FeedServiceMock.aziz)))
    }

    func testDeleteIsNotOfferedOnSomebodyElsesPost() {
        let (model, _, _) = makeModel(handle: "aziz")
        XCTAssertNil(
            model.actions(for: post(by: FeedServiceMock.yuki)),
            "offering Delete on another person's post would 403 and look like a bug"
        )
    }

    /// The safe direction: with no known viewer, offer nothing rather than
    /// guess and show a control that cannot work.
    func testNothingIsOfferedWhenTheViewerIsUnknown() {
        let (model, _, _) = makeModel(handle: nil)
        XCTAssertNil(model.actions(for: post(by: FeedServiceMock.aziz)))
    }

    func testTheHandleComparisonIgnoresCaseAndAtSign() {
        let (model, _, _) = makeModel(handle: "@AZIZ")
        XCTAssertTrue(model.isMine(post(by: FeedServiceMock.aziz)))
    }

    // MARK: - Confirmation

    /// Deletion is irreversible and removes the post from every feed, thread
    /// and search result. One tap is the wrong amount of intent.
    func testTappingDeleteOnlyOpensTheConfirmation() async {
        let (model, service, _) = makeModel()
        let mine = post(by: FeedServiceMock.aziz)

        model.actions(for: mine)?.onDelete()

        let calls = await service.recordedCalls
        XCTAssertEqual(model.pending?.id, mine.id)
        XCTAssertFalse(calls.contains("deletePost"), "the post was deleted without confirming")
        XCTAssertTrue(model.deleted.isEmpty)
    }

    func testCancellingLeavesThePostAlone() async {
        let (model, service, _) = makeModel()
        model.actions(for: post(by: FeedServiceMock.aziz))?.onDelete()

        model.cancel()

        let calls = await service.recordedCalls
        XCTAssertNil(model.pending)
        XCTAssertFalse(calls.contains("deletePost"))
    }

    func testConfirmingDeletesAndRecordsIt() async {
        let (model, service, analytics) = makeModel()
        let mine = post(by: FeedServiceMock.aziz)
        model.actions(for: mine)?.onDelete()

        let ok = await model.confirm()

        let calls = await service.recordedCalls
        XCTAssertTrue(ok)
        XCTAssertTrue(calls.contains("deletePost"))
        XCTAssertTrue(model.isDeleted(mine), "every list needs to know it is gone")
        XCTAssertNil(model.pending)
        XCTAssertNil(model.error)
        XCTAssertTrue(analytics.events.contains(.postDeleted))
    }

    func testConfirmingWithNothingPendingDoesNothing() async {
        let (model, service, _) = makeModel()
        let ok = await model.confirm()
        let calls = await service.recordedCalls
        XCTAssertFalse(ok)
        XCTAssertFalse(calls.contains("deletePost"))
    }

    // MARK: - Failure

    /// A failed delete must not mark the post gone locally: the list would hide
    /// a post that is still live, and it would reappear on the next refresh.
    func testAFailedDeleteKeepsThePostAndExplainsWhy() async {
        let (model, _, _) = makeModel(scenario: .offline)
        let mine = post(by: FeedServiceMock.aziz)
        model.actions(for: mine)?.onDelete()

        let ok = await model.confirm()

        XCTAssertFalse(ok)
        XCTAssertFalse(model.isDeleted(mine))
        XCTAssertNotNil(model.error)

        model.clearError()
        XCTAssertNil(model.error)
    }
}
