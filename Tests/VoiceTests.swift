import XCTest
@testable import Sila

/// A recorder with no microphone: `start` begins a fake take whose length the
/// test sets, and `stop` hands back a real (empty) file.
@MainActor
final class FakeVoiceRecorder: VoiceRecording {
    var permission = true
    var elapsed: TimeInterval = 0
    var level: Float = 0.5
    private(set) var isRecording = false
    var onInterrupted: ((URL?) -> Void)?
    private(set) var discarded = 0
    private var file: URL?

    func requestPermission() async -> Bool { permission }

    func start() throws {
        isRecording = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2]))
        file = url
    }

    func stop() -> URL? {
        isRecording = false
        return file
    }

    func discard() {
        discarded += 1
        isRecording = false
        file = nil
    }

    /// A phone call arrives.
    func interrupt() {
        isRecording = false
        onInterrupted?(file)
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
}

final class VoiceModelTests: XCTestCase {

    func testAClipDecodesAndResolvesItsAudioPath() throws {
        let clip = try decode(VoiceClip.self, """
        {"clip_id": "00000000-0000-4000-8000-000000000a01", "kind": "hot_take",
         "audio_url": "/api/v1/media/voice/abc.m4a", "duration_ms": 12480, "peaks": [0, 300, -4, 128],
         "caption": "Spurs will win", "caption_status": "done", "caption_language": "en",
         "caption_by_author": false, "stances": {"agree": 3, "disagree": 1, "viewer_stance": "agree"}}
        """)
        XCTAssertEqual(clip.kind, .hotTake)
        XCTAssertEqual(clip.audioURL?.host, AppConfig.apiBaseURL.host, "a root-relative path resolves against the API host")
        XCTAssertEqual(clip.peaks, [0, 255, 0, 128], "peaks are clamped to 0…255")
        XCTAssertEqual(clip.duration, 12.48, accuracy: 0.001)
        XCTAssertEqual(clip.captionLabel, L10n.t("voice.caption.auto"))
        XCTAssertEqual(clip.stances?.viewerStance, .agree)
        XCTAssertEqual(clip.stances?.agreeShare ?? 0, 0.75, accuracy: 0.001)
    }

    func testEveryCaptionStateCarriesTheRightLabel() {
        XCTAssertEqual(VoiceClip(captionStatus: .pending).captionLabel, L10n.t("voice.caption.pending"))
        XCTAssertEqual(VoiceClip(caption: "x", captionStatus: .done, captionByAuthor: true).captionLabel,
                       L10n.t("voice.caption.byAuthor"))
        XCTAssertNil(VoiceClip(captionStatus: .removed).captionLabel)
        XCTAssertNil(VoiceClip(captionStatus: .failed).captionLabel)
    }

    func testAPostCarriesItsVoice() throws {
        let post = try decode(Post.self, """
        {"id": "00000000-0000-4000-8000-000000000001",
         "author": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
         "text": "", "created_at": "2026-09-23T10:00:00Z", "scope": "international",
         "voice": {"clip_id": "00000000-0000-4000-8000-000000000a01", "kind": "question", "audio_url": "/api/v1/media/voice/a.m4a",
                   "duration_ms": 4000, "peaks": [], "caption": null, "caption_status": "pending"}}
        """)
        XCTAssertEqual(post.voice?.kind, .question)
    }

    func testKindsCarryTheServersCaps() {
        XCTAssertEqual(VoiceKind.allCases.map(\.maxSeconds), [30, 60, 120, 60])
        XCTAssertEqual(VoiceTime.label(75), "1:15")
    }

