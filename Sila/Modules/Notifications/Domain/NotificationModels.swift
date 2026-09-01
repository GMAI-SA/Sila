import Foundation
import SwiftUI

// MARK: - Kind

/// What somebody did. One of five things, plus the case for a sixth this build
/// has never heard of.
///
/// ``unknown`` exists so a kind added to the server after this app shipped
/// still renders as a row rather than failing the whole page's decode. It is
/// deliberately **not** part of ``settable``: the preferences map covers the
/// five kinds the contract names, and offering a switch for "whatever this is"
/// would be a control nobody could reason about.
public enum NotificationKind: String, Sendable, Hashable, Identifiable, Decodable {
    /// Somebody followed the viewer. The only kind with no post behind it.
    case follow
    /// Somebody liked one of the viewer's posts.
    case like
    /// Somebody reposted one of the viewer's posts.
    case repost
    /// Somebody replied to one of the viewer's posts.
    case reply
    /// Somebody put the viewer's handle in a post.
    case mention
    /// A kind this build does not recognise.
    case unknown

    public var id: String { rawValue }

    /// The five kinds the contract names, in the order the settings list shows
    /// them: the noisiest first, because that is the one people come to silence.
    public static let settable: [NotificationKind] = [.like, .reply, .mention, .repost, .follow]

    /// Unrecognised values decode as ``unknown`` rather than throwing — one new
    /// kind on the server must not blank somebody's whole notification list.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotificationKind(rawValue: raw) ?? .unknown
    }

    /// `true` when a notification of this kind is about a post.
    ///
    /// A follow is the only one that is not, which is why it is the only one
    /// whose `post_id` is legitimately `null`.
    public var isAboutAPost: Bool { self != .follow && self != .unknown }

    /// SF Symbol for the row's kind marker.
    public var icon: String {
        switch self {
        case .follow: return "person.badge.plus"
        case .like: return "heart.fill"
        case .repost: return "arrow.2.squarepath"
        case .reply: return "arrowshape.turn.up.left.fill"
        case .mention: return "at"
        case .unknown: return "bell"
        }
    }

    /// Colour of the kind marker.
    public var tint: Color {
        switch self {
        case .follow: return SLColor.primary
        case .like: return SLColor.danger
        case .repost: return SLColor.secondary
        case .reply: return SLColor.primary
        case .mention: return SLColor.warning
        case .unknown: return SLColor.textSecondary
        }
    }

    /// Plural label for the settings list.
    public var settingTitle: String {
        switch self {
        case .follow: return L10n.t("notifications.kind.follow.title")
        case .like: return L10n.t("notifications.kind.like.title")
        case .repost: return L10n.t("notifications.kind.repost.title")
        case .reply: return L10n.t("notifications.kind.reply.title")
        case .mention: return L10n.t("notifications.kind.mention.title")
        case .unknown: return L10n.t("notifications.kind.unknown.title")
        }
    }

    /// What the switch actually governs, said without overclaiming.
    ///
    /// Sila does not send push notifications yet, so none of this copy promises
    /// anything about a phone buzzing — it describes the list, which is the
    /// only thing the setting is known to control.
    public var settingDetail: String {
        switch self {
        case .follow:
            return L10n.t("notifications.kind.follow.detail")
        case .like:
            return L10n.t("notifications.kind.like.detail")
        case .repost:
            return L10n.t("notifications.kind.repost.detail")
        case .reply:
            return L10n.t("notifications.kind.reply.detail")
        case .mention:
            return L10n.t("notifications.kind.mention.detail")
        case .unknown:
            return L10n.t("notifications.kind.unknown.detail")
        }
    }
}

// MARK: - The notification

/// One row of `GET /notifications`.
///
/// Named ``UserNotification`` rather than `Notification` so it cannot be
/// confused with Foundation's, which every SwiftUI file already has in scope.
///
/// **``postExcerpt`` may be `nil` while ``postId`` is not.** That is the server
/// saying the post has since been deleted. The row is still rendered — "someone
/// replied to you" is true whatever happened to the reply afterwards, and a
/// client that dropped the row would be quietly editing somebody's history to
/// make a list tidier. See ``postWasDeleted``.
public struct UserNotification: Identifiable, Equatable, Sendable, Decodable, Hashable {

