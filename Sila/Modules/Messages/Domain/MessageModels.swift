import Foundation

/// A thread between the viewer and one other account.
///
/// There is exactly one per pair, enforced by the server over a canonically
/// ordered pair — two people opening a thread at the same moment must not each
/// get half of it.
public struct Conversation: Identifiable, Hashable, Sendable {

    public let id: UUID
    /// The person on the other side. A conversation is never a group, so this
    /// is singular by construction rather than by convention.
    public let other: UserSummary
    /// Whether the viewer has accepted the thread.
    public let accepted: Bool
    /// True when this thread is waiting for **this** viewer to accept it.
    ///
    /// Distinct from `!accepted`: a request the viewer *sent* is unaccepted
    /// too, and it belongs in their inbox, not in their requests.
    public let isRequest: Bool
    public let unreadCount: Int
    public let lastMessageAt: Date?
    /// A preview of the newest message, or `nil` when it was deleted.
    public let lastMessage: String?

    public init(
        id: UUID,
        other: UserSummary,
        accepted: Bool,
        isRequest: Bool,
        unreadCount: Int,
        lastMessageAt: Date?,
        lastMessage: String?
    ) {
        self.id = id
        self.other = other
        self.accepted = accepted
        self.isRequest = isRequest
        self.unreadCount = unreadCount
        self.lastMessageAt = lastMessageAt
        self.lastMessage = lastMessage
    }
}

/// One message in a thread.
public struct DirectMessage: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let conversationId: UUID
    public let sender: UserSummary
    /// `nil` once deleted. The row survives deletion so a report about it keeps
    /// its evidence, which is why this is optional rather than the row being
    /// absent.
    public let text: String?
    public let deleted: Bool
    public let read: Bool
    public let createdAt: Date

    public init(
        id: UUID,
        conversationId: UUID,
        sender: UserSummary,
        text: String?,
        deleted: Bool,
        read: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.conversationId = conversationId
        self.sender = sender
        self.text = text
        self.deleted = deleted
        self.read = read
        self.createdAt = createdAt
    }

    /// Whether the viewer wrote this one.
    public func isMine(viewerId: UUID?) -> Bool {
        guard let viewerId else { return false }
        return sender.id == viewerId
    }
}

/// The two counts, kept apart on purpose.
public struct MessageCounts: Hashable, Sendable {

    /// Unread messages in accepted threads — the badge.
    public let unread: Int
    /// Pending requests. Counted separately because a stranger must not be able
    /// to put a number on somebody's attention; the badge shows `unread` alone.
    public let requests: Int

    public init(unread: Int, requests: Int) {
        self.unread = unread
        self.requests = requests
    }

    public static let none = MessageCounts(unread: 0, requests: 0)
}

// MARK: - Decoding

extension Conversation: Decodable {

    private enum CodingKeys: String, CodingKey {
        case id, other, accepted, isRequest, unreadCount, lastMessageAt, lastMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        other = try container.decode(UserSummary.self, forKey: .other)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? true
        isRequest = try container.decodeIfPresent(Bool.self, forKey: .isRequest) ?? false
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        // Decoded as a Date, not a String: NetworkClient's decoder already
        // handles all three shapes the server emits — ISO8601 with fractional
        // seconds, plain ISO8601, and naive UTC with no Z. Parsing here would
        // be a fourth implementation that has to be kept in step with it.
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
    }
}

extension DirectMessage: Decodable {

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, sender, text, deleted, read, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        conversationId = try container.decode(UUID.self, forKey: .conversationId)
        sender = try container.decode(UserSummary.self, forKey: .sender)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? (text == nil)
        read = try container.decodeIfPresent(Bool.self, forKey: .read) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

extension MessageCounts: Decodable {

    private enum CodingKeys: String, CodingKey {
        case unread, requests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
    }
}
