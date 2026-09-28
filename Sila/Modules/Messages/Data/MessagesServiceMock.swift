import Foundation

/// An in-memory ``MessagesServiceProtocol`` for previews, UI tests and unit
/// tests.
///
/// Models the one rule that makes this surface worth testing without a server:
/// a message from somebody the viewer does not follow lands in the **request**
/// folder and is counted apart from the inbox. A mock that put every thread in
/// one list would let a screen pass its tests while showing strangers where the
/// inbox should be.
public actor MessagesServiceMock: MessagesServiceProtocol {

    private var conversations: [Conversation]
    private var messages: [UUID: [DirectMessage]]
    private let viewer: UserSummary
    /// Handles the viewer follows — the mock's stand-in for "we already know
    /// each other", which is what lets a thread skip the request folder.
    private var known: Set<String>
    /// Told about every message the viewer sends — how the mocked socket
    /// (``RealtimeServerMock``) answers one the way a person would.
    private var onSent: (@Sendable (DirectMessage, Conversation) -> Void)?

    public init(
        viewer: UserSummary = .mockViewer,
        conversations: [Conversation] = Conversation.mockThreads,
        messages: [UUID: [DirectMessage]] = DirectMessage.mockThreads,
        known: Set<String> = ["noura"]
    ) {
        self.viewer = viewer
        self.conversations = conversations
        self.messages = messages
        self.known = known
    }

    public func fetchConversations() async throws -> [Conversation] {
        onInboxRead?()
        return conversations.filter { !$0.isRequest }.sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    public func fetchRequests() async throws -> [Conversation] {
        conversations.filter(\.isRequest)
    }

    public func fetchCounts() async throws -> MessageCounts {
        MessageCounts(
            unread: conversations.filter { !$0.isRequest }.reduce(0) { $0 + $1.unreadCount },
            requests: conversations.filter(\.isRequest).count
        )
    }

    public func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] {
        messages[conversationId] ?? []
    }

    @discardableResult
    public func send(to handle: String, text: String) async throws -> UUID {
        let existing = conversations.first { $0.other.handle == handle }
        let id = existing?.id ?? UUID()

        if existing == nil {
            conversations.append(
                Conversation(
                    id: id,
                    other: UserSummary.mock(handle: handle),
                    accepted: known.contains(handle),
                    // A thread the viewer *starts* is never their own request,
                    // whichever folder it lands in for the other person.
                    isRequest: false,
                    unreadCount: 0,
                    lastMessageAt: Date(),
                    lastMessage: text
                )
            )
        }

        let message = DirectMessage(
            id: UUID(),
            conversationId: id,
            sender: viewer,
            text: text,
            deleted: false,
            // Unread until the other person reads it, as the server has it.
            read: false,
            createdAt: Date()
        )
        messages[id, default: []].append(message)
        conversations = conversations.map { thread in
            thread.id == id ? thread.with(lastMessageAt: message.createdAt, lastMessage: .some(text)) : thread
        }
        if let thread = conversations.first(where: { $0.id == id }) {
            onSent?(message, thread)
        }
        return id
    }

    // MARK: - The other side, for the mocked socket

    public func setOnSent(_ handler: (@Sendable (DirectMessage, Conversation) -> Void)?) {
        onSent = handler
    }

    /// Told whenever the inbox is read — the moment somebody is looking at it.
    private var onInboxRead: (@Sendable () -> Void)?

    public func setOnInboxRead(_ handler: (@Sendable () -> Void)?) {
        onInboxRead = handler
    }

    /// The thread with `handle`, as this store has it now.
    public func conversation(with handle: String) -> Conversation? {
        conversations.first { $0.other.handle == handle }
    }

    /// `handle` writes to the viewer: the message lands in the thread and
    /// its preview, and counts as unread — exactly what a real message does
    /// to what `GET /conversations` answers next.
    public func receive(from handle: String, text: String) -> (Conversation, DirectMessage)? {
        guard let thread = conversations.first(where: { $0.other.handle == handle }) else { return nil }
        let message = DirectMessage(
            id: UUID(),
            conversationId: thread.id,
            sender: thread.other,
            text: text,
            deleted: false,
            read: false,
            createdAt: Date()
        )
        messages[thread.id, default: []].append(message)
        let updated = thread.with(unreadCount: thread.unreadCount + 1, lastMessageAt: message.createdAt, lastMessage: .some(text))
        conversations = conversations.map { $0.id == thread.id ? updated : $0 }
        return (updated, message)
    }

    /// The other person read the thread: every message of the viewer's in it
    /// is read now.
    public func otherPersonRead(conversationId: UUID) {
        messages[conversationId] = messages[conversationId]?.map { message in
            message.sender.id == viewer.id ? message.markedRead() : message
        }
    }

    public func accept(conversationId: UUID) async throws {
        conversations = conversations.map { thread in
            guard thread.id == conversationId else { return thread }
            return Conversation(
                id: thread.id,
                other: thread.other,
                accepted: true,
                isRequest: false,
                unreadCount: thread.unreadCount,
                lastMessageAt: thread.lastMessageAt,
                lastMessage: thread.lastMessage
            )
        }
    }

    public func markRead(conversationId: UUID) async throws {
        conversations = conversations.map { thread in
            guard thread.id == conversationId else { return thread }
            return Conversation(
                id: thread.id,
                other: thread.other,
                accepted: thread.accepted,
                isRequest: thread.isRequest,
                unreadCount: 0,
                lastMessageAt: thread.lastMessageAt,
                lastMessage: thread.lastMessage
            )
        }
    }

    public func deleteMessage(id: UUID) async throws {
        for (thread, list) in messages {
            messages[thread] = list.map { message in
                guard message.id == id else { return message }
                // Blanked, not removed — exactly what the server does, so a
                // screen that assumed deletion meant absence fails here rather
                // than in production.
                return DirectMessage(
                    id: message.id,
                    conversationId: message.conversationId,
                    sender: message.sender,
                    text: nil,
                    deleted: true,
                    read: message.read,
                    createdAt: message.createdAt
                )
            }
        }
    }
}

