import XCTest
@testable import Sila

/// Drives the deployed notifications API through the app's own decoders.
///
/// The fixture tests agree with the contract by construction; these are the
/// only ones that would notice the server disagreeing — a `kind` this build has
/// never seen, a `post_excerpt` that is null for a reason nobody documented, a
/// count that does not match the rows beside it.
///
/// **Deliberately non-destructive: nothing here marks anything read.**
/// `POST /notifications/read` has no inverse. Marking a live account's
/// notifications read would destroy the one signal saying what its owner has
/// not seen yet, and no API call could put it back — so the write paths are
/// covered against ``NotificationsServiceMock`` in `NotificationsViewModelTests`
/// and `NotificationsServiceTests` instead, where the state is disposable. The
/// read paths are safe to run against the real server precisely because they
/// change nothing.
///
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LiveNotificationsTests: XCTestCase {

    private var token: String?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"], let password = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        token = try await auth.signIn(email: email, password: password).token.accessToken
    }

    private func service() throws -> NotificationsService {
        NotificationsService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func feed() throws -> FeedService {
        FeedService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    // MARK: - Reading the list

    /// The whole page decodes, including every actor. A decode failure here is
    /// an empty tab in production.
    func testTheListDecodes() async throws {
        let page = try await service().fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)

        XCTAssertLessThanOrEqual(page.notifications.count, 20)
        for row in page.notifications {
            XCTAssertFalse(row.actor.handle.isEmpty, "a row arrived with no actor handle")
            XCTAssertFalse(row.sentence.isEmpty)
            XCTAssertFalse(
                row.sentence.lowercased().contains("new notification"),
                "the server sent a kind this build describes generically: \(row.kind.rawValue)"
            )
        }
    }

    /// The kinds the server actually emits must all be ones this build has a
    /// sentence for. An `unknown` here is the early warning that the backend's
    /// vocabulary has moved on.
    func testEveryKindTheServerSendsIsOneThisBuildKnows() async throws {
        let page = try await service().fetchNotifications(cursor: nil, limit: 50, unreadOnly: false)

        let unknown = page.notifications.filter { $0.kind == .unknown }
        XCTAssertTrue(
            unknown.isEmpty,
            "the server is sending \(unknown.count) notification(s) this build cannot name"
        )
    }

    /// A row with a post id and no excerpt is the deleted-post case. It must
    /// stay in the list and it must not claim to be a follow.
    func testDeletedPostRowsSurviveDecoding() async throws {
        let page = try await service().fetchNotifications(cursor: nil, limit: 50, unreadOnly: false)

        for row in page.notifications where row.postWasDeleted {
            XCTAssertNotEqual(row.kind, .follow, "a follow arrived carrying a post id")
            XCTAssertNil(row.postExcerpt)
            XCTAssertTrue(row.kind.isAboutAPost)
        }
        // A follow must never carry a post — that is what makes `post_id == nil`
        // a reliable answer to "what does this row open?".
        XCTAssertTrue(
            page.notifications.filter { $0.kind == .follow }.allSatisfy { $0.postId == nil },
            "a follow arrived with a post id"
        )
    }

    /// The limit the client sends is the limit the server honours — the
    /// clamping is only there to keep a 422 off the screen.
    func testTheServerHonoursTheLimit() async throws {
        let page = try await service().fetchNotifications(cursor: nil, limit: 5, unreadOnly: false)

        XCTAssertLessThanOrEqual(page.notifications.count, 5)
    }

    /// `unread_only=true` really does narrow, rather than being ignored.
    func testTheUnreadFilterIsAppliedServerSide() async throws {
        let unread = try await service().fetchNotifications(cursor: nil, limit: 20, unreadOnly: true)

        XCTAssertTrue(
            unread.notifications.allSatisfy { !$0.read },
            "unread_only returned rows that are already read"
        )
    }

    /// Paging with the server's own cursor returns different rows — the
    /// property the client's appending pager depends on.
    func testASecondPageIsDifferentFromTheFirst() async throws {
        let first = try await service().fetchNotifications(cursor: nil, limit: 5, unreadOnly: false)
        guard let cursor = first.nextCursor else {
            throw XCTSkip("the live account has one page of notifications")
        }

        let second = try await service().fetchNotifications(cursor: cursor, limit: 5, unreadOnly: false)

        let overlap = Set(first.notifications.map(\.id))
            .intersection(Set(second.notifications.map(\.id)))
        XCTAssertTrue(overlap.isEmpty, "the cursor returned rows the first page already had")
    }

    // MARK: - The count

    /// The badge's number and the list's number are the same number, from the
    /// same server. If these two ever disagree, the badge is lying.
    func testTheStandaloneCountAgreesWithThePage() async throws {
        let service = try service()

        let count = try await service.fetchUnreadCount()
        let page = try await service.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)

        XCTAssertGreaterThanOrEqual(count, 0)
        XCTAssertEqual(
            count,
            page.unreadCount,
            "GET /notifications/unread-count and GET /notifications disagree about unread"
        )
    }

    // MARK: - Following a row through

    /// What a row opens has to exist. A post that 404s is the deleted case —
    /// and the client already renders that row without an excerpt, so the two
    /// facts must line up.
    func testAPostRowOpensAPostThatStillExists() async throws {
        let page = try await service().fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        guard let row = page.notifications.first(where: { $0.postId != nil && !$0.postWasDeleted }),
              let postId = row.postId else {
            throw XCTSkip("the live account has no notification about a live post")
        }

        let post = try await feed().fetchPost(postId)

        XCTAssertEqual(post.id, postId)
    }

    // MARK: - Preferences

    /// The five switches ride inside `/me/preferences`, and reading them must
    /// not disturb the feed settings sitting beside them.
    func testTheNotificationSwitchesComeBackWithThePreferences() async throws {
        let preferences = PreferencesService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )

        let stored = try await preferences.fetchPreferences()

        // Nothing is asserted about which are on: this account's owner chose
        // that. What matters is that every kind has an answer rather than a
        // crash, and that the map's default is permissive.
        for kind in NotificationKind.settable {
            _ = stored.notifications.isEnabled(kind)
        }
        XCTAssertTrue(
            NotificationPreferences().isEnabled(.like),
            "an unwritten preference map must not read as silence"
        )
    }
}
