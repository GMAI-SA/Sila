import XCTest
@testable import Sila

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
}

private let author = #"{"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true}"#

private func post(_ id: Int, extra: String = "") -> String {
    #"{"id": "00000000-0000-4000-8000-\#(String(format: "%012d", id))", "author": \#(author), "text": "post \#(id)", "created_at": "2026-09-23T10:00:00Z", "scope": "international" \#(extra)}"#
}

final class DepthModelTests: XCTestCase {

    func testReactionsDecodeOnMetricsAndTheViewer() throws {
        let decoded = try decode(Post.self, post(1, extra: """
        , "metrics": {"likes": 1, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0, "helpful": 4, "funny": 1},
          "viewer": {"liked": false, "reposted": false, "bookmarked": false, "can_reply": true, "reactions": ["helpful"]}
        """))
        XCTAssertEqual(decoded.metrics.count(for: .helpful), 4)
        XCTAssertEqual(decoded.metrics.count(for: .question), 0)
        XCTAssertEqual(decoded.viewer.reactions, ["helpful"])
    }

    func testAThreadDecodesAncestorsRootFirst() throws {
        let thread = try decode(PostThread.self, """
        {"ancestors": [\(post(1)), \(post(2))], "post": \(post(3)),
         "replies": {"posts": [\(post(4, extra: #", "reply_count_direct": 2"#))], "next_cursor": null, "has_more": false}}
        """)
        XCTAssertEqual(thread.ancestors.map(\.text), ["post 1", "post 2"])
        XCTAssertEqual(thread.replies.posts.first?.replyCountDirect, 2)
    }

    func testARoomCarriesCohostsAndItsPinnedQuestion() throws {
        let room = try decode(VoiceRoom.self, """
        {"id": "00000000-0000-4000-8000-000000000c01", "title": "AMA with Noura", "status": "live", "host": \(author),
         "kind": "ama", "is_cohost": true, "cohosts": [\(author)],
         "pinned_question": {"id": "00000000-0000-4000-8000-000000000e01", "text": "Best advice?", "upvote_count": 9}}
        """)
        XCTAssertTrue(room.isCohost)
        XCTAssertEqual(room.cohosts.count, 1)
        XCTAssertEqual(room.pinnedQuestion?.text, "Best advice?")
    }