// MARK: - Fixtures

extension UserSummary {

    /// The mocked session's own account: the same id `AuthServiceMock`
    /// signs in with, so a mocked thread knows which bubbles are the viewer's.
    public static let mockViewer = UserSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        handle: "you",
        displayName: "You",
        avatarURL: nil,
        isVerified: true,
        countryCode: "SA",
        verifiedSince: nil
    )

    public static func mock(handle: String, displayName: String? = nil) -> UserSummary {
        UserSummary(
            id: UUID(),
            handle: handle,
            displayName: displayName ?? handle.capitalized,
            avatarURL: nil,
            isVerified: true,
            countryCode: "SA",
            verifiedSince: nil
        )
    }
}

extension Conversation {

    /// One accepted thread and one waiting request — the two states the screen
    /// has to keep apart.
    public static let mockThreads: [Conversation] = {
        [
            Conversation(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
                other: .mock(handle: "noura", displayName: "نورة"),
                accepted: true,
                isRequest: false,
                unreadCount: 2,
                lastMessageAt: Date(timeIntervalSinceNow: -600),
                lastMessage: "تمام، أشوفك بكرة"
            ),
            Conversation(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!,
                other: .mock(handle: "stranger"),
                accepted: false,
                isRequest: true,
                unreadCount: 1,
                lastMessageAt: Date(timeIntervalSinceNow: -7_200),
                lastMessage: "Hello, are you interested in an investment?"
            )
        ]
    }()
}

extension DirectMessage {

    public static let mockThreads: [UUID: [DirectMessage]] = {
        let thread = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let noura = UserSummary.mock(handle: "noura", displayName: "نورة")
        return [
            thread: [
                DirectMessage(
                    id: UUID(),
                    conversationId: thread,
                    sender: noura,
                    text: "السلام عليكم",
                    deleted: false,
                    read: true,
                    createdAt: Date(timeIntervalSinceNow: -900)
                ),
                DirectMessage(
                    id: UUID(),
                    conversationId: thread,
                    sender: .mockViewer,
                    text: "وعليكم السلام",
                    deleted: false,
                    read: true,
                    createdAt: Date(timeIntervalSinceNow: -800)
                )
            ]
        ]
    }()
}
