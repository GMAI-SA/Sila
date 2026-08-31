import Foundation

/// Scripted ``NotificationsServiceProtocol`` for tests, previews and the
/// `-mockNotifications` launch argument.
///
/// It behaves like the server rather than saying yes to everything: reads
/// mutate stored rows, and the unread count it returns is always recomputed
/// from those rows. That is what makes it a useful stand-in for the one rule
/// this surface has to hold — the badge and the list agree because both come
/// from the same place.
///
/// The cast is ``FeedServiceMock``'s, and the post ids are its posts, so a
/// notification tapped in a mocked build opens a thread that actually exists.
/// One row deliberately points at a post that does **not**: that is the
/// deleted-post case, and it is the only way to see what the client does when
/// `post_excerpt` is `null` while `post_id` is not.
public actor NotificationsServiceMock: NotificationsServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Six notifications covering all five kinds, three unread, one of them
        /// about a post that has been deleted.
        case populated
        /// A brand-new account: nothing has happened yet.
        case empty
        /// Everything already read — the "all caught up" state.
        case allRead
        /// Enough rows to page twice, so the pager can be exercised.
        case paged
        /// Every call fails with a transport error.
        case offline
        /// Reads fine; every write is throttled with `429`.
        case markFails
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    private let latency: Double

    /// The stored rows, newest first. Mutated by an accepted mark-read.
    private var stored: [UserNotification]

    /// Calls recorded for test assertions, e.g. `"markRead:2"`.
    public private(set) var recordedCalls: [String] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay. Tests pass `0`.
    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
        switch scenario {
        case .empty, .offline:
            stored = []
        case .allRead:
            stored = Self.cast.map { row in
                var copy = row
                copy.read = true
                return copy
            }
        case .paged:
            stored = Self.manyRows
        case .populated, .markFails:
            stored = Self.cast
        }
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - NotificationsServiceProtocol

    public func fetchNotifications(
        cursor: String?,
        limit: Int,
        unreadOnly: Bool
    ) async throws -> NotificationPage {
        recordedCalls.append("fetch:\(cursor ?? "first"):\(unreadOnly ? "unread" : "all")")
        try await delay()
        try failIfOffline()

        let rows = unreadOnly ? stored.filter { !$0.read } : stored
        let size = min(max(limit, 1), NotificationConstants.maximumPageSize)
        let start = cursor.flatMap { Int($0) } ?? 0
        guard start < rows.count else {
            return NotificationPage(notifications: [], nextCursor: nil, unreadCount: unread)
        }
        let end = min(start + size, rows.count)
        // The cursor is an offset here only because the mock needs *a* cursor;
        // it is opaque to the client either way, exactly like the server's.
        return NotificationPage(
            notifications: Array(rows[start..<end]),
            nextCursor: end < rows.count ? String(end) : nil,
            unreadCount: unread
        )
    }

    public func fetchUnreadCount() async throws -> Int {
        recordedCalls.append("unreadCount")
        try await delay()
        try failIfOffline()
        return unread
    }

    public func markRead(ids: [UUID]) async throws -> NotificationReadResult {
        recordedCalls.append("markRead:\(ids.count)")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        let targets = Set(ids)
        var marked = 0
        for index in stored.indices where targets.contains(stored[index].id) && !stored[index].read {
            stored[index].read = true
            marked += 1
        }
        return NotificationReadResult(markedRead: marked, unread: unread)
    }

    public func markAllRead() async throws -> NotificationReadResult {
        recordedCalls.append("markAllRead")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        var marked = 0
        for index in stored.indices where !stored[index].read {
            stored[index].read = true
            marked += 1
        }
        return NotificationReadResult(markedRead: marked, unread: 0)
    }

    // MARK: - Fixture world

    private var unread: Int { stored.filter { !$0.read }.count }

    private static func id(_ suffix: Int) -> UUID {
        let padded = String(format: "%012d", suffix)
        return UUID(uuidString: "00000000-0000-4000-8000-\(padded)") ?? UUID()
    }

    private static func minutesAgo(_ minutes: Double) -> Date {
        Date().addingTimeInterval(-minutes * 60)
    }

    /// The post ``FeedServiceMock`` serves as the viewer's own thread.
    static let ownPostId = id(1)
    /// A post id nothing resolves — the deleted one.
    static let deletedPostId = id(9_001)

    /// All five kinds, plus the deleted-post case.
    static let cast: [UserNotification] = [
        UserNotification(
            id: id(201), kind: .reply, actor: FeedServiceMock.yuki,
            postId: ownPostId,
            postExcerpt: "Depends on the country. In Japan the hard part isn't identity, it's the paperwork around it.",
            read: false, createdAt: minutesAgo(4)
        ),
        UserNotification(
            id: id(202), kind: .like, actor: FeedServiceMock.noor,
            postId: ownPostId,
            postExcerpt: "What's the single biggest change identity verification will bring to social media?",
            read: false, createdAt: minutesAgo(26)
        ),
        UserNotification(
            id: id(203), kind: .follow, actor: FeedServiceMock.maria,
            postId: nil, postExcerpt: nil,
            read: false, createdAt: minutesAgo(90)
        ),
        // The row this whole feature's second rule is about: there is a post,
        // and there is no excerpt, because the post is gone.
        UserNotification(
            id: id(204), kind: .mention, actor: FeedServiceMock.pending,
            postId: deletedPostId, postExcerpt: nil,
            read: true, createdAt: minutesAgo(180)
        ),
        UserNotification(
            id: id(205), kind: .repost, actor: FeedServiceMock.maria,
            postId: ownPostId,
            postExcerpt: "What's the single biggest change identity verification will bring to social media?",
            read: true, createdAt: minutesAgo(300)
        ),
        UserNotification(
            id: id(206), kind: .follow, actor: FeedServiceMock.yuki,
            postId: nil, postExcerpt: nil,
            read: true, createdAt: minutesAgo(60 * 26)
        )
    ]

    /// Twenty-five rows, so ``MockScenario/paged`` needs two pages.
    static let manyRows: [UserNotification] = makeManyRows()

    private static func makeManyRows() -> [UserNotification] {
        let cast: [UserSummary] = [FeedServiceMock.yuki, FeedServiceMock.maria, FeedServiceMock.noor]
        var rows: [UserNotification] = []
        for index in 0..<25 {
            let kind: NotificationKind = NotificationKind.settable[index % 5]
            let isFollow: Bool = kind == .follow
            let excerpt: String? = isFollow ? nil : "A post of yours, number \(index)."
            let minutes: Double = Double(index) * 17 + 3
            rows.append(
                UserNotification(
                    id: id(300 + index),
                    kind: kind,
                    actor: cast[index % 3],
                    postId: isFollow ? nil : ownPostId,
                    postExcerpt: excerpt,
                    read: index >= 6,
                    createdAt: minutesAgo(minutes)
                )
            )
        }
        return rows
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }

    private func failIfWritesFail() throws {
        if scenario == .markFails {
            throw APIError.api(code: .rateLimited, message: "Too many requests", status: 429)
        }
    }
}
