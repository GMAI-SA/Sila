import Foundation

/// What the real-time socket told the app (contract v30), as the screens use it.
///
/// Every one of these is a reason to refresh sooner, never the only way to
/// learn something: the same facts are one HTTP call away, and every screen
/// keeps refreshing on foreground, on pull and on opening as it did before
/// the socket existed.
public enum RealtimeEvent: Sendable {

    /// The socket is up and says what it will carry. **Nothing is replayed**:
    /// whatever happened while it was down is only in the HTTP answers, so
    /// every screen refreshes once on this.
    case ready(RealtimeReady)
    /// A message, exactly as `GET /conversations/{id}/messages` shows it.
    case messageNew(RealtimeMessageNew)
    /// Somebody read a thread up to a moment.
    case messageRead(RealtimeMessageRead)
    /// A message was deleted for both people.
    case messageDeleted(RealtimeMessageDeleted)
    /// The other person in a thread is typing, or stopped.
    case typing(RealtimeTyping)
    /// A notification row was written; the badge is its count.
    case notificationNew(RealtimeNotificationNew)
    /// The account as `GET /auth/me` returns it now — a verification or a
    /// vouch changed. The one event an account at the wall hears.
    case accountStatus(AuthUser)
    /// A typing frame was refused, with the code a send would get. The socket
    /// stays open; the thread stops saying it is typing.
    case typingRefused(code: String, conversationId: UUID?)
    /// Real time cannot be offered now (`1013`): refresh as before it existed.
    case unavailable
    /// The socket went away. Nothing arrives until the next ``ready``.
    case disconnected
}

/// `ready`: the socket is live.
public struct RealtimeReady: Sendable, Equatable, Decodable {
    public let connectionId: String?
    public let userId: UUID?
    /// `verified`, `vouched` or `none` (the wall).
    public let standing: String
    /// The event types this socket carries for that standing.
    public let events: [String]
    public let heartbeatSeconds: Int
    public let typingSeconds: Int
    public let tokenExpiresAt: Date?

    public init(
        connectionId: String? = nil,
        userId: UUID? = nil,
        standing: String,
        events: [String],
        heartbeatSeconds: Int = 25,
        typingSeconds: Int = 6,
        tokenExpiresAt: Date? = nil
    ) {
        self.connectionId = connectionId
        self.userId = userId
        self.standing = standing
        self.events = events
        self.heartbeatSeconds = heartbeatSeconds
        self.typingSeconds = typingSeconds
        self.tokenExpiresAt = tokenExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case connectionId, userId, standing, events, heartbeatSeconds, typingSeconds, tokenExpiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionId = try container.decodeIfPresent(String.self, forKey: .connectionId)
        userId = try container.decodeIfPresent(UUID.self, forKey: .userId)
        standing = try container.decodeIfPresent(String.self, forKey: .standing) ?? "none"
        events = try container.decodeIfPresent([String].self, forKey: .events) ?? []
        heartbeatSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatSeconds) ?? 25
        typingSeconds = try container.decodeIfPresent(Int.self, forKey: .typingSeconds) ?? 6
        tokenExpiresAt = try container.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
    }
}

/// `message.new`.
public struct RealtimeMessageNew: Sendable, Equatable, Decodable {

    /// How the receiving account's inbox files the thread.
    public struct Filing: Sendable, Equatable, Decodable {
        public let id: UUID
        public let accepted: Bool
        /// `true` for a stranger's thread this account has not accepted.
        public let isRequest: Bool

        public init(id: UUID, accepted: Bool, isRequest: Bool) {
            self.id = id
            self.accepted = accepted
            self.isRequest = isRequest
        }

        private enum CodingKeys: String, CodingKey { case id, accepted, isRequest }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? true
            isRequest = try container.decodeIfPresent(Bool.self, forKey: .isRequest) ?? false
        }
    }

    public let conversationId: UUID
    public let message: DirectMessage
    public let conversation: Filing
    /// `true` only where a push is sent: never for a request, never from a
    /// muted sender, never the sender's own copy. Nothing in the app makes a
    /// sound or a banner of its own; the push does that, and only then.
    public let alert: Bool

    public init(conversationId: UUID, message: DirectMessage, conversation: Filing, alert: Bool) {
        self.conversationId = conversationId
        self.message = message
        self.conversation = conversation
        self.alert = alert
    }

    private enum CodingKeys: String, CodingKey { case conversationId, message, conversation, alert }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(DirectMessage.self, forKey: .message)
        conversationId = try container.decodeIfPresent(UUID.self, forKey: .conversationId) ?? message.conversationId
        conversation = try container.decodeIfPresent(Filing.self, forKey: .conversation)
            ?? Filing(id: conversationId, accepted: true, isRequest: false)
        alert = try container.decodeIfPresent(Bool.self, forKey: .alert) ?? false
    }
}

/// `message.read`: `readerId` read the thread up to `readAt`.
public struct RealtimeMessageRead: Sendable, Equatable, Decodable {
    public let conversationId: UUID
    public let readerId: UUID
    public let readAt: Date

    public init(conversationId: UUID, readerId: UUID, readAt: Date) {
        self.conversationId = conversationId
        self.readerId = readerId
        self.readAt = readAt
    }
}

