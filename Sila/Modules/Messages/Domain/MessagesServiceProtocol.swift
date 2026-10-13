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

    /// Whether the other person is typing now, `GET /conversations/{id}/typing`
    /// (contract v30) — for a thread just opened, or after the socket
    /// reconnects between two `typing` events. Always "no" in a request, for
    /// somebody the viewer muted, and when real time is unavailable.
    func fetchTyping(conversationId: UUID) async throws -> TypingStatus

    // MARK: Pictures and documents (contract v39)

    /// `GET /config` → `chat_files`. ``ChatFilesConfig/off`` when the server
    /// says nothing.
    func fetchChatFilesConfig() async throws -> ChatFilesConfig

    /// Sends words, files or both. With no files this is ``send(to:text:)``.
    @discardableResult
    func send(to handle: String, text: String, attachmentIds: [UUID]) async throws -> UUID

    /// `POST /messages/attachments` — where the bytes go.
    func startAttachment(_ request: ChatAttachmentRequest) async throws -> ChatAttachmentStart

    /// PUTs `file` as the plan says. `progress` is `0…1` of the bytes sent.
    func uploadAttachment(
        _ upload: ChatAttachmentUpload,
        file: URL,
        sizeBytes: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// `POST /messages/attachments/{id}/complete`.
    func completeAttachment(id: UUID) async throws -> ChatAttachment

    /// `DELETE /messages/attachments/{id}` — a file taken out before sending.
    func discardAttachment(id: UUID) async throws

    /// `GET /messages/attachments/{id}` — the same file with fresh URLs.
    func fetchAttachment(id: UUID) async throws -> ChatAttachment

    /// A picture's bytes (its 512 px thumbnail when `thumbnail`), asking for
    /// fresh URLs when they have run out.
    func attachmentData(_ attachment: ChatAttachment, thumbnail: Bool) async throws -> Data

    /// Downloads a document to a temporary file named as it was sent.
    func downloadAttachment(_ attachment: ChatAttachment) async throws -> URL
}

extension MessagesServiceProtocol {
    /// Nobody is typing where there is no server to say otherwise.
    public func fetchTyping(conversationId: UUID) async throws -> TypingStatus { .notTyping }
}

/// Files are off wherever a service does not implement them — the mocks, and
/// the tests' scripted servers: no attach button, and words go as before.
extension MessagesServiceProtocol {

    private var filesOff: APIError { .api(code: .chatFilesOff, message: "", status: 503) }

    public func fetchChatFilesConfig() async throws -> ChatFilesConfig { .off }

    @discardableResult
    public func send(to handle: String, text: String, attachmentIds: [UUID]) async throws -> UUID {
        guard attachmentIds.isEmpty else { throw filesOff }
        return try await send(to: handle, text: text)
    }

    public func startAttachment(_ request: ChatAttachmentRequest) async throws -> ChatAttachmentStart { throw filesOff }

    public func uploadAttachment(
        _ upload: ChatAttachmentUpload,
        file: URL,
        sizeBytes: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws { throw filesOff }

    public func completeAttachment(id: UUID) async throws -> ChatAttachment { throw filesOff }

    public func discardAttachment(id: UUID) async throws {}

    public func fetchAttachment(id: UUID) async throws -> ChatAttachment { throw filesOff }

    public func attachmentData(_ attachment: ChatAttachment, thumbnail: Bool) async throws -> Data { throw filesOff }

    public func downloadAttachment(_ attachment: ChatAttachment) async throws -> URL { throw filesOff }
}

/// Limits from the messaging contract.
public enum MessageConstants {
    /// The server's maximum message length; longer bodies answer 422.
    public static let maximumLength = 4_000
}
