import XCTest
@testable import Sila

/// What the screens do with the socket's events (contract v30): a message in
/// the thread and the inbox at once, the read receipt, "typing…" both ways,
/// the notification badge, and the wall moving on `account.status`.
@MainActor
final class RealtimeMessagingTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private let viewer = UserSummary.mockViewer
    private var thread: Conversation { Conversation.mockThreads[0] }   // @noura, accepted
    private var request: Conversation { Conversation.mockThreads[1] }  // @stranger, a request

    private func incoming(
        _ text: String?,
        in conversation: Conversation? = nil,
        from sender: UserSummary? = nil,
        id: UUID = UUID(),
        at date: Date = Date(),
        isRequest: Bool = false,
        accepted: Bool? = nil
    ) -> RealtimeEvent {
        let conversation = conversation ?? thread
        let message = DirectMessage(
            id: id,
            conversationId: conversation.id,
            sender: sender ?? conversation.other,
            text: text,
            deleted: text == nil,
            read: false,
            createdAt: date
        )
        return .messageNew(RealtimeMessageNew(
            conversationId: conversation.id,
            message: message,
            conversation: .init(id: conversation.id, accepted: accepted ?? !isRequest, isRequest: isRequest),
            alert: !isRequest
        ))
    }

    private func chat(
        _ conversation: Conversation? = nil,
        service: SpyMessages = SpyMessages(),
        realtime: FakeRealtime? = nil,
        typing: TypingBoard? = nil,
        clock: TestClock = TestClock()
    ) -> ChatViewModel {
        ChatViewModel(
            conversation: conversation ?? thread,
            viewerId: viewer.id,
            service: service,
            realtime: realtime ?? FakeRealtime(),
            typing: typing ?? TypingBoard(),
            now: { clock.now }
        )
    }

    // MARK: - The thread

    func testANewMessageAppearsOnceAndIsReadWhileTheThreadIsOnScreen() async {
        let service = SpyMessages()
        let model = chat(service: service)
        await model.load()
        await model.screenAppeared()
        let before = model.messages.count
        let reads = await service.markReadCalls

        let id = UUID()
        await model.apply(incoming("On my way", id: id))
        await model.apply(incoming("On my way", id: id))   // the same one again

        XCTAssertEqual(model.messages.count, before + 1, "a message is matched on its id, once")
        XCTAssertEqual(model.messages.last?.text, "On my way")
        let after = await service.markReadCalls
        XCTAssertEqual(after, reads + 1, "a message on screen is read as it arrives, once")
    }

    func testAMessageForAnotherThreadIsNotThisOnes() async {
        let model = chat()
        await model.load()
        let before = model.messages
        await model.apply(incoming("elsewhere", in: request))
        XCTAssertEqual(model.messages, before)
    }

    func testAMessageArrivingOffScreenIsReadWhenTheThreadComesBack() async {
        let service = SpyMessages()
        let model = chat(service: service)
        await model.load()
        await model.screenAppeared()
        model.screenDisappeared()   // a profile pushed over it
        let reads = await service.markReadCalls

        await model.apply(incoming("while you were away"))
        let unchanged = await service.markReadCalls
        XCTAssertEqual(unchanged, reads, "nobody has read it yet")

        await model.screenAppeared()
        let read = await service.markReadCalls
        XCTAssertEqual(read, reads + 1)
    }

    func testTheViewersOwnCopyFromAnotherDeviceSlotsIntoPlace() async {
        let model = chat()
        await model.load()
        // Between the two fixture messages.
        let first = model.messages[0].createdAt, second = model.messages[1].createdAt
        let earlier = first.addingTimeInterval(second.timeIntervalSince(first) / 2)
        await model.apply(incoming("from my laptop", from: viewer, at: earlier))
        XCTAssertEqual(model.messages.map(\.text), ["السلام عليكم", "from my laptop", "وعليكم السلام"],
                       "kept in time order, not appended")
    }

    func testTheReadReceiptMarksTheViewersMessagesUpToThatMoment() async throws {
        let model = chat()
        await model.load()
        await model.apply(incoming("mine, before", from: viewer, at: Date(timeIntervalSinceNow: -60)))
        await model.apply(incoming("mine, after", from: viewer, at: Date(timeIntervalSinceNow: 60)))
        XCTAssertNotEqual(model.readReceiptMessageId, model.messages.last?.id, "unread yet")

        await model.apply(.messageRead(RealtimeMessageRead(conversationId: thread.id, readerId: thread.other.id, readAt: Date())))
        let before = try XCTUnwrap(model.messages.first { $0.text == "mine, before" })
        let after = try XCTUnwrap(model.messages.first { $0.text == "mine, after" })
        XCTAssertTrue(before.read)
        XCTAssertFalse(after.read, "sent after the moment it was read")
        XCTAssertNil(model.readReceiptMessageId, "\"Read\" sits under the latest, which is not read yet")

        await model.apply(.messageRead(RealtimeMessageRead(conversationId: thread.id, readerId: thread.other.id, readAt: Date(timeIntervalSinceNow: 120))))
        XCTAssertEqual(model.readReceiptMessageId, after.id)
    }

    func testTheViewerReadingOnAnotherDeviceIsNotAReceipt() async {
        let model = chat()
        await model.load()
        await model.apply(incoming("mine", from: viewer, at: Date(timeIntervalSinceNow: -60)))
        await model.apply(.messageRead(RealtimeMessageRead(conversationId: thread.id, readerId: viewer.id, readAt: Date())))
        XCTAssertFalse(model.messages.last?.read ?? true)
    }

    func testARequestNeverShowsWhetherItWasRead() async {
        let sent = Conversation(
            id: UUID(), other: .mock(handle: "stranger"), accepted: false, isRequest: false,
            unreadCount: 0, lastMessageAt: nil, lastMessage: nil
        )
        let model = chat(sent)
        await model.apply(incoming("hello?", in: sent, from: viewer, accepted: false))
        await model.apply(.messageRead(RealtimeMessageRead(conversationId: sent.id, readerId: sent.other.id, readAt: Date(timeIntervalSinceNow: 60))))
        XCTAssertTrue(model.messages.last?.read ?? false)
        XCTAssertNil(model.readReceiptMessageId, "the requests folder promises the sender cannot see this")
    }

    func testADeletionLeavesTheOtherScreen() async throws {
        let model = chat()
        await model.load()
        let id = UUID()
        await model.apply(incoming("regret", id: id))
        await model.apply(.messageDeleted(RealtimeMessageDeleted(conversationId: thread.id, messageId: id)))
        let gone = try XCTUnwrap(model.messages.first { $0.id == id })
        XCTAssertTrue(gone.deleted)
        XCTAssertNil(gone.text, "no text, exactly as the thread shows it")
    }

    func testAReconnectReadsTheThreadAgainQuietly() async {
        let service = SpyMessages()
        let model = chat(service: service)
        await model.load()
        let reads = await service.fetchMessagesCalls
        _ = await service.mock.receive(from: "noura", text: "sent while the socket was down")

        await model.apply(.ready(RealtimeReady(standing: "verified", events: [])))
        XCTAssertEqual(model.messages.last?.text, "sent while the socket was down", "nothing is replayed")
        let after = await service.fetchMessagesCalls
        XCTAssertEqual(after, reads + 1)
        XCTAssertNil(model.toast)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Typing, theirs

    func testTheirTypingShowsUntilTheirMessageArrives() async {
        let board = TypingBoard()
        let model = chat(typing: board)
        board.apply(RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: true, expiresIn: 6))
        XCTAssertTrue(model.isOtherTyping)

        board.messageArrived(conversationId: thread.id, from: thread.other.id)
        XCTAssertFalse(model.isOtherTyping, "their message ends it")
    }

    func testTypingEndsWhenTheyStopOrTheTimeRunsOut() {
        let clock = TestClock()
        let board = TypingBoard(now: { clock.now }, sleep: { _ in })
        board.apply(RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: true, expiresIn: 6))
        XCTAssertTrue(board.isTyping(in: thread.id))
        board.apply(RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: false, expiresIn: 0))
        XCTAssertFalse(board.isTyping(in: thread.id), "active: false ends it")

        board.apply(RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: true, expiresIn: 6))
        clock.advance(4)
        board.apply(RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: true, expiresIn: 6))
        clock.advance(4)
        XCTAssertTrue(board.isTyping(in: thread.id), "renewed two seconds before it ran out")
        clock.advance(2.5)
        XCTAssertFalse(board.isTyping(in: thread.id), "six seconds after the latest, it is over")
        board.prune()
        XCTAssertTrue(board.entries.isEmpty)
    }

    func testSomebodyElsesMessageDoesNotEndTheirTyping() {
        let board = TypingBoard()
        board.apply(RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: true, expiresIn: 6))
        board.messageArrived(conversationId: thread.id, from: viewer.id)
        XCTAssertTrue(board.isTyping(in: thread.id, by: thread.other.id))
        board.clearAll()
        XCTAssertFalse(board.isTyping(in: thread.id), "a socket gone says nothing about anybody still typing")
    }

    func testAnOpenedThreadAsksWhetherTheyAreTypingNow() async {
        let service = SpyMessages(typing: TypingStatus(typing: true, expiresIn: 4))
        let board = TypingBoard()
        let model = chat(service: service, typing: board)
        await model.load()
        XCTAssertTrue(model.isOtherTyping, "GET …/typing answered yes")
        let asked = await service.fetchTypingCalls
        XCTAssertEqual(asked, 1)
    }

    func testARequestNeverAsksAboutTyping() async {
        let service = SpyMessages(typing: TypingStatus(typing: true, expiresIn: 4))
        let model = chat(request, service: service)
        await model.load()
        XCTAssertFalse(model.isOtherTyping)
        let asked = await service.fetchTypingCalls
        XCTAssertEqual(asked, 0)
    }

    // MARK: - Typing, the viewer's

    func testTypingIsSaidAtMostEveryTwoSecondsAndStoppingOnce() {
        let clock = TestClock()
        let realtime = FakeRealtime()
        let model = chat(realtime: realtime, clock: clock)

        for letter in "hello" {
            model.draft.append(letter)
            model.draftDidChange()
            clock.advance(0.3)
        }
        XCTAssertEqual(realtime.typingSent.map(\.1), [true], "five keystrokes in 1.5 s are one frame")
        clock.advance(1)
        model.draft.append("!")
        model.draftDidChange()
        XCTAssertEqual(realtime.typingSent.map(\.1), [true, true], "and one more after two seconds")

        model.draft = ""
        model.draftDidChange()
        model.draftDidChange()
        XCTAssertEqual(realtime.typingSent.map(\.1), [true, true, false], "cleared: stopped, once")
        XCTAssertTrue(realtime.typingSent.allSatisfy { $0.0 == thread.id })
    }

    func testSendingEndsTypingWithoutSayingSo() async {
        let realtime = FakeRealtime()
        let model = chat(realtime: realtime)
        await model.load()
        model.draft = "on my way"
        model.draftDidChange()
        await model.send()
        model.draftDidChange()   // the screen's onChange, for the cleared field
        XCTAssertEqual(realtime.typingSent.map(\.1), [true], "the server ends it when the message lands")
    }

    func testLeavingTheThreadSaysStopped() async {
        let realtime = FakeRealtime()
        let model = chat(realtime: realtime)
        await model.screenAppeared()
        model.draft = "half a thought"
        model.draftDidChange()
        model.screenDisappeared()
        XCTAssertEqual(realtime.typingSent.map(\.1), [true, false])
    }

    func testNothingIsSaidInARequestOrWithoutASocket() {
        let realtime = FakeRealtime()
        let requestModel = chat(request, realtime: realtime)
        requestModel.draft = "hi"
        requestModel.draftDidChange()
        XCTAssertTrue(realtime.typingSent.isEmpty, "a request stays quiet")

        let offline = FakeRealtime()
        offline.isLive = false
        let model = chat(realtime: offline)
        model.draft = "hi"
        model.draftDidChange()
        offline.isLive = true
        model.draft = "hi there"
        model.draftDidChange()
        XCTAssertEqual(offline.typingSent.map(\.1), [true], "a frame that was never sent is not waited on")
    }

    func testARefusalStopsTheThreadSayingItIsTyping() async {
        let realtime = FakeRealtime()
        let clock = TestClock()
        let model = chat(realtime: realtime, clock: clock)
        model.draft = "a"
        model.draftDidChange()
        await model.apply(.typingRefused(code: "self_verification_required", conversationId: nil))
        clock.advance(3)
        model.draft = "ab"
        model.draftDidChange()
        XCTAssertEqual(realtime.typingSent.count, 1)
    }

    // MARK: - The inbox

    private func inbox(service: SpyMessages = SpyMessages(), typing: TypingBoard? = nil) -> ConversationsViewModel {
        ConversationsViewModel(
            service: service,
            analytics: RecordingAnalyticsClient(),
            typing: typing,
            viewerId: { [viewer] in viewer.id }
        )
    }

    func testANewMessageMovesItsRowToTheTopWithItsWordsAndCount() async throws {
        let model = inbox()
        await model.load()
        XCTAssertEqual(model.badgeCount, 2)

        await model.apply(incoming("Are you coming tonight?"))
        let row = try XCTUnwrap(model.inbox.first)
        XCTAssertEqual(row.id, thread.id)
        XCTAssertEqual(row.lastMessage, "Are you coming tonight?")
        XCTAssertEqual(row.unreadCount, 3)
        XCTAssertEqual(model.badgeCount, 3)

        await model.apply(incoming("sent from my other phone", from: viewer))
        XCTAssertEqual(model.inbox.first?.lastMessage, "sent from my other phone")
        XCTAssertEqual(model.badgeCount, 3, "the viewer's own words are never unread")
    }

    func testARequestStaysInRequestsAndNeverRaisesTheBadge() async {
        let model = inbox()
        await model.load()
        await model.apply(incoming("hello again", in: request, isRequest: true))
        XCTAssertEqual(model.requests.first?.lastMessage, "hello again")
        XCTAssertEqual(model.badgeCount, 2, "a stranger cannot put a number on somebody's attention")
        XCTAssertFalse(model.inbox.contains { $0.id == request.id })
    }

    func testAThreadTheListHasNeverSeenIsReadFromTheServer() async {
        let service = SpyMessages()
        let model = inbox(service: service)
        await model.load()
        let before = await service.fetchConversationsCalls
        let newcomer = Conversation(
            id: UUID(), other: .mock(handle: "newcomer"), accepted: true, isRequest: false,
            unreadCount: 1, lastMessageAt: Date(), lastMessage: "hi"
        )
        await model.apply(incoming("hi", in: newcomer))
        let after = await service.fetchConversationsCalls
        XCTAssertEqual(after, before + 1, "the server's list is the answer, not a guess")
    }

    func testReadingOnAnyDeviceClearsTheRowAndTheBadge() async {
        let model = inbox()
        await model.load()
        await model.apply(.messageRead(RealtimeMessageRead(conversationId: thread.id, readerId: viewer.id, readAt: Date())))
        XCTAssertEqual(model.inbox.first { $0.id == thread.id }?.unreadCount, 0)
        XCTAssertEqual(model.badgeCount, 0)

        // The other person reading is a receipt, not the viewer's count.
        await model.apply(incoming("another"))
        await model.apply(.messageRead(RealtimeMessageRead(conversationId: thread.id, readerId: thread.other.id, readAt: Date())))
        XCTAssertEqual(model.badgeCount, 1)
    }

    func testTheBadgeMovesBeforeTheTabIsEverOpened() async {
        let model = inbox()
        await model.apply(.ready(RealtimeReady(standing: "verified", events: [])))
        XCTAssertEqual(model.badgeCount, 2, "ready reads the counts")
        XCTAssertFalse(model.hasLoaded, "and leaves the list for the tab")
        await model.apply(incoming("hi"))
        XCTAssertEqual(model.badgeCount, 3)
    }

    func testTheRowSaysWhoIsTyping() async throws {
        L10n.use("en")
        let board = TypingBoard()
        let model = inbox(typing: board)
        await model.load()
        let row = model.inbox[0]
        XCTAssertNil(model.typingLine(for: row))
        board.apply(RealtimeTyping(conversationId: row.id, userId: row.other.id, active: true, expiresIn: 6))
        let english = try XCTUnwrap(model.typingLine(for: row))
        XCTAssertTrue(english.contains(row.other.displayName) && english.hasSuffix(" is typing…"), english)
        L10n.use("ar")
        let arabic = try XCTUnwrap(model.typingLine(for: row))
        XCTAssertTrue(arabic.contains(row.other.displayName) && arabic.hasSuffix(" يكتب…"), arabic)
    }

    // MARK: - The notification badge

    func testTheNotificationBadgeIsTheServersCount() async {
        let model = NotificationsViewModel(
            service: NotificationsServiceMock(scenario: .populated),
            feed: FeedServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        )
        await model.apply(.notificationNew(RealtimeNotificationNew(id: UUID(), kind: "follow", unreadCount: 7)))
        XCTAssertEqual(model.unreadCount, 7, "adopted, never counted up here")
        await model.apply(.ready(RealtimeReady(standing: "verified", events: [])))
        let served = try? await NotificationsServiceMock(scenario: .populated).fetchUnreadCount()
        XCTAssertEqual(model.unreadCount, served, "a reconnect reads the count again")
    }

    // MARK: - The wall

    func testTheWallMovesTheMomentTheAccountChanges() async throws {
        let store = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient())
        let pair = AuthServiceMock.makePair(email: "wall@example.com", scenario: .pendingReview, emailVerified: true)
        await store.store(pair)
        let service = AuthServiceMock(scenario: .pendingReview)
        let session = AuthSession(service: service, store: store, analytics: RecordingAnalyticsClient())
        await session.adopt(pair)
        guard case .verificationWall = session.route else { return XCTFail("not at the wall: \(session.route)") }

        // Somebody else's account changes nothing here.
        let stranger = AuthServiceMock.makePair(email: "other@example.com", scenario: .verified, emailVerified: true).user
        await session.adoptAccount(AuthUser.copy(of: stranger, id: UUID()))
        guard case .verificationWall = session.route else { return XCTFail("another account moved the wall") }

        let approved = AuthUser.copy(of: pair.user, status: .verified, country: "SA")
        await session.adoptAccount(approved)
        XCTAssertEqual(session.route, .feed, "approved: the feed, without a refresh")
        XCTAssertEqual(session.user?.countryCode, "SA")
        let cached = await store.user()
        XCTAssertEqual(cached?.verificationStatus, .verified, "and the keychain's copy follows")
    }

    func testTheAppRoutesTheAccountAndTypingEvents() async throws {
        var flags = FeatureFlags()
        flags.useMockAuth = true
        flags.mockScenario = .pendingReview
        let container = AppContainer(
            flags: flags,
            storage: InMemoryStorageClient(),
            keychain: InMemoryKeychainClient(),
            analytics: RecordingAnalyticsClient(),
            biometrics: StubBiometricAuthenticator(),
            authService: AuthServiceMock(scenario: .pendingReview)
        )
        let pair = AuthServiceMock.makePair(email: "wall@example.com", scenario: .pendingReview, emailVerified: true)
        await container.tokenStore.store(pair)
        await container.session.adopt(pair)

        await container.apply(.accountStatus(AuthUser.copy(of: pair.user, status: .verified, country: "SA")))
        XCTAssertEqual(container.session.route, .feed)

        let typing = RealtimeTyping(conversationId: thread.id, userId: thread.other.id, active: true, expiresIn: 6)
        await container.apply(.typing(typing))
        XCTAssertTrue(container.typing.isTyping(in: thread.id))
        await container.apply(incoming("done", from: thread.other))
        XCTAssertFalse(container.typing.isTyping(in: thread.id), "their message ends their typing")
        await container.apply(.typing(typing))
        await container.apply(.disconnected)
        XCTAssertFalse(container.typing.isTyping(in: thread.id))
    }
}