    func testServerRoomEventsAreRecognised() throws {
        let chat = try decode(RoomDataMessage.self, """
        {"type": "chat", "message": {"id": "00000000-0000-4000-8000-000000000f01", "text": "hi", "author": \(author),
         "created_at": "2026-09-23T10:00:00Z", "hidden": false}}
        """)
        XCTAssertTrue(chat.isDepthEvent)
        XCTAssertEqual(chat.message?.text, "hi")
        XCTAssertTrue(try decode(RoomDataMessage.self, #"{"type": "questions_changed"}"#).isDepthEvent)
        XCTAssertFalse(try decode(RoomDataMessage.self, #"{"type": "reaction", "emoji": "👏"}"#).isDepthEvent)
        // What the phone sends still encodes as before.
        let json = String(decoding: try JSONEncoder().encode(RoomDataMessage.hand(userId: UUID(), raised: true)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""type":"hand""#))
    }

    func testReportingAMessageARoomAndAChatLine() throws {
        let target = SafetyTarget(handle: "noura", name: "Noura")
        let id = UUID()
        let dm = ReportRequest(subject: .message(id: id, author: target, excerpt: "x"), reason: .spam, detail: nil)
        XCTAssertEqual(dm.messageId, id)
        XCTAssertNil(dm.postId)
        let json = String(decoding: try JSONCoding.encoder.encode(dm), as: UTF8.self)
        XCTAssertTrue(json.contains("message_id"), json)
        XCTAssertEqual(ReportRequest(subject: .room(id: id, host: target, title: "t"), reason: .spam, detail: nil).roomId, id)
        XCTAssertEqual(ReportRequest(subject: .roomMessage(id: id, author: target, excerpt: "x"), reason: .spam, detail: nil).roomMessageId, id)
    }

    func testNotificationDetailsSayWhatHappened() {
        XCTAssertEqual(NotificationCopy.sentence(.reply, actor: "Noura", detail: "answer"),
                       L10n.t("notifications.sentence.answer", "Noura"))
        XCTAssertEqual(NotificationCopy.sentence(.reaction, actor: "Noura", detail: "helpful"),
                       L10n.t("notifications.sentence.reaction.helpful", "Noura"))
        XCTAssertTrue(NotificationKind.threadReply.isAboutAPost)
    }

    func testGuidelinesVersionsDecodeAsNumbersOrStrings() throws {
        let user = try decode(AuthUser.self, #"{"id": "00000000-0000-4000-8000-000000000101", "email": "a@b.c", "email_verified": true, "verification_status": "verified", "created_at": "2026-09-01T00:00:00Z", "guidelines_version": 1, "current_guidelines_version": "2"}"#)
        XCTAssertEqual(user.guidelinesVersion, "1")
        XCTAssertEqual(user.currentGuidelinesVersion, "2")
    }
}

@MainActor
final class RoomDepthViewModelTests: XCTestCase {

    private func make(stage: Bool = true, host: Bool = true) -> (RoomDepthViewModel, RoomDepthServiceMock) {
        let service = RoomDepthServiceMock()
        return (RoomDepthViewModel(roomId: UUID(), isHost: host, isStage: stage, cohosts: [], service: service,
                                   analytics: RecordingAnalyticsClient()), service)
    }

    func testAskUpvotePinAnswer() async {
        let (viewModel, service) = make()
        await viewModel.load()
        XCTAssertEqual(viewModel.questions.first?.upvoteCount, 9, "most-upvoted first")
        viewModel.askDraft = "Will there be a recap?"
        await viewModel.ask()
        XCTAssertTrue(viewModel.questions.contains { $0.text == "Will there be a recap?" })
        let target = viewModel.questions[1]
        await viewModel.toggleUpvote(target)
        await viewModel.stage("pin", viewModel.questions.first { $0.id == target.id }!)
        XCTAssertEqual(viewModel.pinned?.id, target.id)
        await viewModel.stage("answer", viewModel.pinned!)
        XCTAssertTrue(viewModel.answered.contains { $0.id == target.id })
        XCTAssertEqual(service.stageCalls, ["pin", "answer"])
    }

    func testTheAudienceCannotRunTheStage() async {
        let (viewModel, service) = make(stage: false, host: false)
        await viewModel.load()
        await viewModel.stage("dismiss", viewModel.questions[0])
        XCTAssertTrue(service.stageCalls.isEmpty)
        let opened = await viewModel.openPoll(question: "Q", options: ["A", "B"], durationSeconds: 120)
        XCTAssertFalse(opened)
    }

    func testARoomPollOpensTakesVotesAndCloses() async {
        let (viewModel, _) = make()
        let opened = await viewModel.openPoll(question: "Tonight?", options: ["Yes", "No", " "], durationSeconds: 120)
        XCTAssertTrue(opened)
        let poll = viewModel.openPoll!
        XCTAssertEqual(poll.poll.options.count, 2, "empty options are dropped")
        await viewModel.vote(poll.poll.options[0], in: poll)
        XCTAssertEqual(viewModel.polls.first?.poll.totalVotes, 1)
        let second = await viewModel.openPoll(question: "Another", options: ["A", "B"], durationSeconds: 60)
        XCTAssertFalse(second, "one open poll at a time")
        await viewModel.close(viewModel.polls[0])
        XCTAssertNil(viewModel.openPoll)
    }

    func testOnlyTheHostNamesCohostsAndThreeAtMost() async {
        let (viewModel, _) = make()
        for handle in ["a", "b", "c", "d"] { await viewModel.addCohost(handle) }
        XCTAssertEqual(viewModel.cohosts.count, 3)
        await viewModel.removeCohost("a")
        XCTAssertEqual(viewModel.cohosts.count, 2)
        let (cohost, _) = make(stage: true, host: false)
        await cohost.addCohost("x")
        XCTAssertTrue(cohost.cohosts.isEmpty)
    }
}

@MainActor
final class SafetyDepthTests: XCTestCase {

    func testMutedWordsAddAndRemove() async {
        let viewModel = MutedTermsViewModel(service: SafetyDepthServiceMock())
        viewModel.draft = "x"
        XCTAssertFalse(viewModel.canAdd)
        viewModel.draft = "spoilers"
        await viewModel.add()
        XCTAssertEqual(viewModel.terms.map(\.term), ["spoilers"])
        await viewModel.remove(viewModel.terms[0])
        XCTAssertTrue(viewModel.terms.isEmpty)
    }

    func testTheGuidelinesStandBeforeAFirstPostUntilAccepted() async {
        let service = SafetyDepthServiceMock()
        let gate = GuidelinesGate(service: service, acceptedVersion: nil, currentVersion: "2")
        XCTAssertTrue(gate.needsAcceptance)
        let composer = ComposerViewModel(context: .newPost, author: ComposerAuthor(user: nil),
                                         composer: ComposerServiceMock(scenario: .success),
                                         analytics: RecordingAnalyticsClient(), guidelines: gate)
        composer.setText("hello", at: 0)
        await composer.post()
        XCTAssertTrue(composer.isShowingGuidelines, "the first post waits for the guidelines")
        await gate.load()
        let accepted = await gate.accept()
        XCTAssertTrue(accepted)
        XCTAssertEqual(service.accepted, ["2"])
        XCTAssertFalse(gate.needsAcceptance)
    }

    func testNoVersionFromTheServerNeverBlocksPosting() {
        XCTAssertFalse(GuidelinesGate(service: SafetyDepthServiceMock()).needsAcceptance)
    }
}
