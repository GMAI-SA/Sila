import XCTest
@testable import Sila

/// ``NotificationsServiceProtocol`` whose every answer the test chooses.
///
/// It also records what was *asked*, which is how the two rules that matter get
/// asserted: that nothing marks anything read by itself, and that the unread
/// number on screen is the one the server sent.
final class ScriptedNotificationsService: NotificationsServiceProtocol, @unchecked Sendable {

    /// Pages answered in order; the last one repeats.
    var pages: [NotificationPage] = [.empty]
    /// What `unread-count` answers.
    var unreadCount = 0
    /// What a mark-read answers.
    var readResult = NotificationReadResult(markedRead: 0, unread: 0)

    /// When set, `fetchNotifications` fails.
    var fetchError: APIError?
    /// When set, both mark-read calls fail.
    var markError: APIError?

    private(set) var fetches: [(cursor: String?, limit: Int, unreadOnly: Bool)] = []
    private(set) var markedIds: [[UUID]] = []
    private(set) var markAllCalls = 0
    private(set) var unreadCountCalls = 0

    /// Every write this double received, so a test can assert on *none*.
    var writeCount: Int { markedIds.count + markAllCalls }

    func fetchNotifications(cursor: String?, limit: Int, unreadOnly: Bool) async throws -> NotificationPage {
        fetches.append((cursor, limit, unreadOnly))
        if let fetchError { throw fetchError }
        return pages.count > 1 ? pages.removeFirst() : (pages.first ?? .empty)
    }

    func fetchUnreadCount() async throws -> Int {
        unreadCountCalls += 1
        if let fetchError { throw fetchError }
        return unreadCount
    }

    func markRead(ids: [UUID]) async throws -> NotificationReadResult {
        markedIds.append(ids)
        if let markError { throw markError }
        return readResult
    }

    func markAllRead() async throws -> NotificationReadResult {
        markAllCalls += 1
        if let markError { throw markError }
        return readResult
    }
}

@MainActor
final class NotificationsViewModelTests: XCTestCase {

    private func makeViewModel(
        _ service: ScriptedNotificationsService,
        feed: FeedServiceProtocol = FeedServiceMock(scenario: .populated)
    ) -> NotificationsViewModel {
        NotificationsViewModel(
            service: service,
            feed: feed,
            analytics: RecordingAnalyticsClient()
        )
    }