    public let id: UUID
    /// What happened.
    public let kind: NotificationKind
    /// Who did it.
    public let actor: UserSummary
    /// The post it is about, or `nil` for a follow.
    public let postId: UUID?
    /// The first 140 characters of that post, or `nil` when there is no post —
    /// or when there was one and it is gone.
    public let postExcerpt: String?
    /// Whether the viewer has already seen it. `var` so a row can be marked
    /// read in place without refetching the page.
    public var read: Bool
    /// When it happened.
    public let createdAt: Date

    public init(
        id: UUID,
        kind: NotificationKind,
        actor: UserSummary,
        postId: UUID? = nil,
        postExcerpt: String? = nil,
        read: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.actor = actor
        self.postId = postId
        self.postExcerpt = (postExcerpt?.isEmpty == false) ? postExcerpt : nil
        self.read = read
        self.createdAt = createdAt
    }

    /// Explicit keys are required because ``init(from:)`` is custom, and the
    /// raw values are the *camel-cased* forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case id, kind, actor, postId, postExcerpt, read, createdAt
    }

    /// Tolerant decoder: one malformed row must not blank the whole page.
    ///
    /// Everything except ``actor`` survives a missing or wrong-typed field.
    /// The actor is allowed to throw because there is no row without one —
    /// "somebody liked your post" with no somebody is not a notification.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .id)) ?? ""
            id = UUID(uuidString: raw) ?? UUID()
        }
        kind = (try? container.decode(NotificationKind.self, forKey: .kind)) ?? .unknown
        actor = try container.decode(UserSummary.self, forKey: .actor)
        if let raw = (try? container.decodeIfPresent(String.self, forKey: .postId)) ?? nil {
            postId = UUID(uuidString: raw)
        } else {
            postId = (try? container.decodeIfPresent(UUID.self, forKey: .postId)) ?? nil
        }
        let excerpt = (try? container.decodeIfPresent(String.self, forKey: .postExcerpt)) ?? nil
        postExcerpt = (excerpt?.isEmpty == false) ? excerpt : nil
        read = (try? container.decode(Bool.self, forKey: .read)) ?? false
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    // MARK: Derived

    /// `true` when this row points at a post whose text the server would not
    /// give us — which the contract says means the post has been deleted.
    public var postWasDeleted: Bool { postId != nil && postExcerpt == nil }

    /// The sentence the row leads with.
    public var sentence: String {
        NotificationCopy.sentence(kind, actor: actor.displayName)
    }

    /// The whole row as one line for VoiceOver.
    public var accessibilityDescription: String {
        var parts = [sentence, RelativeTime.accessible(createdAt)]
        if let excerpt = postExcerpt {
            parts.append(L10n.t("notifications.row.accessibility.post", excerpt))
        } else if postWasDeleted {
            parts.append(NotificationCopy.deletedPost)
        }
        parts.append(L10n.t(read ? "notifications.row.accessibility.read" : "notifications.row.accessibility.unread"))
        return parts.joined(separator: ". ")
    }
}

// MARK: - Page

/// One page of `GET /notifications`.
///
/// ``unreadCount`` is the **server's** number and the only one the UI shows.
/// Counting unread rows on the client would drift the moment the server hides
/// something — it filters out notifications from blocked and deactivated
/// accounts — and a badge that disagrees with the list it belongs to is worse
/// than no badge at all.
public struct NotificationPage: Equatable, Sendable, Decodable {

    public let notifications: [UserNotification]
    /// Pass back as `?cursor=` for the next page. `nil` at the end.
    public let nextCursor: String?
    /// How many notifications are unread **in total**, not on this page.
    public let unreadCount: Int

    public init(notifications: [UserNotification], nextCursor: String? = nil, unreadCount: Int = 0) {
        self.notifications = notifications
        self.nextCursor = (nextCursor?.isEmpty == false) ? nextCursor : nil
        self.unreadCount = max(0, unreadCount)
    }

    private enum CodingKeys: String, CodingKey {
        case notifications, nextCursor, unreadCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Row by row, so a single unreadable notification costs that row and
        // not the page. A plain `[UserNotification]` decode is all-or-nothing:
        // one row with no actor would empty a list that has nineteen good ones
        // in it, and the screen would say "nothing yet" — which is a lie the
        // user has no way to see through.
        notifications = ((try? container.decode([FailableRow].self, forKey: .notifications)) ?? [])
            .compactMap(\.value)
        let cursor = (try? container.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        nextCursor = (cursor?.isEmpty == false) ? cursor : nil
        unreadCount = max(0, (try? container.decode(Int.self, forKey: .unreadCount)) ?? 0)
    }

