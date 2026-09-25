import XCTest
@testable import Sila

/// The reply bar posts through the composer's guidelines gate: a voice clip
/// recorded from a thread is a first post like any other, and the guidelines
/// stand before it exactly as they stand before the composer's.
@MainActor
final class ReplyGuidelinesTests: XCTestCase {

    func testAVoiceReplyFromTheBarWaitsForTheGuidelines() async throws {
        let gate = GuidelinesGate(service: SafetyDepthServiceMock(), acceptedVersion: nil, currentVersion: "2")
        let composer = ComposerServiceMock(scenario: .success)
        let detail = PostDetailViewModel(post: FeedServiceMock.internationalRoot, service: FeedServiceMock(),
                                         analytics: RecordingAnalyticsClient())
        let reply = try XCTUnwrap(PostDetailScreen.replyComposer(
            for: detail, composerService: composer, searchService: nil,
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            analytics: RecordingAnalyticsClient(), voiceService: VoiceServiceMock(), guidelines: gate
        ))
        XCTAssertTrue(reply.guidelines === gate, "the bar is handed the composer's gate")

        let clip = VoiceClip(kind: .question, durationMs: 4_000)
        reply.attach(voice: clip)
        XCTAssertTrue(reply.canPost)
        await reply.post()

        XCTAssertTrue(reply.isShowingGuidelines, "the guidelines stand before a first voice reply")
        XCTAssertNotNil(reply.voiceClip, "nothing was posted")
        let before = await composer.receivedDrafts
        XCTAssertTrue(before.isEmpty, "nothing reached the server")

        await gate.load()
        let accepted = await gate.accept()
        XCTAssertTrue(accepted)
        reply.isShowingGuidelines = false
        await reply.post()
        XCTAssertFalse(reply.isShowingGuidelines)
        let after = await composer.receivedDrafts
        XCTAssertEqual(after.map(\.voiceClipId), [clip.id], "accepted, the voice reply goes")
    }

    func testWithoutTheComposerThereIsNoReplyBarToGate() {
        let detail = PostDetailViewModel(post: FeedServiceMock.internationalRoot, service: FeedServiceMock(),
                                         analytics: RecordingAnalyticsClient())
        XCTAssertNil(PostDetailScreen.replyComposer(
            for: detail, composerService: nil, searchService: nil, author: ComposerAuthor(isVerified: true),
            analytics: RecordingAnalyticsClient(), voiceService: nil,
            guidelines: GuidelinesGate(service: SafetyDepthServiceMock())
        ))
    }
}
