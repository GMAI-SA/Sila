import Foundation
import Observation

/// One open thread.
@MainActor
@Observable
public final class ChatViewModel {

    public private(set) var messages: [DirectMessage] = []
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public var draft = ""
    public var toast: SLToastMessage?
    /// Set when the person deleting one of their own messages needs to confirm.
    public var pendingDeletion: DirectMessage?

    public let conversation: Conversation
    private let viewerId: UUID?
    private let service: MessagesServiceProtocol

    public init(conversation: Conversation, viewerId: UUID?, service: MessagesServiceProtocol) {
        self.conversation = conversation
        self.viewerId = viewerId
        self.service = service
    }

    /// Whether the composer is usable.
    ///
    /// A request the viewer has not accepted is readable but not answerable:
    /// replying **is** accepting, and doing that silently would take the
    /// decision away from the person the folder exists to protect.
    public var canSend: Bool {
        conversation.accepted || !conversation.isRequest
    }

    public var isOverLimit: Bool {
        draft.count > MessageConstants.maximumLength
    }

    public var remaining: Int {
        MessageConstants.maximumLength - draft.count
    }

    public var isSendable: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isOverLimit
            && !isSending
            && canSend
    }

    public func isMine(_ message: DirectMessage) -> Bool {
        message.isMine(viewerId: viewerId)
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await service.fetchMessages(conversationId: conversation.id)
            try? await service.markRead(conversationId: conversation.id)
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSendable else { return }

        isSending = true
        defer { isSending = false }
        do {
            // Addressed by handle: the server owns the one-thread-per-pair rule.
            try await service.send(to: conversation.other.handle, text: text)
            // Cleared only after the server accepted it. Clearing first would
            // lose somebody's words to a dropped connection.
            draft = ""
            await load()
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Asks before deleting, because there is no undo.
    public func requestDeletion(of message: DirectMessage) {
        guard isMine(message), !message.deleted else { return }
        pendingDeletion = message
    }

    public func confirmDeletion() async {
        guard let message = pendingDeletion else { return }
        pendingDeletion = nil
        do {
            try await service.deleteMessage(id: message.id)
            await load()
            // "Removed", not "erased": the server keeps the row with its text
            // blanked so a report about it still has its evidence, and telling
            // somebody otherwise would be a promise this platform cannot keep.
            toast = .success(L10n.t("messages.deleted"))
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }
}