// MARK: - Doubles

/// ``MessagesServiceMock``, counting what it was asked.
actor SpyMessages: MessagesServiceProtocol {

    let mock = MessagesServiceMock()
    private let typing: TypingStatus
    private(set) var markReadCalls = 0
    private(set) var fetchMessagesCalls = 0
    private(set) var fetchConversationsCalls = 0
    private(set) var fetchTypingCalls = 0

    init(typing: TypingStatus = .notTyping) {
        self.typing = typing
    }

    func fetchConversations() async throws -> [Conversation] {
        fetchConversationsCalls += 1
        return try await mock.fetchConversations()
    }
    func fetchRequests() async throws -> [Conversation] { try await mock.fetchRequests() }
    func fetchCounts() async throws -> MessageCounts { try await mock.fetchCounts() }
    func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] {
        fetchMessagesCalls += 1
        return try await mock.fetchMessages(conversationId: conversationId)
    }
    @discardableResult
    func send(to handle: String, text: String) async throws -> UUID { try await mock.send(to: handle, text: text) }
    func accept(conversationId: UUID) async throws { try await mock.accept(conversationId: conversationId) }
    func markRead(conversationId: UUID) async throws {
        markReadCalls += 1
        try await mock.markRead(conversationId: conversationId)
    }
    func deleteMessage(id: UUID) async throws { try await mock.deleteMessage(id: id) }
    func fetchTyping(conversationId: UUID) async throws -> TypingStatus {
        fetchTypingCalls += 1
        return typing
    }
}

extension AuthUser {
    /// The same account with its verification — or its id — changed.
    static func copy(of user: AuthUser, id: UUID? = nil, status: VerificationStatus? = nil, country: String? = nil) -> AuthUser {
        AuthUser(
            id: id ?? user.id,
            email: user.email,
            displayName: user.displayName,
            emailVerified: user.emailVerified,
            verificationStatus: status ?? user.verificationStatus,
            createdAt: user.createdAt,
            handle: user.handle,
            countryCode: country ?? user.countryCode
        )
    }
}