    /// Whether another page exists. Unlike the feed there is no `has_more`
    /// flag — the cursor is the whole answer.
    public var hasMore: Bool { nextCursor != nil }

    /// The end-of-list page.
    public static let empty = NotificationPage(notifications: [], nextCursor: nil, unreadCount: 0)
}

/// One array element that decodes to `nil` instead of throwing.
///
/// The wrapper is what makes the row-by-row decode safe: a failed element still
/// consumes exactly one slot, so the loop cannot stall on a row it cannot read.
private struct FailableRow: Decodable {
    let value: UserNotification?

    init(from decoder: Decoder) throws {
        value = try? UserNotification(from: decoder)
    }
}

// MARK: - Small responses

/// What `GET /notifications/unread-count` answers: `{"unread": n}`.
public struct NotificationUnreadCount: Equatable, Sendable, Decodable {

    public let unread: Int

    public init(unread: Int) {
        self.unread = max(0, unread)
    }

    private enum CodingKeys: String, CodingKey { case unread }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unread = max(0, (try? container.decode(Int.self, forKey: .unread)) ?? 0)
    }
}

/// What `POST /notifications/read` answers: `{"marked_read": n, "unread": n}`.
///
/// Both numbers come back for a reason: ``markedRead`` says what this call did
/// and ``unread`` says what is left, and the client must adopt the second
/// rather than subtracting the first — another device may have read something
/// in between.
public struct NotificationReadResult: Equatable, Sendable, Decodable {

    /// How many rows this call actually flipped.
    public let markedRead: Int
    /// How many are unread afterwards, server-side.
    public let unread: Int

    public init(markedRead: Int, unread: Int) {
        self.markedRead = max(0, markedRead)
        self.unread = max(0, unread)
    }

    private enum CodingKeys: String, CodingKey { case markedRead, unread }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markedRead = max(0, (try? container.decode(Int.self, forKey: .markedRead)) ?? 0)
        unread = max(0, (try? container.decode(Int.self, forKey: .unread)) ?? 0)
    }
}

// MARK: - Preferences

/// The `notifications` object inside `GET`/`PUT /me/preferences` — an on/off
/// switch per kind.
///
/// Stored as a dictionary rather than five booleans so a kind added server-side
/// round-trips untouched instead of being silently dropped by a `PUT` this
/// build wrote. **A kind that is absent is on**, which is the server's own
/// default: a preferences object that has never been written must not read as
/// "everything is off".
public struct NotificationPreferences: Equatable, Sendable, Codable {

    /// Raw wire map, keyed by ``NotificationKind`` raw values.
    public private(set) var enabled: [String: Bool]

    /// - Parameter enabled: The wire map. Defaults to empty — every kind on.
    public init(enabled: [String: Bool] = [:]) {
        self.enabled = enabled
    }

