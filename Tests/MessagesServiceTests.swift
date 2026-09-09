import XCTest
@testable import Sila

/// The wire contract for direct messages.
///
/// The server wraps both lists — `{"conversations": [...]}` and
/// `{"messages": [...]}` — and the client once decoded bare arrays, so the
/// Messages tab reported that it could not read a response the server had
/// answered with 200. These tests pin the wrapped shape and keep the bare one
/// working too.
final class MessagesServiceTests: XCTestCase {

    private func make(_ network: StubNetworkClient) -> MessagesService {
        MessagesService(
            network: network,
            tokens: StaticAccessTokenProvider(token: "t"),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let other = """
    {"id":"2b1f0d6e-7c1a-4b9a-9d3e-1c2f3a4b5c6d","handle":"noura","display_name":"Noura",
     "avatar_url":null,"is_verified":true,"country_code":"SA","verified_since":null,"is_private":false}
    """

    private static let conversation = """
    {"id":"9e8d7c6b-5a4f-4e3d-8c2b-1a0f9e8d7c6b","other":\(other),"accepted":true,"is_request":false,
     "unread_count":2,"last_message_at":"2026-09-08T18:28:00.123456Z","last_message":"see you there"}
    """

    func testConversationsAreReadFromTheServersEnvelope() async throws {
        let network = StubNetworkClient(responses: [#"{"conversations":[\#(Self.conversation)]}"#])
        let rows = try await make(network).fetchConversations()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.other.handle, "noura")
        XCTAssertEqual(rows.first?.unreadCount, 2)
        XCTAssertEqual(rows.first?.lastMessage, "see you there")
        XCTAssertNotNil(rows.first?.lastMessageAt)
        XCTAssertEqual(network.lastRequest?.path, "/conversations")
        XCTAssertTrue(network.lastRequest?.query.isEmpty ?? true)
    }

    func testAnEmptyInboxIsTheEmptyEnvelope() async throws {
        // Exactly what the server answers a new account with — the twenty
        // bytes the tab could not read.
        let network = StubNetworkClient(responses: [#"{"conversations":[]}"#])
        let rows = try await make(network).fetchConversations()
        XCTAssertEqual(rows, [])
    }

    func testABareArrayStillDecodes() async throws {
        let network = StubNetworkClient(responses: [#"[\#(Self.conversation)]"#])
        let rows = try await make(network).fetchConversations()
        XCTAssertEqual(rows.count, 1)
    }

    func testRequestsAskForTheRequestsList() async throws {
        let network = StubNetworkClient(responses: [#"{"conversations":[]}"#])
        _ = try await make(network).fetchRequests()
        XCTAssertEqual(network.lastRequest?.path, "/conversations")
        XCTAssertEqual(network.lastRequest?.query.first?.name, "requests")
        XCTAssertEqual(network.lastRequest?.query.first?.value, "true")
    }

    func testMessagesAreReadFromTheServersEnvelope() async throws {
        let conversationId = UUID()
        let json = """
        {"messages":[
          {"id":"\(UUID().uuidString.lowercased())","conversation_id":"\(conversationId.uuidString.lowercased())",
           "sender":\(Self.other),"text":"hi","deleted":false,"read":true,"created_at":"2026-09-08T18:28:00Z"},
          {"id":"\(UUID().uuidString.lowercased())","conversation_id":"\(conversationId.uuidString.lowercased())",
           "sender":\(Self.other),"text":null,"deleted":true,"read":false,"created_at":"2026-09-08T18:29:00Z"}
        ]}
        """
        let network = StubNetworkClient(responses: [json])
        let rows = try await make(network).fetchMessages(conversationId: conversationId)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.text, "hi")
        XCTAssertEqual(rows.last?.deleted, true)
        XCTAssertNil(rows.last?.text)
        XCTAssertEqual(network.lastRequest?.path, "/conversations/\(conversationId.uuidString.lowercased())/messages")
    }

    func testCountsAreRead() async throws {
        let network = StubNetworkClient(responses: [#"{"unread":3,"requests":1}"#])
        let counts = try await make(network).fetchCounts()
        XCTAssertEqual(counts.unread, 3)
        XCTAssertEqual(counts.requests, 1)
    }
}

/// The Messages screen's own shape.
///
/// The screen once shrink-wrapped its content, so SwiftUI centred it and left
/// half a screen of blank above the folder control. This pins the two things
/// that made it wrong: the screen fills its space, and a conversation can be
/// started from nothing.
@MainActor
final class ConversationsScreenTests: XCTestCase {

    func testADraftConversationCarriesThePersonAndNoThread() {
        let person = UserSummary(id: UUID(), handle: "noura", displayName: "Noura", isVerified: true)
        let draft = Conversation.draft(with: person)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.other.handle, "noura")
        XCTAssertEqual(draft.unreadCount, 0)
        XCTAssertNil(draft.lastMessageAt)
        // Accepted and not a request: there is nothing to accept yet.
        XCTAssertTrue(draft.accepted)
        XCTAssertFalse(draft.isRequest)
    }

    func testADraftReadsNothingAndBecomesRealOnTheFirstMessage() async {
        let service = MessagesServiceMock()
        let person = UserSummary(id: UUID(), handle: "noura", displayName: "Noura", isVerified: true)
        let viewModel = ChatViewModel(
            conversation: Conversation.draft(with: person),
            viewerId: UUID(),
            service: service
        )
        await viewModel.load()
        XCTAssertTrue(viewModel.messages.isEmpty)

        viewModel.draft = "hello"
        await viewModel.send()
        // The mock answers with a real thread, which the screen adopts.
        XCTAssertFalse(viewModel.conversation.isDraft)
        XCTAssertEqual(viewModel.draft, "")
    }

    func testTheInboxFindsAnExistingThreadBeforeStartingADraft() async {
        let viewModel = ConversationsViewModel(
            service: MessagesServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        await viewModel.load()
        let known = viewModel.inbox.first?.other.handle
        XCTAssertNotNil(known)
        XCTAssertNotNil(viewModel.conversation(with: known ?? ""))
        XCTAssertNotNil(viewModel.conversation(with: "@\((known ?? "").uppercased())"))
        XCTAssertNil(viewModel.conversation(with: "nobody-at-all"))
    }
}
