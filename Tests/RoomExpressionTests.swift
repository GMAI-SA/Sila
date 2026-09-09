import XCTest
@testable import Sila

/// Reactions and room chat: what a listener can do without a microphone.
@MainActor
final class RoomExpressionTests: XCTestCase {

    /// A joined room. `start()` is what wires the engine's events to the
    /// model, so nothing arrives before it.
    /// Rooms opened by a test, closed in `tearDown`. A joined room polls its
    /// roster on a timer; one left running starves every async test after it.
    private var opened: [LiveRoomViewModel] = []

    override func tearDown() async throws {
        for viewModel in opened { await viewModel.leave() }
        opened = []
        try await super.tearDown()
    }

    private func joined() async throws -> (LiveRoomViewModel, VoiceEngineMock, RoomsServiceMock) {
        let (viewModel, engine, service) = try await make()
        await viewModel.start()
        opened.append(viewModel)
        return (viewModel, engine, service)
    }

    private func make() async throws -> (LiveRoomViewModel, VoiceEngineMock, RoomsServiceMock) {
        let service = RoomsServiceMock()
        // A room the mock knows, so joining succeeds — the join is what wires
        // the engine's events to the model.
        let rooms = try await service.fetchRooms(status: .live, topic: nil, limit: 5)
        let room = try XCTUnwrap(rooms.first)
        let engine = VoiceEngineMock()
        let viewModel = LiveRoomViewModel(
            room: room,
            viewerHandle: "aziz",
            viewerId: UUID(),
            service: service,
            engine: engine,
            analytics: RecordingAnalyticsClient()
        )
        return (viewModel, engine, service)
    }

    func testAListenerCanReactAndTheEmojiGoesToTheWholeRoom() async throws {
        let (viewModel, engine, _) = try await joined()
        await viewModel.react("👏")
        XCTAssertEqual(viewModel.reactions.map(\.emoji), ["👏"])
        XCTAssertEqual(engine.publishedMessages.last?.emoji, "👏")
        XCTAssertEqual(engine.publishedMessages.last?.type, "reaction")
        // No destinations: everybody sees it.
        XCTAssertEqual(engine.publishedDestinations.last, [])
    }

    func testReactionsAgeOut() async throws {
        let (viewModel, _, _) = try await joined()
        await viewModel.react("🔥")
        XCTAssertEqual(viewModel.reactions.count, 1)
        // Nothing expires before its time.
        viewModel.expireReactions()
        XCTAssertEqual(viewModel.reactions.count, 1)
    }

    func testALineToEveryoneIsListedAndBroadcast() async throws {
        let (viewModel, engine, _) = try await joined()
        viewModel.chatDraft = "  hello everyone  "
        XCTAssertTrue(viewModel.canSendChat)
        await viewModel.sendChat()
        XCTAssertEqual(viewModel.chat.map(\.text), ["hello everyone"])
        XCTAssertTrue(viewModel.chat[0].isMine)
        XCTAssertFalse(viewModel.chat[0].toHost)
        XCTAssertEqual(viewModel.chatDraft, "")
        XCTAssertEqual(engine.publishedMessages.last?.type, "chat")
        XCTAssertEqual(engine.publishedDestinations.last, [])
    }

    func testALineToTheHostIsAddressedToTheHostAlone() async throws {
        let (viewModel, engine, _) = try await joined()
        viewModel.chatToHostOnly = true
        viewModel.chatDraft = "can I speak?"
        await viewModel.sendChat()
        XCTAssertTrue(viewModel.chat[0].toHost)
        XCTAssertEqual(engine.publishedMessages.last?.toHost, true)
        // Addressed on the wire: the host's identity is the account id.
        XCTAssertEqual(engine.publishedDestinations.last, [viewModel.room.host.id.uuidString.lowercased()])
    }

    func testAnEmptyOrOverlongLineIsNotSendable() async throws {
        let (viewModel, engine, _) = try await joined()
        viewModel.chatDraft = "   "
        XCTAssertFalse(viewModel.canSendChat)
        await viewModel.sendChat()
        viewModel.chatDraft = String(repeating: "a", count: LiveRoomViewModel.chatCharacterLimit + 1)
        XCTAssertFalse(viewModel.canSendChat)
        await viewModel.sendChat()
        XCTAssertTrue(viewModel.chat.isEmpty)
        XCTAssertTrue(engine.publishedMessages.filter { $0.isChat }.isEmpty)
    }

    func testWhatArrivesFromOthersIsShownAndCounted() async throws {
        let (viewModel, engine, _) = try await joined()
        let other = UUID()
        engine.simulate(.message(.reaction("❤️", userId: other, handle: "noura", name: "Noura")))
        await Task.yield()
        engine.simulate(.message(.chat("hi", userId: other, handle: "noura", name: "Noura", toHost: false)))
        // The model coalesces events; give the main actor a turn.
        await Task.yield()
        XCTAssertEqual(viewModel.reactions.map(\.emoji), ["❤️"])
        XCTAssertEqual(viewModel.chat.map(\.name), ["Noura"])
        XCTAssertFalse(viewModel.chat[0].isMine)
        // Counted while the panel is closed, and cleared when it opens.
        XCTAssertEqual(viewModel.unreadChat, 1)
        viewModel.isChatOpen = true
        XCTAssertEqual(viewModel.unreadChat, 0)
    }

    func testOurOwnMessagesComingBackAreNotDoubled() async throws {
        let (viewModel, engine, _) = try await joined()
        let me = try XCTUnwrap(viewModel.viewerId)
        await viewModel.react("💯")
        engine.simulate(.message(.reaction("💯", userId: me, handle: "aziz", name: "Aziz")))
        await Task.yield()
        XCTAssertEqual(viewModel.reactions.count, 1)
    }
}
