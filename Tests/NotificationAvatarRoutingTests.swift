import XCTest
@testable import Sila

/// The actor's avatar is its own tap target: tapping Noura's face on
/// "Noura liked your post" opens *Noura*, while the rest of the row keeps
/// opening the post — mirroring the post card's author block.
@MainActor
final class NotificationAvatarRoutingTests: XCTestCase {

    private func makeViewModel(
        analytics: RecordingAnalyticsClient = RecordingAnalyticsClient()
    ) -> NotificationsViewModel {
        NotificationsViewModel(
            service: NotificationsServiceMock(scenario: .populated),
            feed: FeedServiceMock(scenario: .populated),
            analytics: analytics
        )
    }

    private func likeNotification(postId: UUID) -> UserNotification {
        UserNotification(
            id: UUID(),
            kind: .like,
            actor: UserSummary(
                id: UUID(),
                handle: "noura",
                displayName: "Noura",
                isVerified: true,
                countryCode: "SA"
            ),
            postId: postId,
            postExcerpt: "The post she liked",
            read: false
        )
    }

    func testAvatarTapRoutesToTheActorsProfileNotThePost() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let notification = likeNotification(postId: UUID())

        let destination = viewModel.openActor(notification)

        XCTAssertEqual(
            destination,
            .profile(handle: "noura"),
            "the face is a question about the person, not about the post"
        )
    }

    func testRowOpenStillLeadsToThePostForPostNotifications() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // A post the feed mock can actually serve, so the fetch resolves.
        let row = likeNotification(postId: FeedServiceMock.internationalRoot.id)

        let rowDestination = await viewModel.open(row)
        let avatarDestination = viewModel.openActor(row)

        guard case .post = rowDestination else {
            return XCTFail("the row's own destination moved: \(String(describing: rowDestination))")
        }
        XCTAssertEqual(
            avatarDestination,
            .profile(handle: "noura"),
            "same row, two targets: the body opens the post, the face opens the person"
        )
    }

    func testAvatarTapDoesNotMarkTheRowRead() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let unreadBefore = viewModel.unreadCount
        guard let row = viewModel.notifications.first(where: { !$0.read }) else {
            return XCTFail("the populated scenario should contain an unread row")
        }

        _ = viewModel.openActor(row)

        XCTAssertEqual(viewModel.unreadCount, unreadBefore, "reading is recorded when the *notification* is opened; a profile visit is not that")
        XCTAssertFalse(
            viewModel.notifications.first(where: { $0.id == row.id })?.read ?? true,
            "the row itself must stay unread"
        )
    }

    func testAvatarTapIsTrackedAsAnActorOpen() async {
        let analytics = RecordingAnalyticsClient()
        let viewModel = makeViewModel(analytics: analytics)
        let notification = likeNotification(postId: UUID())

        _ = viewModel.openActor(notification)

        let record = analytics.recorded.last
        XCTAssertEqual(record?.event, .notificationOpened)
        XCTAssertEqual(record?.properties["target"], "actor")
    }
}