    func testTheVoiceClipGoesOnTheWire() throws {
        let id = UUID()
        let draft = PostDraft(text: "", scope: .international, voiceClipId: id)
        XCTAssertTrue(draft.isPostable, "a recording can stand alone")
        let json = String(decoding: try JSONCoding.encoder.encode(CreatePostBody(draft: draft)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""voice_clip_id":"\#(id.uuidString.lowercased())""#), json)
    }

    func testEveryVoiceRefusalHasItsOwnCopy() {
        let codes: [APIErrorCode] = [.invalidAudio, .audioTooShort, .audioTooLarge, .audioProcessingUnavailable,
                                     .voiceWithMedia, .invalidVoiceClip, .captionRedoLimit, .ownHotTake, .notAHotTake]
        for code in codes {
            XCTAssertNotEqual(APIError.api(code: code, message: "", status: 400).userMessage, L10n.t("common.somethingWentWrong"))
        }
    }
}

@MainActor
final class VoiceRecorderViewModelTests: XCTestCase {

    private func make(_ recorder: FakeVoiceRecorder, service: VoiceServiceMock = VoiceServiceMock(),
                      onUse: @escaping (VoiceClip) -> Void = { _ in }) -> VoiceRecorderViewModel {
        VoiceRecorderViewModel(recorder: recorder, service: service, analytics: RecordingAnalyticsClient(),
                               languageHint: "ar", pollInterval: 1_000_000, onUse: onUse)
    }

    func testPressToStartPressToStopKeepsTheTake() async {
        let recorder = FakeVoiceRecorder()
        let viewModel = make(recorder)
        await viewModel.toggleRecording()
        XCTAssertTrue(viewModel.isRecording)
        XCTAssertFalse(viewModel.canChangeKind, "the kind is fixed while recording")
        recorder.elapsed = 5
        viewModel.tick()
        XCTAssertEqual(viewModel.remaining, 25)
        await viewModel.toggleRecording()
        guard case let .recorded(_, seconds) = viewModel.phase else { return XCTFail("\(viewModel.phase)") }
        XCTAssertEqual(seconds, 5)
    }

    func testTheCapStopsTheRecording() async {
        let recorder = FakeVoiceRecorder()
        let viewModel = make(recorder)
        viewModel.kind = .thought
        await viewModel.toggleRecording()
        recorder.elapsed = 30
        viewModel.tick()
        guard case .recorded = viewModel.phase else { return XCTFail("the cap did not stop it") }
    }

    func testTooShortIsNotKept() async {
        let recorder = FakeVoiceRecorder()
        let viewModel = make(recorder)
        await viewModel.toggleRecording()
        recorder.elapsed = 0.4
        await viewModel.toggleRecording()
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNotNil(viewModel.toast)
    }

    func testADeniedMicrophoneSaysSo() async {
        let recorder = FakeVoiceRecorder()
        recorder.permission = false
        let viewModel = make(recorder)
        await viewModel.toggleRecording()
        XCTAssertTrue(viewModel.micDenied)
        XCTAssertEqual(viewModel.phase, .idle)
    }

    func testAnInterruptionKeepsWhatWasRecorded() async {
        let recorder = FakeVoiceRecorder()
        let viewModel = make(recorder)
        await viewModel.toggleRecording()
        recorder.elapsed = 8
        viewModel.tick()
        recorder.interrupt()
        guard case .recorded = viewModel.phase else { return XCTFail("the take was lost to a phone call") }
    }

    func testUploadThenTheCaptionArrivesThenTheAuthorCorrectsIt() async throws {
        let recorder = FakeVoiceRecorder()
        let service = VoiceServiceMock()
        var used: VoiceClip?
        let viewModel = make(recorder, service: service, onUse: { used = $0 })
        viewModel.kind = .story
        await viewModel.toggleRecording()
        recorder.elapsed = 6
        viewModel.tick()
        await viewModel.toggleRecording()
        await viewModel.upload()
        XCTAssertEqual(service.uploads.first?.kind, .story)
        XCTAssertEqual(service.uploads.first?.languageHint, "ar")
        XCTAssertEqual(viewModel.uploadedClip?.captionStatus, .pending)

        for _ in 0..<50 where viewModel.uploadedClip?.captionStatus == .pending {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(viewModel.uploadedClip?.captionStatus, .done)
        XCTAssertFalse(viewModel.captionDraft.isEmpty)

        viewModel.captionDraft = "What I actually said"
        await viewModel.saveCaption()
        XCTAssertEqual(viewModel.uploadedClip?.captionByAuthor, true)

        viewModel.use()
        XCTAssertEqual(used?.caption, "What I actually said")
    }

    func testARefusedUploadKeepsTheTake() async {
        let recorder = FakeVoiceRecorder()
        let viewModel = make(recorder, service: VoiceServiceMock(scenario: .tooLong))
        await viewModel.toggleRecording()
        recorder.elapsed = 3
        viewModel.tick()
        await viewModel.toggleRecording()
        await viewModel.upload()
        guard case .recorded = viewModel.phase else { return XCTFail("the take was dropped") }
        XCTAssertNotNil(viewModel.toast)
    }

    func testRetakeDiscards() async {
        let recorder = FakeVoiceRecorder()
        let viewModel = make(recorder)
        await viewModel.toggleRecording()
        recorder.elapsed = 3
        viewModel.tick()
        await viewModel.toggleRecording()
        viewModel.retake()
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(recorder.discarded, 1)
    }
}

@MainActor
final class VoiceComposerTests: XCTestCase {

    func testAVoicePostTravelsAlone() {
        let composer = ComposerViewModel(context: .newPost, author: ComposerAuthor(user: nil),
                                         composer: ComposerServiceMock(scenario: .success),
                                         analytics: RecordingAnalyticsClient(), voice: VoiceServiceMock())
        XCTAssertTrue(composer.canRecordVoice)
        composer.attach(voice: VoiceClip(kind: .thought, durationMs: 4000))
        XCTAssertFalse(composer.canAddPoll)
        XCTAssertFalse(composer.allowsMedia)
        XCTAssertFalse(composer.allowsThread)
        XCTAssertTrue(composer.canPost, "a recording with no words is a post")
        composer.removeVoice()
        XCTAssertFalse(composer.canPost)
    }

    func testAReplyRecordsAQuestion() throws {
        let parent = FeedServiceMock.internationalRoot
        let composer = ComposerViewModel(context: .reply(to: parent), author: ComposerAuthor(user: nil),
                                         composer: ComposerServiceMock(scenario: .success),
                                         analytics: RecordingAnalyticsClient(), voice: VoiceServiceMock())
        XCTAssertTrue(composer.canRecordVoice)
        XCTAssertEqual(composer.recorderKind, .question)
    }

    func testNoVoiceServiceNoMicrophone() {
        let composer = ComposerViewModel(context: .newPost, author: ComposerAuthor(user: nil),
                                         composer: ComposerServiceMock(scenario: .success),
                                         analytics: RecordingAnalyticsClient())
        XCTAssertFalse(composer.canRecordVoice)
    }

    func testHotTakeStancesAreSentAndCanBeWithdrawn() async throws {
        let service = VoiceServiceMock()
        let post = UUID()
        let agreed = try await service.setStance(.agree, postId: post)
        XCTAssertEqual(agreed.viewerStance, .agree)
        XCTAssertEqual(agreed.agree, 4)
        let changed = try await service.setStance(.disagree, postId: post)
        XCTAssertEqual(changed.agree, 3)
        XCTAssertEqual(changed.disagree, 2)
        let withdrawn = try await service.setStance(nil, postId: post)
        XCTAssertNil(withdrawn.viewerStance)
    }

    func testTheArbiterGivesARoomTheSession() {
        let arbiter = AudioSessionArbiter()
        var yielded = false
        arbiter.onYield(.recorder) { yielded = true }
        try? arbiter.acquireForRecording()
        arbiter.prepareForRoom()
        XCTAssertTrue(yielded, "the recorder was not told to stop")
        XCTAssertEqual(arbiter.owner, .room)
        XCTAssertThrowsError(try arbiter.acquireForRecording(), "nothing records while a room holds the session")
        arbiter.release(.room)
        XCTAssertEqual(arbiter.owner, .none)
    }
}
