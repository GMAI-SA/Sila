import XCTest
@testable import Sila

/// The notification payload as the deployed server sends it, through the app's
/// own decoders.
///
/// Two of these are the feature's whole point. **Every kind gets its own
/// sentence**, so a list can be triaged without opening every row. And **a null
/// `post_excerpt` beside a non-null `post_id` is a deleted post, not a
/// malformed row** — it stays in the list, because the thing it describes
/// happened whatever became of the post afterwards.
final class NotificationModelsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static func row(
        kind: String,
        postId: String? = "6f6d1a3e-0000-4000-8000-00000000ab01",
        excerpt: String? = "Some post text",
        read: Bool = false
    ) -> String {
        let post = postId.map { "\"\($0)\"" } ?? "null"
        let text = excerpt.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "11111111-0000-4000-8000-000000000001",
         "kind": "\(kind)",
         "actor": {"id": "22222222-0000-4000-8000-000000000002", "handle": "faisal",
                   "display_name": "Faisal", "avatar_url": null, "is_verified": true,
                   "country_code": "SA", "verified_since": "2026-01-04T09:00:00Z"},
         "post_id": \(post), "post_excerpt": \(text), "read": \(read),
         "created_at": "2026-08-30T12:00:00Z"}
        """
    }

    // MARK: - The five kinds

    /// Each kind decodes, and each one says something different. The assertion
    /// that matters is the *distinctness*: five identical "new notification"
    /// rows would be a list nobody could use.
    func testEveryKindDecodesWithItsOwnSentence() throws {
        let expected: [(String, NotificationKind, String)] = [
            ("follow", .follow, "Faisal followed you"),
            ("like", .like, "Faisal liked your post"),
            ("repost", .repost, "Faisal reposted you"),
            ("reply", .reply, "Faisal replied to you"),
            ("mention", .mention, "Faisal mentioned you")
        ]

        var sentences: Set<String> = []
        for (raw, kind, sentence) in expected {
            let decoded = try decode(
                UserNotification.self,
                Self.row(kind: raw, postId: raw == "follow" ? nil : "6f6d1a3e-0000-4000-8000-00000000ab01")
            )
            XCTAssertEqual(decoded.kind, kind, "\(raw) decoded as \(decoded.kind)")
            XCTAssertEqual(decoded.sentence, sentence)
            XCTAssertFalse(
                decoded.sentence.lowercased().contains("notification"),
                "\(raw) fell back to a generic sentence"
            )
            sentences.insert(decoded.sentence)
        }
        XCTAssertEqual(sentences.count, 5, "two kinds share a sentence")
    }

    /// Icons matter for the same reason the sentences do — the row is scanned
    /// before it is read.
    func testEveryKindHasItsOwnIcon() {
        let icons = Set(NotificationKind.settable.map(\.icon))
        XCTAssertEqual(icons.count, NotificationKind.settable.count)
    }

    /// A kind added to the server after this build shipped must not blank the
    /// page, and must not be described as nothing.
    func testAnUnrecognisedKindStillDecodesAsARow() throws {
        let decoded = try decode(UserNotification.self, Self.row(kind: "quote_boost"))

        XCTAssertEqual(decoded.kind, .unknown)
        XCTAssertTrue(decoded.sentence.contains("Faisal"), "the actor was dropped with the kind")
        XCTAssertFalse(NotificationKind.settable.contains(.unknown), "unknown reached the settings list")
    }

    // MARK: - The deleted post

    /// The behaviour this feature is judged on: `post_excerpt: null` with a
    /// real `post_id` is a post that has been deleted. The row survives, minus
    /// the excerpt.
    func testANullExcerptWithAPostIdIsADeletedPostAndKeepsItsRow() throws {
        let decoded = try decode(UserNotification.self, Self.row(kind: "reply", excerpt: nil))

        XCTAssertNotNil(decoded.postId)
        XCTAssertNil(decoded.postExcerpt)
        XCTAssertTrue(decoded.postWasDeleted)
        XCTAssertEqual(decoded.sentence, "Faisal replied to you", "the row lost its meaning with its excerpt")
        XCTAssertTrue(
            decoded.accessibilityDescription.contains(NotificationCopy.deletedPost),
            "VoiceOver would read a reply with no explanation of the missing text"
        )
    }

    /// An empty string is the same fact as a null, and must not render as a
    /// blank line pretending to be a quote.
    func testAnEmptyExcerptIsTreatedAsNone() throws {
        let decoded = try decode(UserNotification.self, Self.row(kind: "like", excerpt: ""))

        XCTAssertNil(decoded.postExcerpt)
        XCTAssertTrue(decoded.postWasDeleted)
    }

    /// A follow has no post at all, which is a different thing from a deleted
    /// one — and must not be described as one.
    func testAFollowHasNoPostAndIsNotADeletion() throws {
        let decoded = try decode(UserNotification.self, Self.row(kind: "follow", postId: nil, excerpt: nil))

        XCTAssertNil(decoded.postId)
        XCTAssertFalse(decoded.postWasDeleted)
        XCTAssertFalse(decoded.kind.isAboutAPost)
        XCTAssertEqual(NotificationCopy.openHint(.follow), "Opens this person's profile")
    }

    // MARK: - The page

    func testPageDecodesRowsCursorAndTheServersUnreadCount() throws {
        let json = """
        {"notifications": [\(Self.row(kind: "like")), \(Self.row(kind: "follow", postId: nil, excerpt: nil))],
         "next_cursor": "b3BhcXVl", "unread_count": 3}
        """

        let page = try decode(NotificationPage.self, json)

        XCTAssertEqual(page.notifications.count, 2)
        XCTAssertEqual(page.nextCursor, "b3BhcXVl")
        XCTAssertEqual(page.unreadCount, 3)
        XCTAssertTrue(page.hasMore)
    }

    /// The count is whatever the server said, even when it disagrees with the
    /// rows in hand — the server hides notifications from blocked and
    /// deactivated accounts, so it knows things this page does not.
    func testUnreadCountIsTheServersNumberNotACountOfUnreadRows() throws {
        let json = """
        {"notifications": [\(Self.row(kind: "like", read: true))],
         "next_cursor": null, "unread_count": 9}
        """

        let page = try decode(NotificationPage.self, json)

        XCTAssertEqual(page.unreadCount, 9)
        XCTAssertEqual(page.notifications.filter { !$0.read }.count, 0)
    }

    func testANullCursorEndsThePage() throws {
        let page = try decode(
            NotificationPage.self,
            #"{"notifications": [], "next_cursor": null, "unread_count": 0}"#
        )

        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    /// One unreadable row costs that row, not the nineteen good ones beside it.
    func testAMalformedRowDoesNotEmptyThePage() throws {
        let json = """
        {"notifications": [\(Self.row(kind: "like")), {"id": "x", "kind": "like"}],
         "next_cursor": null, "unread_count": 1}
        """

        let page = try decode(NotificationPage.self, json)

        XCTAssertEqual(page.notifications.count, 1, "a row with no actor took the page with it")
        XCTAssertEqual(page.unreadCount, 1)
    }

    // MARK: - The small responses

    func testUnreadCountResponseDecodes() throws {
        XCTAssertEqual(try decode(NotificationUnreadCount.self, #"{"unread": 4}"#).unread, 4)
    }

    func testReadResultDecodesBothNumbers() throws {
        let result = try decode(NotificationReadResult.self, #"{"marked_read": 3, "unread": 0}"#)

        XCTAssertEqual(result.markedRead, 3)
        XCTAssertEqual(result.unread, 0)
    }

    // MARK: - Preferences

    /// The server's default: an account that has never touched these gets
    /// everything. A missing key must never read as "off".
    func testAnAbsentKindIsOn() throws {
        let preferences = try decode(NotificationPreferences.self, #"{"like": false}"#)

        XCTAssertFalse(preferences.isEnabled(.like))
        XCTAssertTrue(preferences.isEnabled(.follow))
        XCTAssertTrue(preferences.isEnabled(.mention))
        XCTAssertEqual(preferences.silenced, [.like])
    }

    /// A `PUT` states every kind, because the object is replaced wholesale —
    /// sending one key would switch the other four off.
    func testPayloadStatesEveryKnownKind() {
        let payload = NotificationPreferences([.like: false]).payload

        XCTAssertEqual(payload["like"], false)
        for kind in NotificationKind.settable {
            XCTAssertNotNil(payload[kind.rawValue], "\(kind.rawValue) missing from the PUT body")
        }
    }

    /// A key this build does not recognise is carried through rather than
    /// dropped, so writing one switch cannot silently reset another.
    func testAnUnknownKeyIsPreservedThroughAWrite() {
        let stored = NotificationPreferences(enabled: ["like": true, "quote_boost": false])

        let payload = stored.setting(false, for: .like).payload

        XCTAssertEqual(payload["like"], false)
        XCTAssertEqual(payload["quote_boost"], false, "an unrecognised key was dropped by the client")
    }

    /// Notification switches ride inside the same document as the feed
    /// settings, so the feed decoder has to keep them.
    func testFeedPreferencesCarriesTheNotificationMap() throws {
        let json = """
        {"interests": [], "muted_topics": [], "filter_international_by_interests": false,
         "show_untagged_posts": true, "muted_countries": [],
         "notifications": {"like": false, "reply": true}}
        """

        let preferences = try decode(FeedPreferences.self, json)

        XCTAssertFalse(preferences.notifications.isEnabled(.like))
        XCTAssertTrue(preferences.notifications.isEnabled(.reply))
    }

    /// An older account whose preferences predate the map is not silenced by
    /// the absence.
    func testFeedPreferencesWithoutANotificationMapLeavesEverythingOn() throws {
        let json = """
        {"interests": [], "muted_topics": [], "filter_international_by_interests": false,
         "show_untagged_posts": true, "muted_countries": []}
        """

        let preferences = try decode(FeedPreferences.self, json)

        XCTAssertTrue(NotificationKind.settable.allSatisfy { preferences.notifications.isEnabled($0) })
    }

    /// The feed-preferences screen must not re-assert notification switches it
    /// never showed — that would undo a change made on the other surface.
    func testTheFeedPreferencesBodyDoesNotCarryNotifications() {
        let body = PreferencesUpdate.replacing(
            FeedPreferences(notifications: NotificationPreferences([.like: false]))
        )

        XCTAssertNil(body.notifications)
    }

    // MARK: - Copy

    func testTheSummaryNamesWhatIsSilenced() {
        let sentence = NotificationCopy.settingsSummary(
            NotificationPreferences([.like: false, .repost: false])
        )

        XCTAssertTrue(sentence.contains("likes"))
        XCTAssertTrue(sentence.contains("reposts"))
    }

    func testTheSummarySaysSoWhenNothingIsSilenced() {
        XCTAssertEqual(
            NotificationCopy.settingsSummary(NotificationPreferences()),
            "Every kind of notification reaches you."
        )
    }

    func testTheUnreadSummaryReadsAsASentenceAtEveryCount() {
        XCTAssertEqual(NotificationCopy.unreadSummary(0), "Nothing unread")
        XCTAssertEqual(NotificationCopy.unreadSummary(1), "1 unread")
        XCTAssertEqual(NotificationCopy.unreadSummary(12), "12 unread")
    }

    /// The one thing the settings copy must not do is promise something about
    /// push notifications, which Sila does not send.
    func testTheSettingsCopyPromisesNothingAboutPush() {
        let copy = NotificationCopy.settingsExplanation.lowercased()

        for phrase in ["push", "alert on your phone", "buzz", "badge on your home screen"] {
            XCTAssertFalse(copy.contains(phrase), "the settings copy promises \(phrase)")
        }
    }
}