    private static func notification(
        _ index: Int,
        kind: NotificationKind = .like,
        postId: UUID? = FeedServiceMock.internationalRoot.id,
        excerpt: String? = "Some post",
        read: Bool = false
    ) -> UserNotification {
        UserNotification(
            id: UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", index))") ?? UUID(),
            kind: kind,
            actor: FeedServiceMock.yuki,
            postId: postId,
            postExcerpt: excerpt,
            read: read,
            createdAt: Date().addingTimeInterval(-Double(index) * 60)
        )
    }

    // MARK: - Loading

    func testLoadPopulatesTheListAndTheCursor() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(
                notifications: [Self.notification(1), Self.notification(2)],
                nextCursor: "opaque-1",
                unreadCount: 2
            )
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.notifications.count, 2)
        XCTAssertEqual(viewModel.cursor, "opaque-1")
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertNil(viewModel.loadError)
        XCTAssertEqual(service.fetches.first?.unreadOnly, false)
    }

    /// **The count comes from the response.** Here the server says nine while
    /// the page holds one unread row — because it can see notifications this
    /// page does not, from accounts the viewer has blocked. The client must not
    /// "correct" it.
    func testTheUnreadCountComesFromTheResponseRatherThanBeingRecounted() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(
                notifications: [
                    Self.notification(1, read: false),
                    Self.notification(2, read: true),
                    Self.notification(3, read: true)
                ],
                nextCursor: nil,
                unreadCount: 9
            )
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.unreadCount, 9)
        XCTAssertEqual(viewModel.notifications.filter { !$0.read }.count, 1)
        XCTAssertEqual(viewModel.unreadSummary, "9 unread")
    }

    /// Opening the tab must not clear anything. There is no endpoint that makes
    /// a notification unread again, so an incidental mark is unrecoverable.
    func testLoadingMarksNothingRead() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: nil, unreadCount: 1)
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.reload(isRefresh: true)

        XCTAssertEqual(service.writeCount, 0, "arriving on the screen marked something read")
        XCTAssertEqual(viewModel.unreadCount, 1)
    }

    func testASecondLoadDoesNothingOnceLoaded() async {
        let service = ScriptedNotificationsService()
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(service.fetches.count, 1)
    }

    func testAFailedLoadOffersItsReasonAndRetries() async {
        let service = ScriptedNotificationsService()
        service.fetchError = .transport("offline")
        let viewModel = makeViewModel(service)

        await viewModel.load()
        XCTAssertNotNil(viewModel.loadError)
        XCTAssertTrue(viewModel.notifications.isEmpty)

        service.fetchError = nil
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: nil, unreadCount: 1)
        ]
        await viewModel.reload()

        XCTAssertNil(viewModel.loadError)
        XCTAssertEqual(viewModel.notifications.count, 1)
    }

    // MARK: - Pagination

    /// The second page is **appended**. A pager that replaced would look like a
    /// list that keeps forgetting where somebody was.
    func testLoadingMoreAppendsRatherThanReplaces() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(
                notifications: [Self.notification(1), Self.notification(2)],
                nextCursor: "opaque-1",
                unreadCount: 5
            ),
            NotificationPage(
                notifications: [Self.notification(3), Self.notification(4)],
                nextCursor: nil,
                unreadCount: 5
            )
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.notifications.count, 4)
        XCTAssertEqual(
            viewModel.notifications.map(\.id),
            [Self.notification(1).id, Self.notification(2).id,
             Self.notification(3).id, Self.notification(4).id]
        )
        XCTAssertEqual(service.fetches.map(\.cursor), [nil, "opaque-1"])
        XCTAssertFalse(viewModel.hasMore)
    }

    /// Something read on another device shifts the window and can repeat a row
    /// across two pages, which would break the list's id uniqueness.
    func testARepeatedRowIsNotAppendedTwice() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: "opaque-1", unreadCount: 1),
            NotificationPage(
                notifications: [Self.notification(1), Self.notification(2)],
                nextCursor: nil,
                unreadCount: 1
            )
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.notifications.count, 2)
        XCTAssertEqual(Set(viewModel.notifications.map(\.id)).count, 2)
    }

    func testLoadingMoreDoesNothingWithoutACursor() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: nil, unreadCount: 0)
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(service.fetches.count, 1)
    }

    /// A later page carries a fresher count, and it wins for the same reason
    /// the first one did.
    func testALaterPageUpdatesTheCountFromItsOwnResponse() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: "opaque-1", unreadCount: 5),
            NotificationPage(notifications: [Self.notification(2)], nextCursor: nil, unreadCount: 4)
        ]
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.unreadCount, 4)
    }

    /// A failing page stops the pager rather than hammering it on every scroll.
    func testAFailedPageStopsThePagerAndSaysSo() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: "opaque-1", unreadCount: 1)
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        service.fetchError = .transport("offline")
        await viewModel.loadMore()

        XCTAssertFalse(viewModel.hasMore)
        XCTAssertNotNil(viewModel.toast)
        XCTAssertEqual(viewModel.notifications.count, 1, "the page in hand was thrown away")
    }

    // MARK: - Filtering

    func testTheUnreadFilterAsksTheServerRatherThanFilteringLocally() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(
                notifications: [Self.notification(1), Self.notification(2, read: true)],
                nextCursor: nil,
                unreadCount: 1
            )
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.setFilter(.unread)

        XCTAssertEqual(service.fetches.count, 2)
        XCTAssertEqual(service.fetches.last?.unreadOnly, true)
        XCTAssertEqual(service.fetches.last?.cursor, nil, "the unread list started from the old cursor")
    }

    // MARK: - Marking read

    /// The explicit control, and the only thing that clears the list.
    func testMarkAllReadAdoptsTheServersCountAndFlipsTheRows() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(
                notifications: [Self.notification(1), Self.notification(2)],
                nextCursor: nil,
                unreadCount: 2
            )
        ]
        service.readResult = NotificationReadResult(markedRead: 2, unread: 0)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.markAllRead()

        XCTAssertEqual(service.markAllCalls, 1)
        XCTAssertEqual(viewModel.unreadCount, 0)
        XCTAssertTrue(viewModel.notifications.allSatisfy(\.read))
        XCTAssertFalse(viewModel.canMarkAllRead)
    }

    /// The number afterwards is the server's `unread`, not zero — if the two
    /// ever stop agreeing, the screen shows what is true.
    func testMarkAllReadTrustsTheServersRemainingCount() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: nil, unreadCount: 4)
        ]
        service.readResult = NotificationReadResult(markedRead: 3, unread: 1)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.markAllRead()

        XCTAssertEqual(viewModel.unreadCount, 1)
    }

    func testMarkAllReadDoesNothingWithNothingUnread() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(
                notifications: [Self.notification(1, read: true)],
                nextCursor: nil,
                unreadCount: 0
            )
        ]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.markAllRead()

        XCTAssertEqual(service.markAllCalls, 0)
    }

    func testAFailedMarkAllLeavesTheRowsAloneAndSaysSo() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: nil, unreadCount: 1)
        ]
        service.markError = .api(code: .rateLimited, message: "Too many", status: 429)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.markAllRead()

        XCTAssertEqual(viewModel.unreadCount, 1)
        XCTAssertFalse(viewModel.notifications[0].read)
        XCTAssertNotNil(viewModel.toast)
    }

    // MARK: - Opening a row

    /// A post row opens that post — which means fetching it, because the route
    /// carries a whole ``Post``.
    func testAPostRowOpensThePostAndMarksThatRowRead() async {
        let service = ScriptedNotificationsService()
        let row = Self.notification(1, kind: .reply)
        service.pages = [NotificationPage(notifications: [row], nextCursor: nil, unreadCount: 1)]
        service.readResult = NotificationReadResult(markedRead: 1, unread: 0)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        let destination = await viewModel.open(row)

        guard case let .post(post) = destination else {
            return XCTFail("a reply row did not open a post: \(String(describing: destination))")
        }
        XCTAssertEqual(post.id, FeedServiceMock.internationalRoot.id)
        XCTAssertEqual(service.markedIds, [[row.id]])
        XCTAssertEqual(viewModel.unreadCount, 0)
        XCTAssertTrue(viewModel.notifications[0].read)
    }

    /// A follow row opens the person. Nothing is fetched — there is nothing to
    /// fetch, and a spinner in front of a profile push would be theatre.
    func testAFollowRowOpensTheActorsProfile() async {
        let service = ScriptedNotificationsService()
        let row = Self.notification(1, kind: .follow, postId: nil, excerpt: nil)
        service.pages = [NotificationPage(notifications: [row], nextCursor: nil, unreadCount: 1)]
        service.readResult = NotificationReadResult(markedRead: 1, unread: 0)
        let viewModel = makeViewModel(service)
        await viewModel.load()

        let destination = await viewModel.open(row)

        XCTAssertEqual(destination, .profile(handle: FeedServiceMock.yuki.handle))
        XCTAssertEqual(service.markedIds, [[row.id]])
    }

    /// The deleted-post row is still tappable, and the tap says plainly that
    /// the post is gone rather than doing nothing at all.
    func testADeletedPostRowSaysSoAndOpensNothing() async {
        let service = ScriptedNotificationsService()
        let missing = UUID(uuidString: "99999999-0000-4000-8000-000000000099") ?? UUID()
        let row = Self.notification(1, kind: .mention, postId: missing, excerpt: nil)
        service.pages = [NotificationPage(notifications: [row], nextCursor: nil, unreadCount: 1)]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        let destination = await viewModel.open(row)

        XCTAssertNil(destination)
        XCTAssertNotNil(viewModel.toast)
        XCTAssertEqual(service.markedIds, [], "a row nobody could open was marked read anyway")
        XCTAssertEqual(viewModel.unreadCount, 1)
        XCTAssertEqual(viewModel.notifications.count, 1, "the row disappeared when it failed to open")
    }

    /// A row already read costs no write.
    func testOpeningAnAlreadyReadRowWritesNothing() async {
        let service = ScriptedNotificationsService()
        let row = Self.notification(1, kind: .follow, postId: nil, excerpt: nil, read: true)
        service.pages = [NotificationPage(notifications: [row], nextCursor: nil, unreadCount: 0)]
        let viewModel = makeViewModel(service)
        await viewModel.load()

        _ = await viewModel.open(row)

        XCTAssertEqual(service.writeCount, 0)
    }

    /// A read receipt that never reached the server must not be drawn as though
    /// it had — the row stays unread, which is what the server still holds.
    func testAFailedSingleReadLeavesTheRowUnread() async {
        let service = ScriptedNotificationsService()
        let row = Self.notification(1, kind: .follow, postId: nil, excerpt: nil)
        service.pages = [NotificationPage(notifications: [row], nextCursor: nil, unreadCount: 1)]
        service.markError = .transport("offline")
        let viewModel = makeViewModel(service)
        await viewModel.load()

        let destination = await viewModel.open(row)

        XCTAssertEqual(destination, .profile(handle: FeedServiceMock.yuki.handle))
        XCTAssertFalse(viewModel.notifications[0].read)
        XCTAssertEqual(viewModel.unreadCount, 1)
    }

    // MARK: - The badge

    /// The badge refresh reads the count and nothing else — it is called for a
    /// tab nobody is looking at, so it must not disturb the list.
    func testRefreshingTheBadgeTouchesNothingElse() async {
        let service = ScriptedNotificationsService()
        service.pages = [
            NotificationPage(notifications: [Self.notification(1)], nextCursor: nil, unreadCount: 1)
        ]
        service.unreadCount = 6
        let viewModel = makeViewModel(service)
        await viewModel.load()

        await viewModel.refreshUnreadCount()

        XCTAssertEqual(viewModel.unreadCount, 6)
        XCTAssertEqual(viewModel.notifications.count, 1)
        XCTAssertEqual(service.fetches.count, 1, "the badge refresh reloaded the list")
        XCTAssertEqual(service.writeCount, 0)
    }

    /// A badge is not worth an error banner in front of somebody who asked for
    /// nothing.
    func testAFailedBadgeRefreshIsSilent() async {
        let service = ScriptedNotificationsService()
        service.fetchError = .transport("offline")
        let viewModel = makeViewModel(service)

        await viewModel.refreshUnreadCount()

        XCTAssertNil(viewModel.toast)
        XCTAssertNil(viewModel.loadError)
    }

    // MARK: - Empty

    func testAnEmptyListIsEmptyRatherThanBroken() async {
        let service = ScriptedNotificationsService()
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertNil(viewModel.loadError)
        XCTAssertEqual(viewModel.unreadSummary, "Nothing unread")
    }
}

