import XCTest
@testable import Sila

/// The order SwiftUI actually produces when a dialog's destructive button is
/// tapped: the presentation binding goes false first — which clears whatever
/// drives the dialog — and the button's async action runs after. Four
/// dialogs in this app read the driving value inside that action and found
/// nothing, so confirming did nothing. Each keeps what was armed now.
@MainActor
final class DialogDismissalRaceTests: XCTestCase {

    // MARK: - Groups

    /// A group of the viewer's own, made the way the editor makes one.
    private func groupsModelWithAGroup() async -> (GroupsViewModel, UserGroup)? {
        let viewModel = GroupsViewModel(service: RoomsServiceMock(), analytics: RecordingAnalyticsClient())
        await viewModel.load()
        viewModel.nameText = "Family"
        viewModel.handlesText = "@yuki"
        await viewModel.create()
        guard let group = viewModel.groups.first else { XCTFail("the editor made no group"); return nil }
        return (viewModel, group)
    }

    func testDeletingAGroupSurvivesTheDialogClosingFirst() async {
        guard let (viewModel, group) = await groupsModelWithAGroup() else { return }

        viewModel.requestDeletion(group)
        viewModel.cancelDeletion()          // the binding's dismissal
        await viewModel.confirmDeletion()   // the button's action, after it

        XCTAssertFalse(viewModel.groups.contains { $0.id == group.id },
                       "the dialog closing before the action ran used to swallow the delete")
    }

    func testKeepingAGroupReallyKeepsIt() async {
        guard let (viewModel, group) = await groupsModelWithAGroup() else { return }

        viewModel.requestDeletion(group)
        viewModel.keepGroup()
        await viewModel.confirmDeletion()

        XCTAssertTrue(viewModel.groups.contains { $0.id == group.id }, "a group somebody chose to keep was deleted")
    }

    // MARK: - Rooms list

    func testEndingAHostedRoomFromTheListSurvivesTheDialogClosingFirst() async {
        let service = RoomsServiceMock(scenario: .hosting)
        let viewModel = RoomsViewModel(service: service, analytics: RecordingAnalyticsClient(), debounce: 0)
        await viewModel.load()
        guard let mine = viewModel.visibleLive.first(where: { $0.isHost }) else {
            return XCTFail("the hosting scenario has no live room the viewer hosts")
        }

        viewModel.requestEnd(mine)
        viewModel.endingRoom = nil          // the binding's dismissal
        await viewModel.confirmEnd()

        XCTAssertFalse(viewModel.visibleLive.contains { $0.id == mine.id },
                       "the room is still listed as live after the host confirmed ending it")
    }

    func testKeepingARoomLeavesItRunning() async {
        let service = RoomsServiceMock(scenario: .hosting)
        let viewModel = RoomsViewModel(service: service, analytics: RecordingAnalyticsClient(), debounce: 0)
        await viewModel.load()
        guard let mine = viewModel.visibleLive.first(where: { $0.isHost }) else {
            return XCTFail("the hosting scenario has no live room the viewer hosts")
        }

        viewModel.requestEnd(mine)
        viewModel.keepRoom()
        await viewModel.confirmEnd()

        XCTAssertTrue(viewModel.visibleLive.contains { $0.id == mine.id }, "a room the host chose to keep was ended")
    }
}

// MARK: - Chat

extension DialogDismissalRaceTests {

    /// A message the viewer wrote, from the mock's own threads.
    private func ownMessage(in service: MessagesServiceMock) async throws -> (Conversation, DirectMessage) {
        let viewer = UserSummary.mockViewer
        for conversation in Conversation.mockThreads {
            let thread = DirectMessage.mockThreads[conversation.id] ?? []
            if let mine = thread.first(where: { $0.sender.id == viewer.id && !$0.deleted }) {
                return (conversation, mine)
            }
        }
        throw XCTSkip("the mock threads hold no message written by the viewer")
    }

    func testDeletingAMessageSurvivesTheDialogClosingFirst() async throws {
        let service = MessagesServiceMock()
        let (conversation, mine) = try await ownMessage(in: service)
        let viewModel = ChatViewModel(conversation: conversation, viewerId: UserSummary.mockViewer.id, service: service)
        await viewModel.load()

        viewModel.requestDeletion(of: mine)
        viewModel.pendingDeletion = nil     // the binding's dismissal
        await viewModel.confirmDeletion()   // the button's action, after it

        let after = viewModel.messages.first { $0.id == mine.id }
        XCTAssertEqual(after?.deleted, true,
                       "the dialog closing before the action ran used to swallow the delete")
    }

    func testKeepingAMessageReallyKeepsIt() async throws {
        let service = MessagesServiceMock()
        let (conversation, mine) = try await ownMessage(in: service)
        let viewModel = ChatViewModel(conversation: conversation, viewerId: UserSummary.mockViewer.id, service: service)
        await viewModel.load()

        viewModel.requestDeletion(of: mine)
        viewModel.keepMessage()
        await viewModel.confirmDeletion()

        let after = viewModel.messages.first { $0.id == mine.id }
        XCTAssertEqual(after?.deleted, false, "a message somebody chose to keep was deleted")
    }
}

// MARK: - Blocking

extension DialogDismissalRaceTests {

    func testBlockingSurvivesTheAlertClosingFirst() async {
        let viewModel = SafetyViewModel(
            service: SafetyServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            viewerHandle: "aziz"
        )
        let target = SafetyTarget(handle: "yuki", name: "Yuki Tanaka")

        viewModel.requestBlock(target)
        viewModel.dismissBlockAlert()       // the binding's dismissal
        await viewModel.confirmBlock()      // the destructive button, after it

        XCTAssertTrue(viewModel.isBlocked("yuki"),
                      "the alert closing before the action ran used to swallow the block — nobody was ever blocked")
    }

    func testCancellingTheBlockDisarmsIt() async {
        let viewModel = SafetyViewModel(
            service: SafetyServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            viewerHandle: "aziz"
        )
        viewModel.requestBlock(SafetyTarget(handle: "yuki", name: "Yuki Tanaka"))

        viewModel.cancelBlock()
        await viewModel.confirmBlock()

        XCTAssertFalse(viewModel.isBlocked("yuki"), "somebody the viewer chose not to block was blocked")
    }
}