/// `message.deleted`.
public struct RealtimeMessageDeleted: Sendable, Equatable, Decodable {
    public let conversationId: UUID
    public let messageId: UUID

    public init(conversationId: UUID, messageId: UUID) {
        self.conversationId = conversationId
        self.messageId = messageId
    }
}

/// `typing`: `userId` is typing in `conversationId` for `expiresIn` seconds
/// after this, unless renewed, ended, or answered by their message.
public struct RealtimeTyping: Sendable, Equatable, Decodable {
    public let conversationId: UUID
    public let userId: UUID
    public let active: Bool
    public let expiresIn: Int

    public init(conversationId: UUID, userId: UUID, active: Bool, expiresIn: Int) {
        self.conversationId = conversationId
        self.userId = userId
        self.active = active
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey { case conversationId, userId, active, expiresIn }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try container.decode(UUID.self, forKey: .conversationId)
        userId = try container.decode(UUID.self, forKey: .userId)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? (active ? 6 : 0)
    }
}

/// `notification.new`: the badge is `unreadCount`, exactly
/// `GET /notifications/unread-count`'s `unread` at that moment.
public struct RealtimeNotificationNew: Sendable, Equatable, Decodable {
    public let id: UUID
    public let kind: String
    public let unreadCount: Int

    public init(id: UUID, kind: String, unreadCount: Int) {
        self.id = id
        self.kind = kind
        self.unreadCount = unreadCount
    }
}

// MARK: - Frames

/// One JSON frame from the server, before the client acts on it: the
/// protocol's own frames (`ping`, `auth_ok`, `reauth_required`, `error`)
/// and the events the screens receive.
enum RealtimeFrame: Sendable {
    case ping
    case pong
    case authOK(standing: String?, tokenExpiresAt: Date?)
    case reauthRequired
    /// An `error` frame: a refusal before a close, or a typing refusal.
    case error(code: String, ref: String?, conversationId: UUID?)
    case event(RealtimeEvent)
    /// A type this client does not know — later contracts add events, and
    /// clients must ignore them.
    case unknown(String)

    /// Reads one text frame. `nil` for anything that is not a JSON object
    /// with a `type`, or an event whose body does not decode.
    static func parse(_ text: String) -> RealtimeFrame? {
        let data = Data(text.utf8)
        guard let head = try? JSONCoding.decoder.decode(Head.self, from: data) else { return nil }
        let decoder = JSONCoding.decoder
        switch head.type {
        case "ping": return .ping
        case "pong": return .pong
        case "auth_ok":
            let body = try? decoder.decode(AuthOK.self, from: data)
            return .authOK(standing: body?.standing, tokenExpiresAt: body?.tokenExpiresAt)
        case "reauth_required": return .reauthRequired
        case "error":
            let body = try? decoder.decode(ErrorBody.self, from: data)
            return .error(code: body?.code ?? "unknown", ref: body?.ref, conversationId: body?.conversationId)
        case "ready":
            return (try? decoder.decode(RealtimeReady.self, from: data)).map { .event(.ready($0)) }
        case "message.new":
            return (try? decoder.decode(RealtimeMessageNew.self, from: data)).map { .event(.messageNew($0)) }
        case "message.read":
            return (try? decoder.decode(RealtimeMessageRead.self, from: data)).map { .event(.messageRead($0)) }
        case "message.deleted":
            return (try? decoder.decode(RealtimeMessageDeleted.self, from: data)).map { .event(.messageDeleted($0)) }
        case "typing":
            return (try? decoder.decode(RealtimeTyping.self, from: data)).map { .event(.typing($0)) }
        case "notification.new":
            return (try? decoder.decode(RealtimeNotificationNew.self, from: data)).map { .event(.notificationNew($0)) }
        case "account.status":
            return (try? decoder.decode(AccountStatus.self, from: data)).map { .event(.accountStatus($0.me)) }
        default:
            return .unknown(head.type)
        }
    }

    private struct Head: Decodable { let type: String }
    private struct AuthOK: Decodable { let standing: String?; let tokenExpiresAt: Date? }
    private struct AccountStatus: Decodable { let me: AuthUser }

    private struct ErrorBody: Decodable {
        let code: String?
        let ref: String?
        let conversationId: UUID?

        private enum CodingKeys: String, CodingKey { case code, ref, conversationId }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decodeIfPresent(String.self, forKey: .code)
            ref = try container.decodeIfPresent(String.self, forKey: .ref)
            // Tolerant: a malformed id in a refusal must not lose the refusal.
            conversationId = try? container.decodeIfPresent(UUID.self, forKey: .conversationId)
        }
    }
}

/// What the client sends. Encoded here, once, so a test can read the exact
/// bytes that would go over the wire.
enum RealtimeOutgoing {

    static func auth(token: String) -> String {
        encode(["type": "auth", "token": token])
    }

    static let pong = #"{"type":"pong"}"#
    static let ping = #"{"type":"ping"}"#

    static func typing(conversationId: UUID, active: Bool) -> String {
        var frame: [String: Any] = ["type": "typing", "conversation_id": conversationId.uuidString.lowercased()]
        if !active { frame["active"] = false }
        return encode(frame)
    }

    private static func encode(_ frame: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
