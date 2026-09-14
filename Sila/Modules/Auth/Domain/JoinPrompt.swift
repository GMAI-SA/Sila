import Foundation

/// What a guest was reaching for when the app asked them to join.
///
/// The ask is the whole point of the read-only surface, so it is never a
/// generic "sign in to continue": it names the thing they just tried to do,
/// at the moment they wanted to do it, which is the only moment the answer
/// is obviously worth it.
public enum JoinPrompt: String, Identifiable, CaseIterable, Sendable {
    case reply
    case like
    case repost
    case bookmark
    case post
    case follow
    case message
    case room
    case notifications
    case profile

    public var id: String { rawValue }

    /// The headline: what joining would let them do.
    ///
    /// Spelled out rather than interpolated from ``rawValue``: a key the
    /// catalogue check cannot see is a key nobody notices has gone missing,
    /// and the first anyone would know is a screen showing `guest.join.…`.
    public var title: String {
        switch self {
        case .reply: return L10n.t("guest.join.reply.title")
        case .like: return L10n.t("guest.join.like.title")
        case .repost: return L10n.t("guest.join.repost.title")
        case .bookmark: return L10n.t("guest.join.bookmark.title")
        case .post: return L10n.t("guest.join.post.title")
        case .follow: return L10n.t("guest.join.follow.title")
        case .message: return L10n.t("guest.join.message.title")
        case .room: return L10n.t("guest.join.room.title")
        case .notifications: return L10n.t("guest.join.notifications.title")
        case .profile: return L10n.t("guest.join.profile.title")
        }
    }

    /// One sentence about why this place asks at all. The honest reason —
    /// everyone here is a verified person — is also the selling point.
    public var detail: String {
        switch self {
        case .reply: return L10n.t("guest.join.reply.detail")
        case .like: return L10n.t("guest.join.like.detail")
        case .repost: return L10n.t("guest.join.repost.detail")
        case .bookmark: return L10n.t("guest.join.bookmark.detail")
        case .post: return L10n.t("guest.join.post.detail")
        case .follow: return L10n.t("guest.join.follow.detail")
        case .message: return L10n.t("guest.join.message.detail")
        case .room: return L10n.t("guest.join.room.detail")
        case .notifications: return L10n.t("guest.join.notifications.detail")
        case .profile: return L10n.t("guest.join.profile.detail")
        }
    }

    /// The symbol beside the headline.
    public var icon: String {
        switch self {
        case .reply: return "bubble.left"
        case .like: return "heart"
        case .repost: return "arrow.2.squarepath"
        case .bookmark: return "bookmark"
        case .post: return "square.and.pencil"
        case .follow: return "person.badge.plus"
        case .message: return "envelope"
        case .room: return "waveform"
        case .notifications: return "bell"
        case .profile: return "person"
        }
    }
}
