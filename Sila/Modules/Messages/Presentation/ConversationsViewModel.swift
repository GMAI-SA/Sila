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

    public init(service: MessagesServiceProtocol, analytics: AnalyticsClient) {
        self.service = service
        self.analytics = analytics
    }

    public var visible: [Conversation] {
        folder == .inbox ? inbox : requests
    }

    /// The badge. Requests are excluded on purpose — a stranger must not be
    /// able to put a number on somebody's attention.
    public var badgeCount: Int { counts.unread }

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
            toast = .error(APIError.wrapping(error).userMessage)
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
            toast = .error(APIError.wrapping(error).userMessage)
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
}
