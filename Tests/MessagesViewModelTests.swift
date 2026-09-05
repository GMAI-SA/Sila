import XCTest
@testable import Sila

/// The two message folders, and the rules that keep them apart.
///
/// The request folder is the whole point of this surface: a stranger may write
/// once, into a room the viewer has to open deliberately. Every test here is
/// really the same test — that nothing lets a stranger act as though they had
/// already been let in.
@MainActor
final class MessagesViewModelTests: XCTestCase {

    // MARK: - The list

    func testLoadFillsBothFoldersFromTheirOwnCalls() async {
        let model = makeList()
        await model.load()

        XCTAssertEqual(model.inbox.map(\.other.handle), ["noura"])
        XCTAssertEqual(model.requests.map(\.other.handle), ["stranger"])
        XCTAssertTrue(model.hasLoaded)
    }

    func testTheVisibleListFollowsTheChosenFolder() async {
        let model = makeList()
        await model.load()

        XCTAssertEqual(model.visible.map(\.other.handle), ["noura"])
        model.folder = .requests
        XCTAssertEqual(model.visible.map(\.other.handle), ["stranger"])
    }

    func testTheBadgeCountsTheInboxOnly() async {
        // The fixture has an unread request. If a stranger could raise the
        // badge, "requests" would be a folder in name only — the interruption
        // is the thing being withheld, not the row.
        let model = makeList()
        await model.load()

        XCTAssertEqual(model.counts.requests, 1)
        XCTAssertEqual(model.badgeCount, model.counts.unread)
        XCTAssertEqual(model.badgeCount, 2, "Only the accepted thread's two unread messages.")
    }

