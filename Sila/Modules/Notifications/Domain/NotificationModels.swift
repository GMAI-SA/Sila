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
    /// Somebody asked to follow the viewer's private account. No post behind it.
    case followRequest = "follow_request"
    /// A private account let the viewer in. No post behind it either.
    case followAccepted = "follow_accepted"
    /// Somebody asked you into a closed room.
    case roomInvite = "room_invite"
    /// Somebody asked you into a community.
    case communityInvite = "community_invite"
    /// Somebody asked to join a community you run.
    case communityJoinRequest = "community_join_request"
    /// A community you asked to join let you in.
    case communityAccepted = "community_accepted"
    /// Somebody liked a room you hosted.
    case roomLike = "room_like"
    /// Somebody put a room you hosted on their timeline.
    case roomShared = "room_shared"
    /// A poll you asked or answered has closed (contract v19).
    case pollClosed = "poll_closed"
    /// Sila's weekly question.
    case prompt
    /// Somebody may be claiming to be you. Never switch-offable.
    case identityImpostor = "identity_impostor"
    /// A room you set a reminder for is tomorrow / within the hour / live now,
    /// or was cancelled before it began (contract v21).
    case roomTomorrow = "room_tomorrow"
    case roomSoon = "room_soon"
    case roomLive = "room_live"
    case roomCancelled = "room_cancelled"
    /// Somebody gave one of your posts a qualitative reaction (contract v22).
    case reaction
    /// Somebody replied deeper in a thread you started.
    case threadReply = "thread_reply"
    /// Events (contract v23).
    case eventInvite = "event_invite"
    case eventTomorrow = "event_tomorrow"
    case eventSoon = "event_soon"
    case eventLive = "event_live"
    case eventChanged = "event_changed"
    case eventCancelled = "event_cancelled"
    /// A kind this build does not recognise.
    case unknown

    public var id: String { rawValue }

    /// The five kinds the contract names, in the order the settings list shows
    /// them: the noisiest first, because that is the one people come to silence.
    public static let settable: [NotificationKind] = [.like, .reply, .mention, .repost, .follow, .roomInvite]

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
    public var isAboutAPost: Bool {
        switch self {
        case .follow, .followRequest, .followAccepted, .roomInvite, .unknown,
             .communityInvite, .communityJoinRequest, .communityAccepted,
             .roomLike, .prompt, .identityImpostor, .roomTomorrow, .roomSoon, .roomLive, .roomCancelled,
             .eventInvite, .eventTomorrow, .eventSoon, .eventLive, .eventChanged, .eventCancelled:
            return false
        case .like, .repost, .reply, .mention, .roomShared, .pollClosed, .reaction, .threadReply: return true
        }
    }

    /// SF Symbol for the row's kind marker.
    public var icon: String {
        switch self {
        case .follow: return "person.badge.plus"
        case .like: return "heart.fill"
        case .repost: return "arrow.2.squarepath"
        case .reply: return "arrowshape.turn.up.left.fill"
        case .mention: return "at"
        case .followRequest: return "person.crop.circle.badge.questionmark"
        case .followAccepted: return "person.crop.circle.badge.checkmark"
        case .roomInvite: return "waveform.circle.fill"
        case .communityInvite: return "person.3.fill"
        case .communityJoinRequest: return "person.crop.circle.badge.questionmark"
        case .communityAccepted: return "person.crop.circle.badge.checkmark"
        case .roomLike: return "heart.circle"
        case .roomShared: return "square.and.arrow.up.circle"
        case .pollClosed: return "chart.bar.fill"
        case .prompt: return "questionmark.bubble.fill"
        case .identityImpostor: return "exclamationmark.shield.fill"
        case .roomTomorrow: return "calendar"
        case .roomSoon: return "clock.badge"
        case .roomLive: return "dot.radiowaves.left.and.right"
        case .roomCancelled: return "calendar.badge.minus"
        case .reaction: return "hands.clap.fill"
        case .threadReply: return "bubble.left.and.bubble.right.fill"
        case .eventInvite: return "envelope.open.fill"
        case .eventTomorrow, .eventSoon: return "calendar"
        case .eventLive: return "calendar.badge.clock"
        case .eventChanged: return "calendar.badge.exclamationmark"
        case .eventCancelled: return "calendar.badge.minus"
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
        case .followRequest: return SLColor.primary
        case .followAccepted: return SLColor.secondary
        case .roomInvite: return SLColor.secondary
        case .communityInvite: return SLColor.primary
        case .communityJoinRequest: return SLColor.warning
        case .communityAccepted: return SLColor.secondary
        case .roomLike: return SLColor.danger
        case .roomShared: return SLColor.secondary
        case .pollClosed: return SLColor.primary
        case .prompt: return SLColor.warning
        case .identityImpostor: return SLColor.danger
        case .roomTomorrow, .roomSoon: return SLColor.primary
        case .roomLive: return SLColor.danger
        case .roomCancelled: return SLColor.textSecondary
        case .reaction: return SLColor.warning
        case .threadReply: return SLColor.primary
        case .eventInvite, .eventTomorrow, .eventSoon, .eventChanged: return SLColor.primary
        case .eventLive: return SLColor.danger
        case .eventCancelled: return SLColor.textSecondary
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
        case .followRequest: return L10n.t("notifications.kind.followRequest.title")
        case .followAccepted: return L10n.t("notifications.kind.followAccepted.title")
        case .roomInvite: return L10n.t("notifications.kind.roomInvite.title")
        case .communityInvite: return L10n.t("notifications.kind.communityInvite.title")
        case .communityJoinRequest: return L10n.t("notifications.kind.communityJoinRequest.title")
        case .communityAccepted: return L10n.t("notifications.kind.communityAccepted.title")
        case .roomLike: return L10n.t("notifications.kind.roomLike.title")
        case .roomShared: return L10n.t("notifications.kind.roomShared.title")
        case .pollClosed: return L10n.t("notifications.kind.pollClosed.title")
        case .prompt: return L10n.t("notifications.kind.prompt.title")
        case .identityImpostor: return L10n.t("notifications.kind.identityImpostor.title")
        case .roomTomorrow: return L10n.t("notifications.kind.roomTomorrow.title")
        case .roomSoon: return L10n.t("notifications.kind.roomSoon.title")
        case .roomLive: return L10n.t("notifications.kind.roomLive.title")
        case .roomCancelled: return L10n.t("notifications.kind.roomCancelled.title")
        case .reaction: return L10n.t("notifications.kind.reaction.title")
        case .threadReply: return L10n.t("notifications.kind.threadReply.title")
        case .eventInvite: return L10n.t("notifications.kind.eventInvite.title")
        case .eventTomorrow: return L10n.t("notifications.kind.eventTomorrow.title")
        case .eventSoon: return L10n.t("notifications.kind.eventSoon.title")
        case .eventLive: return L10n.t("notifications.kind.eventLive.title")
        case .eventChanged: return L10n.t("notifications.kind.eventChanged.title")
        case .eventCancelled: return L10n.t("notifications.kind.eventCancelled.title")
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
        case .followRequest:
            return L10n.t("notifications.kind.followRequest.detail")
        case .followAccepted:
            return L10n.t("notifications.kind.followAccepted.detail")
        case .roomInvite:
            return L10n.t("notifications.kind.roomInvite.detail")
        case .communityInvite:
            return L10n.t("notifications.kind.communityInvite.detail")
        case .communityJoinRequest:
            return L10n.t("notifications.kind.communityJoinRequest.detail")
        case .communityAccepted:
            return L10n.t("notifications.kind.communityAccepted.detail")
        case .roomLike:
            return L10n.t("notifications.kind.roomLike.detail")
        case .roomShared:
            return L10n.t("notifications.kind.roomShared.detail")
        case .pollClosed:
            return L10n.t("notifications.kind.pollClosed.detail")
        case .prompt:
            return L10n.t("notifications.kind.prompt.detail")
        case .identityImpostor:
            return L10n.t("notifications.kind.identityImpostor.detail")
        case .roomTomorrow:
            return L10n.t("notifications.kind.roomTomorrow.detail")
        case .roomSoon:
            return L10n.t("notifications.kind.roomSoon.detail")
        case .roomLive:
            return L10n.t("notifications.kind.roomLive.detail")
        case .roomCancelled:
            return L10n.t("notifications.kind.roomCancelled.detail")
        case .reaction:
            return L10n.t("notifications.kind.reaction.detail")
        case .threadReply:
            return L10n.t("notifications.kind.threadReply.detail")
        case .eventInvite, .eventTomorrow, .eventSoon, .eventLive, .eventChanged, .eventCancelled:
            return L10n.t("notifications.kind.event.detail")
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
    /// The room it is about, for a room invitation.
    public let roomId: UUID?
    /// A qualifier the server adds (contract v22): `answer` on a reply to a
    /// question, the reaction's kind on `reaction`.
    public var detail: String? = nil
    /// The event a row is about (contract v23).
    public var eventId: UUID? = nil
    /// The community a community notification points at, and its address.
    public let communityId: UUID?
    public let communitySlug: String?
    public let communityName: String?
    /// The first 140 characters of that post, or `nil` when there is no post —
    /// or when there was one and it is gone — or when the post is covered and
    /// its author wrote no note.
    public let postExcerpt: String?
    /// Set when the post carries a warning. The excerpt is then the author's
    /// note, never the text: the list must not be a way to read a spoiler the
    /// post itself hides.
    public let postSensitive: SensitiveKind?
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
        createdAt: Date = Date(),
        postSensitive: SensitiveKind? = nil,
        roomId: UUID? = nil,
        communityId: UUID? = nil,
        communitySlug: String? = nil,
        communityName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.actor = actor
        self.postId = postId
        self.roomId = roomId
        self.communityId = communityId
        self.communitySlug = communitySlug
        self.communityName = communityName
        self.postExcerpt = (postExcerpt?.isEmpty == false) ? postExcerpt : nil
        self.postSensitive = postSensitive
        self.read = read
        self.createdAt = createdAt
    }

    /// Explicit keys are required because ``init(from:)`` is custom, and the
    /// raw values are the *camel-cased* forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case id, kind, actor, postId, postExcerpt, read, createdAt, postSensitive, roomId, detail, eventId
        case communityId, communitySlug, communityName
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
        if let rawRoom = (try? container.decodeIfPresent(String.self, forKey: .roomId)) ?? nil {
            roomId = UUID(uuidString: rawRoom)
        } else {
            roomId = (try? container.decodeIfPresent(UUID.self, forKey: .roomId)) ?? nil
        }
        communityId = (try? container.decodeIfPresent(UUID.self, forKey: .communityId)) ?? nil
        let slug = (try? container.decodeIfPresent(String.self, forKey: .communitySlug)) ?? nil
        communitySlug = (slug?.isEmpty == false) ? slug : nil
        let label = (try? container.decodeIfPresent(String.self, forKey: .communityName)) ?? nil
        communityName = (label?.isEmpty == false) ? label : nil
        if let raw = (try? container.decodeIfPresent(String.self, forKey: .postId)) ?? nil {
            postId = UUID(uuidString: raw)
        } else {
            postId = (try? container.decodeIfPresent(UUID.self, forKey: .postId)) ?? nil
        }
        let excerpt = (try? container.decodeIfPresent(String.self, forKey: .postExcerpt)) ?? nil
        postExcerpt = (excerpt?.isEmpty == false) ? excerpt : nil
        postSensitive = (try? container.decodeIfPresent(SensitiveKind.self, forKey: .postSensitive)) ?? nil
        read = (try? container.decode(Bool.self, forKey: .read)) ?? false
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        eventId = (try? container.decodeIfPresent(UUID.self, forKey: .eventId)) ?? nil
    }

    // MARK: Derived

    /// `true` when this row points at a post whose text the server would not
    /// give us — which the contract says means the post has been deleted.
    ///
    /// Checked after the warning: a covered post with no note also has no
    /// excerpt, and it is not gone.
    public var postWasDeleted: Bool { postId != nil && postExcerpt == nil && postSensitive == nil }

    /// The sentence the row leads with.
    public var sentence: String {
        NotificationCopy.sentence(kind, actor: actor.displayName, community: communityName, detail: detail)
    }

    /// The whole row as one line for VoiceOver.
    public var accessibilityDescription: String {
        var parts = [sentence, RelativeTime.accessible(createdAt)]
        if let kind = postSensitive {
            parts.append(NotificationCopy.covered(kind, note: postExcerpt))
        } else if let excerpt = postExcerpt {
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

    /// Whether a kind, by its wire name, is switched on — for kinds this
    /// build may not have a case for.
    public func isEnabled(key: String) -> Bool {
        enabled[key] ?? true
    }

    /// A copy with one kind, by its wire name, flipped.
    public func setting(_ isEnabled: Bool, key: String) -> NotificationPreferences {
        var copy = self
        copy.enabled[key] = isEnabled
        return copy
    }

    /// Every wire name the server sent, sorted — the fallback list when the
    /// server did not say how to group them.
    public var keys: [String] { enabled.keys.sorted() }

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

// MARK: - Groups

/// One section of the notification settings, as the server groups it
/// (contract v19 `notification_groups`). The client draws what the server
/// lists, in order, rather than a list compiled into an old build.
public struct NotificationGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let kinds: [String]

    public init(id: String, kinds: [String]) {
        self.id = id
        self.kinds = kinds
    }

    /// The order sections are drawn in; a group the server adds later goes
    /// after these, alphabetically.
    static let knownOrder = ["people", "posts", "rooms", "communities", "sila"]

    /// JSON objects carry no order, so the known groups are put back in
    /// theirs and anything new follows.
    static func ordered(_ map: [String: [String]]) -> [NotificationGroup] {
        let known = knownOrder.compactMap { id in map[id].map { NotificationGroup(id: id, kinds: $0) } }
        let rest = map.keys.filter { !knownOrder.contains($0) }.sorted().map { NotificationGroup(id: $0, kinds: map[$0] ?? []) }
        return (known + rest).filter { !$0.kinds.isEmpty }
    }

    /// The section's heading.
    public var title: String {
        switch id {
        case "people": return L10n.t("notifications.settings.group.people")
        case "posts": return L10n.t("notifications.settings.group.posts")
        case "rooms": return L10n.t("notifications.settings.group.rooms")
        case "communities": return L10n.t("notifications.settings.group.communities")
        case "sila": return L10n.t("notifications.settings.group.sila")
        case "more": return L10n.t("notifications.settings.group.more")
        case "events": return L10n.t("notifications.settings.group.events")
        default: return NotificationGroup.humanised(id)
        }
    }

    /// `"quote_boost"` → `"Quote boost"`: a readable label for a wire name
    /// this build has no copy for. Better than hiding the switch.
    public static func humanised(_ key: String) -> String {
        let words = key.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A settings row for a kind by its wire name.
public struct NotificationSettingRow: Identifiable, Equatable, Sendable {
    public let key: String

    public var id: String { key }

    private var kind: NotificationKind? {
        let kind = NotificationKind(rawValue: key)
        return kind == .unknown ? nil : kind
    }

    public var title: String { kind?.settingTitle ?? NotificationGroup.humanised(key) }
    public var detail: String { kind?.settingDetail ?? L10n.t("notifications.kind.unknown.detail") }
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
    public static func sentence(_ kind: NotificationKind, actor: String, community: String? = nil, detail: String? = nil) -> String {
        let name = actor.isEmpty ? L10n.t("notifications.sentence.someone") : actor
        // The server's qualifiers make two rows say what actually happened.
        if kind == .reply, detail == "answer" { return L10n.t("notifications.sentence.answer", name) }
        if kind == .reaction, let detail, let reaction = ReactionKind(rawValue: detail) {
            switch reaction {
            case .helpful: return L10n.t("notifications.sentence.reaction.helpful", name)
            case .question: return L10n.t("notifications.sentence.reaction.question", name)
            case .insight: return L10n.t("notifications.sentence.reaction.insight", name)
            case .funny: return L10n.t("notifications.sentence.reaction.funny", name)
            }
        }
        // A community row names the space, which is the part that makes it
        // legible: "Noura invited you to Riyadh runners".
        let place = (community?.isEmpty == false) ? community! : L10n.t("communities.title")
        switch kind {
        case .follow: return L10n.t("notifications.sentence.follow", name)
        case .like: return L10n.t("notifications.sentence.like", name)
        case .repost: return L10n.t("notifications.sentence.repost", name)
        case .reply: return L10n.t("notifications.sentence.reply", name)
        case .mention: return L10n.t("notifications.sentence.mention", name)
        case .followRequest: return L10n.t("notifications.sentence.followRequest", name)
        case .followAccepted: return L10n.t("notifications.sentence.followAccepted", name)
        case .roomInvite: return L10n.t("notifications.sentence.roomInvite", name)
        case .communityInvite: return L10n.t("notifications.sentence.communityInvite", name, place)
        case .communityJoinRequest: return L10n.t("notifications.sentence.communityJoinRequest", name, place)
        case .communityAccepted: return L10n.t("notifications.sentence.communityAccepted", name, place)
        case .roomLike: return L10n.t("notifications.sentence.roomLike", name)
        case .roomShared: return L10n.t("notifications.sentence.roomShared", name)
        case .pollClosed: return L10n.t("notifications.sentence.pollClosed")
        case .prompt: return L10n.t("notifications.sentence.prompt")
        case .identityImpostor: return L10n.t("notifications.sentence.identityImpostor")
        case .roomTomorrow: return L10n.t("notifications.sentence.roomTomorrow", name)
        case .roomSoon: return L10n.t("notifications.sentence.roomSoon", name)
        case .roomLive: return L10n.t("notifications.sentence.roomLive", name)
        case .roomCancelled: return L10n.t("notifications.sentence.roomCancelled", name)
        case .reaction: return L10n.t("notifications.sentence.reaction", name)
        case .threadReply: return L10n.t("notifications.sentence.threadReply", name)
        case .eventInvite: return L10n.t("notifications.sentence.eventInvite", name)
        case .eventTomorrow: return L10n.t("notifications.sentence.eventTomorrow", name)
        case .eventSoon: return L10n.t("notifications.sentence.eventSoon", name)
        case .eventLive: return L10n.t("notifications.sentence.eventLive", name)
        case .eventChanged: return L10n.t("notifications.sentence.eventChanged", name)
        case .eventCancelled: return L10n.t("notifications.sentence.eventCancelled", name)
        // Not "new notification": it still says who, and it says plainly that
        // the *app* is the part that is out of date, rather than implying the
        // event was unimportant.
        case .unknown: return L10n.t("notifications.sentence.unknown", name)
        }
    }

    /// Shown in place of the excerpt when the post is covered: the kind of
    /// warning, and the author's note if they wrote one — never the text.
    public static func covered(_ kind: SensitiveKind, note: String?) -> String {
        let label: String
        switch kind {
        case .spoiler: label = L10n.t("notifications.row.sensitive.spoiler")
        case .violence: label = L10n.t("notifications.row.sensitive.violence")
        case .other: label = L10n.t("notifications.row.sensitive.other")
        }
        guard let note, !note.isEmpty else { return label }
        return "\(label) — \(note)"
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