    /// Builds a map from the five known kinds.
    public init(_ values: [NotificationKind: Bool]) {
        enabled = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    public init(from decoder: Decoder) throws {
        // A `null`, a missing key or an object of the wrong shape all mean "the
        // server said nothing", which is the same as every kind being on.
        enabled = (try? decoder.singleValueContainer().decode([String: Bool].self)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(enabled)
    }

    /// Whether this kind is switched on. Unknown to the map means on.
    public func isEnabled(_ kind: NotificationKind) -> Bool {
        enabled[kind.rawValue] ?? true
    }

    /// A copy with one kind flipped.
    public func setting(_ isEnabled: Bool, for kind: NotificationKind) -> NotificationPreferences {
        var copy = self
        copy.enabled[kind.rawValue] = isEnabled
        return copy
    }

    /// The body a `PUT` sends. Every known kind is stated explicitly, plus any
    /// key the server sent that this build does not recognise — dropping those
    /// would turn a partial edit into an unintended reset.
    public var payload: [String: Bool] {
        var body = enabled
        for kind in NotificationKind.settable where body[kind.rawValue] == nil {
            body[kind.rawValue] = true
        }
        return body
    }

    /// Kinds the viewer has switched off, in settings order.
    public var silenced: [NotificationKind] {
        NotificationKind.settable.filter { !isEnabled($0) }
    }
}

// MARK: - Copy

/// The sentences this surface uses.
///
/// Pure functions, kept out of the views so they can be asserted directly. The
/// rule they exist to hold: **every kind gets its own sentence.** A list that
/// said "you have a new notification" five times would be a list nobody could
/// triage without tapping every row.
public enum NotificationCopy {

    /// The one-line description of a notification.
    /// - Parameters:
    ///   - kind: What happened.
    ///   - actor: The display name of whoever did it.
    public static func sentence(_ kind: NotificationKind, actor: String) -> String {
        let name = actor.isEmpty ? L10n.t("notifications.sentence.someone") : actor
        switch kind {
        case .follow: return L10n.t("notifications.sentence.follow", name)
        case .like: return L10n.t("notifications.sentence.like", name)
        case .repost: return L10n.t("notifications.sentence.repost", name)
        case .reply: return L10n.t("notifications.sentence.reply", name)
        case .mention: return L10n.t("notifications.sentence.mention", name)
        // Not "new notification": it still says who, and it says plainly that
        // the *app* is the part that is out of date, rather than implying the
        // event was unimportant.
        case .unknown: return L10n.t("notifications.sentence.unknown", name)
        }
    }

    /// Shown in place of the excerpt when the post behind a row is gone.
    public static var deletedPost: String { L10n.t("notifications.row.deletedPost") }

    /// What tapping a row does.
    public static func openHint(_ kind: NotificationKind) -> String {
        L10n.t(kind.isAboutAPost ? "notifications.row.openHint.post" : "notifications.row.openHint.profile")
    }

    /// The empty list.
    public static var emptyTitle: String { L10n.t("notifications.empty.title") }

    /// Why an empty list is not a broken one.
    public static var emptySubtitle: String { L10n.t("notifications.empty.subtitle") }

    /// The empty *unread* list, which is a different fact from an empty list.
    public static var emptyUnreadTitle: String { L10n.t("notifications.emptyUnread.title") }

    /// - Parameter total: How many notifications exist in the All tab.
    ///
    /// A plural entry rather than a `total > 0` ternary: the two sentences are
    /// the `zero` category and the rest, which is a distinction the catalog can
    /// make in six Arabic forms and a Swift `if` cannot make in any.
    public static func emptyUnreadSubtitle(total: Int) -> String {
        L10n.plural("notifications.emptyUnread.subtitle", total)
    }

    /// The counter above the list.
    ///
    /// Counted copy, so it goes through the catalog's plural rules. `0` is not
    /// a count here at all — it is a different sentence, carried by the `zero`
    /// category.
    /// - Parameter unread: The server's unread count.
    public static func unreadSummary(_ unread: Int) -> String {
        L10n.plural("notifications.unread.summary", unread)
    }

    /// What "Mark all read" does, said in a way that does not imply anybody
    /// else can see the result.
    public static var markAllHint: String { L10n.t("notifications.markAll.hint") }

    /// Confirmation after a successful mark-all.
    ///
    /// `0` is the `zero` category and says something else entirely — nothing
    /// was left to mark, rather than "0 notifications marked".
    /// - Parameter count: How many the **server** says it flipped.
    public static func markedAll(_ count: Int) -> String {
        L10n.plural("notifications.markAll.confirmation", count)
    }

    /// The settings sheet's explanation.
    ///
    /// Says exactly what is known — these switches govern this list — and
    /// promises nothing about push, which Sila does not send.
    public static var settingsExplanation: String { L10n.t("notifications.settings.explanation") }

    /// The line under the settings list, summarising what is off.
    /// - Parameter preferences: The stored map.
    public static func settingsSummary(_ preferences: NotificationPreferences) -> String {
        let off = preferences.silenced
        guard !off.isEmpty else { return L10n.t("notifications.settings.summary.nothingSilenced") }
        let names = off.map { $0.settingTitle.lowercased() }
        return L10n.t("notifications.settings.summary.hidden", list(names))
    }

    /// Joins names the way the reading language joins them — the conjunction
    /// and the separator are both catalog strings, because Arabic writes
    /// "أ وب" with no space before the و and separates with `،`.
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return L10n.t("notifications.settings.summary.listPair", items[0], items[1])
        default:
            let leading = items.dropLast().joined(separator: L10n.t("notifications.settings.summary.listSeparator"))
            return L10n.t("notifications.settings.summary.listPair", leading, items.last ?? "")
        }
    }
}