@MainActor
final class NotificationSettingsViewModelTests: XCTestCase {

    func testLoadReadsTheStoredMap() async {
        let viewModel = NotificationSettingsViewModel(
            service: PreferencesServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.loadError)
        XCTAssertFalse(viewModel.preferences.isEnabled(.like), "the mocked account has likes silenced")
        XCTAssertTrue(viewModel.preferences.isEnabled(.reply))
    }

    /// A switch saves itself, immediately, and the whole map goes with it —
    /// `PUT /me/preferences` replaces the object it is given.
    func testFlippingASwitchWritesTheWholeMap() async {
        let service = PreferencesServiceMock(scenario: .populated)
        let viewModel = NotificationSettingsViewModel(
            service: service,
            analytics: RecordingAnalyticsClient()
        )
        await viewModel.load()

        await viewModel.setEnabled(false, for: .repost)

        let updates = await service.receivedUpdates
        let body = updates.last?.notifications
        XCTAssertEqual(body?["repost"], false)
        XCTAssertEqual(body?["like"], false, "the existing silence was dropped by the write")
        XCTAssertEqual(body?["reply"], true)
        XCTAssertFalse(viewModel.preferences.isEnabled(.repost))
    }

    /// The stored state is re-read from the response, so a switch never claims
    /// something the server did not confirm.
    func testTheSwitchAdoptsTheStoredAnswer() async {
        let service = PreferencesServiceMock(scenario: .populated)
        let viewModel = NotificationSettingsViewModel(
            service: service,
            analytics: RecordingAnalyticsClient()
        )
        await viewModel.load()

        await viewModel.setEnabled(true, for: .like)

        let stored = try? await service.fetchPreferences()
        XCTAssertEqual(stored?.notifications.isEnabled(.like), true)
        XCTAssertTrue(viewModel.preferences.isEnabled(.like))
    }

    /// A refused write springs the switch back. A control that stayed where it
    /// was left would be telling somebody their likes are silenced when they
    /// are not.
    func testARefusedWriteRestoresTheSwitch() async {
        let service = PreferencesServiceMock(scenario: .saveFails)
        let viewModel = NotificationSettingsViewModel(
            service: service,
            analytics: RecordingAnalyticsClient()
        )
        await viewModel.load()
        let before = viewModel.preferences.isEnabled(.mention)

        await viewModel.setEnabled(!before, for: .mention)

        XCTAssertEqual(viewModel.preferences.isEnabled(.mention), before)
        XCTAssertNotNil(viewModel.toast)
    }

    func testAFailedLoadOffersItsReason() async {
        let viewModel = NotificationSettingsViewModel(
            service: PreferencesServiceMock(scenario: .offline),
            analytics: RecordingAnalyticsClient()
        )

        await viewModel.load()

        XCTAssertNotNil(viewModel.loadError)
    }
}
