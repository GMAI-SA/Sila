import Foundation

/// Everything the Messages module can ask the backend to do.
///
/// **Sending is addressed by handle, not by conversation id.** The server
/// creates the thread on first use, and there is exactly one per pair. A
/// client that had to create a conversation first would have to decide what to
/// do when two devices created one simultaneously — the server already answers
/// that with a uniqueness constraint, and addressing by handle is what lets it.
public protocol MessagesServiceProtocol: Sendable {

    /// The accepted threads, `GET /conversations`.
    func fetchConversations() async throws -> [Conversation]

    /// The request folder, `GET /conversations?requests=true`.
    ///
    /// Separate from ``fetchConversations()`` rather than a Bool parameter on
    /// it: these are two different rooms, and a screen that passed the wrong
    /// flag would silently show strangers where the inbox should be.
    func fetchRequests() async throws -> [Conversation]

    /// Both counts, `GET /conversations/unread-count`.
    func fetchCounts() async throws -> MessageCounts

    /// One thread's messages, oldest first.
    func fetchMessages(conversationId: UUID) async throws -> [DirectMessage]

    /// Sends to `handle`, creating the conversation if this is the first message.
    /// - Returns: The conversation it landed in.
    @discardableResult
    func send(to handle: String, text: String) async throws -> UUID

    /// Accepts a request, moving it into the inbox.
    func accept(conversationId: UUID) async throws

    /// Marks a thread read.
    func markRead(conversationId: UUID) async throws

    /// Deletes one of the viewer's own messages.
    ///
    /// The row survives on the server with its text blanked, so a report about
    /// it keeps its evidence. Nothing in this client should describe it as
    /// erased.
    func deleteMessage(id: UUID) async throws
}

/// Limits from the messaging contract.
public enum MessageConstants {
    /// The server's maximum message length; longer bodies answer 422.
    public static let maximumLength = 4_000
}
