import Foundation
import Observation

/// The conversation list, in two folders.
@MainActor
@Observable
public final class ConversationsViewModel {

    /// Which room the list is showing. Two folders, never one list with a
    /// filter: the inbox is people you accepted and the requests folder is
    /// people you have not, and blurring them is the whole harassment vector
    /// this design exists to close.
    public enum Folder: String, CaseIterable, Identifiable, Sendable {
        case inbox
        case requests

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .inbox: return L10n.t("messages.folder.inbox")
            case .requests: return L10n.t("messages.folder.requests")
            }
        }

        public var accessibilityHint: String {
            switch self {
            case .inbox: return L10n.t("messages.folder.inbox.hint")
            case .requests: return L10n.t("messages.folder.requests.hint")
            }
        }
    }

    public private(set) var inbox: [Conversation] = []
    public private(set) var requests: [Conversation] = []
    public private(set) var counts: MessageCounts = .none
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public var folder: Folder = .inbox
    public var toast: SLToastMessage?

    private let service: MessagesServiceProtocol
    private let analytics: AnalyticsClient
    /// Who is typing where (contract v30), for "Noura is typing…" on a row.
    public let typing: TypingBoard?
    /// The signed-in account — whose messages do not count as unread.
    private let viewerId: @MainActor () -> UUID?

    public init(
        service: MessagesServiceProtocol,
        analytics: AnalyticsClient,
        typing: TypingBoard? = nil,
        viewerId: @escaping @MainActor () -> UUID? = { nil }
    ) {
        self.service = service
        self.analytics = analytics
        self.typing = typing
        self.viewerId = viewerId
    }

    /// "Noura is typing…" in place of the row's preview, while she is.
    public func typingLine(for conversation: Conversation) -> String? {
        guard let typing, typing.isTyping(in: conversation.id, by: conversation.other.id) else { return nil }
        return L10n.t("messages.typing.row", conversation.other.displayName)
    }

    public var visible: [Conversation] {
        folder == .inbox ? inbox : requests
    }

    /// The badge. Requests are excluded on purpose — a stranger must not be
    /// able to put a number on somebody's attention.
    public var badgeCount: Int { counts.unread }

    /// The thread with somebody, when one has already been read.
    public func conversation(with handle: String) -> Conversation? {
        let target = Handle.normalised(handle)
        return (inbox + requests).first { Handle.normalised($0.other.handle) == target }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        do {
            // Both folders and the counts together: switching tabs must not
            // issue a request, and the counts must agree with the lists that
            // are on screen rather than with a different moment in time.
            async let inboxTask = service.fetchConversations()
            async let requestsTask = service.fetchRequests()
            async let countsTask = service.fetchCounts()
            inbox = try await inboxTask
            requests = try await requestsTask
            counts = try await countsTask
            analytics.track(.messagesOpened, properties: ["folder": folder.rawValue])
        } catch {
            toast = .error(for: error)
        }
    }

    public func accept(_ conversation: Conversation) async {
        do {
            try await service.accept(conversationId: conversation.id)
            // Reload rather than move the row locally: acceptance changes both
            // folders and both counts, and a list that reasoned about it
            // itself would be a second implementation of the server's rule.
            await load()
            toast = .success(L10n.t("messages.request.accepted"))
        } catch {
            toast = .error(for: error)
        }
    }

    /// Clears a thread's unread state after it has been read.
    public func markRead(_ conversation: Conversation) async {
        guard conversation.unreadCount > 0 else { return }
        do {
            try await service.markRead(conversationId: conversation.id)
            await load()
        } catch {
            // Deliberately silent: failing to clear a badge is not worth
            // interrupting somebody who is reading.
        }
    }

    /// Refreshes just the badge, for when the list is not on screen.
    public func refreshCounts() async {
        counts = (try? await service.fetchCounts()) ?? counts
    }

    // MARK: - Real time

    /// One event from the socket (contract v30).
    ///
    /// A message moves its row to the top with its words and its count at
    /// once; anything the rows cannot say by themselves — a thread this list
    /// has never seen, a deletion that may have been the preview — is read
    /// again from the server, quietly. The folders are never decided here:
    /// `is_request` comes from the server, as the inbox files it.
    public func apply(_ event: RealtimeEvent) async {
        switch event {
        case .ready, .unavailable:
            // Nothing is replayed; the lists and the badge are read again.
            if hasLoaded { await refreshQuietly() } else { await refreshCounts() }
        case let .messageNew(new):
            await messageArrived(new)
        case let .messageRead(read):
            guard read.readerId == viewerId() else { return }
            // Read on this device or another: the thread's count clears.
            clearUnread(in: read.conversationId)
        case .messageDeleted:
            if hasLoaded { await refreshQuietly() }
        case .typing, .typingRefused, .notificationNew, .accountStatus, .disconnected:
            break
        }
    }

    private func messageArrived(_ new: RealtimeMessageNew) async {
        let mine = new.message.sender.id == viewerId()
        let inInbox = inbox.firstIndex { $0.id == new.conversationId }
        let inRequests = requests.firstIndex { $0.id == new.conversationId }
        let filedAsRequest = new.conversation.isRequest
        // A thread this list has not seen, or one that moved folders: the
        // server's lists are the answer. Only the badge needs a list loaded.
        guard hasLoaded, let current = inInbox.map({ inbox[$0] }) ?? inRequests.map({ requests[$0] }),
              current.isRequest == filedAsRequest else {
            if hasLoaded { await refreshQuietly() } else if !mine && !filedAsRequest { counts = counts.adding(unread: 1) }
            return
        }
        let updated = current.with(
            accepted: new.conversation.accepted,
            isRequest: filedAsRequest,
            unreadCount: current.unreadCount + (mine ? 0 : 1),
            lastMessageAt: new.message.createdAt,
            lastMessage: .some(new.message.deleted ? nil : new.message.text)
        )
        if filedAsRequest {
            requests.removeAll { $0.id == updated.id }
            requests.insert(updated, at: 0)
        } else {
            inbox.removeAll { $0.id == updated.id }
            inbox.insert(updated, at: 0)
            if !mine { counts = counts.adding(unread: 1) }
        }
    }

    private func clearUnread(in conversationId: UUID) {
        if let index = inbox.firstIndex(where: { $0.id == conversationId }) {
            let cleared = inbox[index].unreadCount
            inbox[index] = inbox[index].with(unreadCount: 0)
            counts = counts.adding(unread: -cleared)
        } else if let index = requests.firstIndex(where: { $0.id == conversationId }) {
            requests[index] = requests[index].with(unreadCount: 0)
        } else {
            Task { await refreshCounts() }
        }
    }

    /// Both folders and the counts again, with no spinner and no error: the
    /// screen keeps what it shows if the server cannot be reached.
    public func refreshQuietly() async {
        guard !isLoading else { return }
        do {
            async let inboxTask = service.fetchConversations()
            async let requestsTask = service.fetchRequests()
            async let countsTask = service.fetchCounts()
            let (freshInbox, freshRequests, freshCounts) = try await (inboxTask, requestsTask, countsTask)
            inbox = freshInbox
            requests = freshRequests
            counts = freshCounts
        } catch {
            // Deliberately silent: this refresh was nobody's request.
        }
    }
}

extension MessageCounts {
    /// The unread badge moved by `delta`, never below zero.
    func adding(unread delta: Int) -> MessageCounts {
        MessageCounts(unread: max(0, unread + delta), requests: requests)
    }
}