    func testAcceptingMovesTheThreadAndSaysSo() async {
        let model = makeList()
        await model.load()
        let request = XCTUnwrap2(model.requests.first)

        await model.accept(request)

        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.inbox.count, 2)
        XCTAssertEqual(model.toast?.kind, .success)
    }

    func testAFailedLoadReportsItselfAndKeepsTheScreenUsable() async {
        let model = ConversationsViewModel(
            service: FailingMessagesService(),
            analytics: RecordingAnalyticsClient()
        )
        await model.load()

        XCTAssertEqual(model.toast?.kind, .error)
        XCTAssertTrue(model.hasLoaded, "A failure is a finished load, not a permanent spinner.")
        XCTAssertTrue(model.inbox.isEmpty)
    }

    func testMarkingReadIsSkippedWhenThereIsNothingUnread() async {
        let service = CountingMessagesService()
        let model = ConversationsViewModel(service: service, analytics: RecordingAnalyticsClient())

        await model.markRead(conversation(unread: 0))
        let none = await service.markReadCalls
        XCTAssertEqual(none, 0)

        await model.markRead(conversation(unread: 3))
        let one = await service.markReadCalls
        XCTAssertEqual(one, 1)
    }

    // MARK: - One thread

    func testAnUnacceptedRequestCannotBeAnswered() async {
        // Replying *is* accepting. A composer that worked here would take that
        // decision away from the person the folder exists to protect.
        let model = ChatViewModel(
            conversation: conversation(isRequest: true, accepted: false),
            viewerId: UUID(),
            service: MessagesServiceMock()
        )
        model.draft = "hello"

        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.isSendable)
    }

    func testAnAcceptedThreadCanBeAnswered() {
        let model = ChatViewModel(
            conversation: conversation(isRequest: true, accepted: true),
            viewerId: UUID(),
            service: MessagesServiceMock()
        )
        model.draft = "hello"

        XCTAssertTrue(model.canSend)
        XCTAssertTrue(model.isSendable)
    }

    func testWhitespaceIsNotAMessage() {
        let model = makeChat()
        model.draft = "   \n  "
        XCTAssertFalse(model.isSendable)
    }

    func testAnOverlongDraftIsRefusedBeforeItIsSent() {
        let model = makeChat()
        model.draft = String(repeating: "ح", count: MessageConstants.maximumLength + 1)

        XCTAssertTrue(model.isOverLimit)
        XCTAssertEqual(model.remaining, -1)
        XCTAssertFalse(model.isSendable)
    }

    func testTheDraftSurvivesAFailedSend() async {
        let model = ChatViewModel(
            conversation: conversation(),
            viewerId: UUID(),
            service: FailingMessagesService()
        )
        model.draft = "words somebody typed"

        await model.send()

        XCTAssertEqual(model.draft, "words somebody typed", "A dropped connection must not eat it.")
        XCTAssertEqual(model.toast?.kind, .error)
    }

    func testASentDraftIsCleared() async {
        let service = MessagesServiceMock()
        let model = ChatViewModel(
            conversation: Conversation.mockThreads[0],
            viewerId: UUID(),
            service: service
        )
        model.draft = "  تمام  "

        await model.send()

        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertNil(model.toast)
        XCTAssertTrue(
            model.messages.contains { $0.text == "تمام" },
            "Trimmed, then sent — and the reload shows it."
        )
    }

    // MARK: - Deleting

    func testOnlyYourOwnUndeletedMessageCanBeDeleted() {
        let viewerId = UUID()
        let model = ChatViewModel(
            conversation: conversation(),
            viewerId: viewerId,
            service: MessagesServiceMock()
        )

        model.requestDeletion(of: message(senderId: UUID()))
        XCTAssertNil(model.pendingDeletion, "Somebody else's message is not yours to remove.")

        model.requestDeletion(of: message(senderId: viewerId, deleted: true))
        XCTAssertNil(model.pendingDeletion, "Already gone; there is nothing to confirm.")

        model.requestDeletion(of: message(senderId: viewerId))
        XCTAssertNotNil(model.pendingDeletion)
    }

    func testDeletionNeverClaimsTheMessageWasErased() async throws {
        let thread = Conversation.mockThreads[0]
        let service = MessagesServiceMock()
        let existing = try await service.fetchMessages(conversationId: thread.id)
        let mine = existing.first { $0.sender.handle == "you" }
        let model = ChatViewModel(
            conversation: thread,
            viewerId: XCTUnwrap2(mine).sender.id,
            service: service
        )
        await model.load()

        model.requestDeletion(of: XCTUnwrap2(mine))
        await model.confirmDeletion()

        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(model.toast?.kind, .success)
        // The row survives with its text blanked so a report keeps its
        // evidence. Copy that said "erased" would be a promise we do not keep.
        let copy = L10n.t("messages.deleted").lowercased()
        for word in ["erase", "permanently", "forever"] {
            XCTAssertFalse(copy.contains(word), "Deletion copy must not overpromise (\"\(word)\").")
        }
        XCTAssertTrue(
            model.messages.contains { $0.deleted },
            "The message is still in the thread, blanked — exactly as the server keeps it."
        )
    }

    // MARK: - Helpers

    private func makeList() -> ConversationsViewModel {
        ConversationsViewModel(service: MessagesServiceMock(), analytics: RecordingAnalyticsClient())
    }

    private func makeChat() -> ChatViewModel {
        ChatViewModel(
            conversation: conversation(),
            viewerId: UUID(),
            service: MessagesServiceMock()
        )
    }

    private func conversation(
        isRequest: Bool = false,
        accepted: Bool = true,
        unread: Int = 0
    ) -> Conversation {
        Conversation(
            id: UUID(),
            other: .mock(handle: "noura"),
            accepted: accepted,
            isRequest: isRequest,
            unreadCount: unread,
            lastMessageAt: Date(),
            lastMessage: "…"
        )
    }

    private func message(senderId: UUID, deleted: Bool = false) -> DirectMessage {
        var sender = UserSummary.mock(handle: "noura")
        sender = UserSummary(
            id: senderId,
            handle: sender.handle,
            displayName: sender.displayName,
            avatarURL: nil,
            isVerified: true,
            countryCode: "SA",
            verifiedSince: nil
        )
        return DirectMessage(
            id: UUID(),
            conversationId: UUID(),
            sender: sender,
            text: deleted ? nil : "hello",
            deleted: deleted,
            read: true,
            createdAt: Date()
        )
    }

    /// `XCTUnwrap` without the `throws`, for use inside non-throwing helpers.
    private func XCTUnwrap2<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected a value.", file: file, line: line)
            fatalError("Unreachable — XCTFail above ends the test.")
        }
        return value
    }
}

/// Answers every call with the same failure, for the paths that must survive one.
private actor FailingMessagesService: MessagesServiceProtocol {

    private let error = APIError.transport("The network connection was lost.")

    func fetchConversations() async throws -> [Conversation] { throw error }
    func fetchRequests() async throws -> [Conversation] { throw error }
    func fetchCounts() async throws -> MessageCounts { throw error }
    func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] { throw error }
    @discardableResult
    func send(to handle: String, text: String) async throws -> UUID { throw error }
    func accept(conversationId: UUID) async throws { throw error }
    func markRead(conversationId: UUID) async throws { throw error }
    func deleteMessage(id: UUID) async throws { throw error }
}

/// Counts what it was asked to do.
private actor CountingMessagesService: MessagesServiceProtocol {

    private(set) var markReadCalls = 0

    func fetchConversations() async throws -> [Conversation] { [] }
    func fetchRequests() async throws -> [Conversation] { [] }
    func fetchCounts() async throws -> MessageCounts { .none }
    func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] { [] }
    @discardableResult
    func send(to handle: String, text: String) async throws -> UUID { UUID() }
    func accept(conversationId: UUID) async throws {}
    func markRead(conversationId: UUID) async throws { markReadCalls += 1 }
    func deleteMessage(id: UUID) async throws {}
}
