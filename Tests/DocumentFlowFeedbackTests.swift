import UIKit
import XCTest
@testable import Sila

/// The document flow says what is happening at every moment (owner, 2026-09-30:
/// "once I upload it won't tell me if the document is accepted or not; it
/// returns to the same page"). A side being read says so; a side that is in
/// says so, with its picture; one that cannot be used says why; each side is
/// retaken on its own; the upload counts up, then the server's check, then
/// the answer — and a send that fails keeps everything for one more tap.
@MainActor
final class DocumentFlowFeedbackTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private let back = Data("back-jpeg".utf8)
    private let selfie = Data("selfie-jpeg".utf8)

    private func image(size: CGSize = CGSize(width: 1200, height: 760)) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private var zone: String { MRZParserTests.passport(number: "X12345678", nationality: "USA") }

    private func make(
        service: VerificationServiceProtocol = VerificationServiceMock(),
        zone: String? = nil
    ) -> DocumentVerificationViewModel {
        let viewModel = DocumentVerificationViewModel(
            service: service, analytics: RecordingAnalyticsClient(), declaredDateOfBirth: "1990-01-01"
        )
        let known = zone
        viewModel.zoneReader = { _ in known }
        return viewModel
    }

    private func sweep() -> LivenessSweep {
        LivenessSweep(
            straight: LivenessSample(yaw: 0.01, pitch: 0.0, t: 0),
            straightFrame: selfie,
            frames: (0..<8).map { LivenessFrame(sector: $0, sample: LivenessSample(yaw: 0.4, pitch: 0.1, t: Double($0) + 1), jpeg: selfie) },
            duration: 9
        )
    }

    /// Waits, briefly, for something the main actor will get to.
    private func eventually(_ condition: @autoclosure () -> Bool, _ message: String = "") async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - Reading on the phone

    /// A chosen photo is read under "Reading your document…" from the moment
    /// it is picked; then the front is in, with its picture, and the back is
    /// next.
    func testAChosenPhotoIsReadUnderAVisibleStateThenTheBackIsNext() async {
        let viewModel = make(zone: zone)
        let gate = ReadingGate()
        viewModel.converter = { data, isPDF in
            await gate.wait()
            return DocumentImport.jpeg(from: data, isPDF: isPDF)
        }
        viewModel.choose(.nationalId)
        let photo = image()
        let pick = Task { await viewModel.importDocument(photo, source: .photos) }

        await eventually(viewModel.reading == .front, "a pick reads as something happening")
        XCTAssertTrue(viewModel.isImporting, "the pickers wait")
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertNil(viewModel.frontImage)

        await gate.open()
        await pick.value

        XCTAssertNil(viewModel.reading)
        XCTAssertNil(viewModel.readingPreview, "nothing lingers once the step moved on")
        XCTAssertEqual(viewModel.phase, .captureBack, "the back is next, and says so")
        XCTAssertNotNil(viewModel.frontImage, "the front card has its picture")
        XCTAssertEqual(viewModel.frontSource, .photos)
        XCTAssertNil(viewModel.importProblem)
    }

    /// The camera's "Use this photo" is read the same way, under the same
    /// words — never a button that only spins.
    func testTheCamerasPhotoIsReadUnderTheSameState() async {
        let viewModel = make()
        let gate = ReadingGate()
        let known = zone
        viewModel.zoneReader = { _ in
            await gate.wait()
            return known
        }
        viewModel.choose(.passport)
        let photo = image()
        let use = Task { await viewModel.useCapturedPhoto(photo) }

        await eventually(viewModel.reading == .front)
        XCTAssertEqual(viewModel.readingPreview, photo, "the picture being read is shown with the words")

        await gate.open()
        await use.value
        XCTAssertNil(viewModel.reading)
        XCTAssertEqual(viewModel.phase, .review, "a passport's one page is in: the review shows it")
        XCTAssertTrue(viewModel.zoneIsReadable)
        XCTAssertEqual(viewModel.frontSource, .camera)
    }

    /// The simulator's sample photo carries its zone; nothing is read.
    func testAKnownZoneIsNotReadAgain() async {
        let viewModel = make(zone: nil)
        viewModel.choose(.passport)
        await viewModel.useCapturedPhoto(image(), knownZone: SampleCapture.passportZone())
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertTrue(viewModel.zoneIsReadable)
    }

    func testTheBacksPhotoGoesStraightToTheReview() async {
        let viewModel = make(zone: zone)
        viewModel.choose(.residencePermit)
        await viewModel.useCapturedPhoto(image())
        XCTAssertEqual(viewModel.phase, .captureBack)
        await viewModel.useCapturedPhoto(back)
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertEqual(viewModel.backImage, back)
        XCTAssertEqual(viewModel.backSource, .camera)
    }

    // MARK: - A photo that cannot be used

    /// iCloud handed back nothing: said as that, in plain words, and the
    /// person stays on the side they were adding.
    func testAPhotoThatNeverArrivedSaysSo() async {
        let viewModel = make()
        viewModel.choose(.nationalId)
        await viewModel.importDocument(source: .photos) { nil }
        XCTAssertEqual(viewModel.importProblem, .notDownloaded)
        XCTAssertEqual(viewModel.importError, L10n.t("document.upload.error.notDownloaded"))
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertNil(viewModel.reading)
    }

    func testAFileThatIsNotAPictureSaysWhyAndRetakeClearsIt() async {
        let viewModel = make()
        viewModel.choose(.passport)
        await viewModel.importDocument(Data("not a document".utf8), source: .file)
        XCTAssertEqual(viewModel.importProblem, .unreadableFile)
        XCTAssertEqual(viewModel.phase, .captureFront)
        viewModel.clearImportError()
        XCTAssertNil(viewModel.importProblem, "Retake goes back to the camera")
    }

    func testTheReasonsReadInArabic() {
        XCTAssertTrue(L10n.use("ar"))
        XCTAssertNotEqual(DocumentImportProblem.notDownloaded.message, "document.upload.error.notDownloaded")
        XCTAssertTrue(DocumentImportProblem.unreadableFile.message.contains("PDF"))
        XCTAssertEqual(L10n.t("document.side.front.added"), "تمت إضافة الوجه الأمامي")
        XCTAssertEqual(L10n.t("document.capture.back.title"), "والآن الوجه الخلفي")
    }

    /// A pick still being read when the person changed the document is
    /// dropped, not added to the new one.
    func testAPickOvertakenByAChangeOfDocumentIsDropped() async {
        let viewModel = make(zone: zone)
        let gate = ReadingGate()
        viewModel.converter = { data, _ in
            await gate.wait()
            return data
        }
        viewModel.choose(.nationalId)
        let pick = Task { await viewModel.importDocument(self.image(), source: .photos) }
        await eventually(viewModel.reading == .front)
        viewModel.changeDocument()
        await gate.open()
        await pick.value
        XCTAssertEqual(viewModel.phase, .chooseDocument)
        XCTAssertNil(viewModel.frontImage)
    }

    // MARK: - Retaking one side

    /// The back stays when the front is retaken from the review, and the
    /// review comes straight back: only the side that was wrong is taken again.
    func testRetakingTheFrontKeepsTheBack() async {
        let viewModel = make(zone: zone)
        viewModel.choose(.nationalId)
        await viewModel.useCapturedPhoto(image())
        await viewModel.useCapturedPhoto(back)
        XCTAssertEqual(viewModel.phase, .review)

        viewModel.retakeFront()
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertNil(viewModel.frontImage)
        XCTAssertEqual(viewModel.backImage, back)

        await viewModel.useCapturedPhoto(image())
        XCTAssertEqual(viewModel.phase, .review, "the back is already in")
    }

    func testRetakingTheBackKeepsTheFrontAndItsZone() async {
        let viewModel = make(zone: zone)
        viewModel.choose(.nationalId)
        await viewModel.useCapturedPhoto(image())
        await viewModel.useCapturedPhoto(back)

        viewModel.retakeBack()
        XCTAssertEqual(viewModel.phase, .captureBack)
        XCTAssertNil(viewModel.backImage)
        XCTAssertNotNil(viewModel.frontImage)
        XCTAssertTrue(viewModel.zoneIsReadable)

        viewModel.acceptBack(jpeg: back)
        XCTAssertEqual(viewModel.phase, .review)
    }

    func testAPassportHasNoBackToRetake() async {
        let viewModel = make(zone: zone)
        viewModel.choose(.passport)
        await viewModel.useCapturedPhoto(image())
        viewModel.retakeBack()
        XCTAssertEqual(viewModel.phase, .review)
    }

    // MARK: - Sending

    /// "Uploading… 42%" as the bytes go, "Checking your documents…" once they
    /// have all arrived, and the answer after that.
    func testTheUploadCountsUpThenTheCheckThenTheAnswer() async {
        let service = SteppedUploadService()
        let viewModel = make(service: service, zone: zone)
        viewModel.choose(.passport)
        await viewModel.useCapturedPhoto(image())
        viewModel.confirmDetails()
        viewModel.sweepCompleted(sweep())

        await eventually(viewModel.phase == .submitting)
        XCTAssertEqual(viewModel.submissionStage, .uploading(0))

        await service.report(0.42)
        await eventually(viewModel.submissionStage == .uploading(0.42))
        XCTAssertTrue(L10n.t("document.submitting.uploading", VideoCopy.percent(0.42)).hasSuffix("42%"))

        await service.report(0.3)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(viewModel.submissionStage, .uploading(0.42), "a late report never moves it back")

        await service.report(1)
        await eventually(viewModel.submissionStage == .checking, "every byte arrived: the server is checking")
        XCTAssertEqual(viewModel.phase, .submitting)

        await service.finish()
        await eventually(viewModel.phase == .submitted)
        XCTAssertEqual(viewModel.submittedCase?.status, .submitted)
    }

    /// No connection: a screen that says the documents did not send, with
    /// everything kept; Try again sends exactly the same pictures.
    func testAFailedSendKeepsEverythingAndTryAgainSendsTheSame() async {
        let service = FlakyUploadService()
        let viewModel = make(service: service, zone: zone)
        viewModel.choose(.nationalId)
        await viewModel.useCapturedPhoto(image())
        await viewModel.useCapturedPhoto(back)
        viewModel.confirmDetails()
        viewModel.sweepCompleted(sweep())

        await eventually(viewModel.phase == .sendFailed)
        XCTAssertNotNil(viewModel.sendFailure)
        XCTAssertNotNil(viewModel.frontImage)
        XCTAssertEqual(viewModel.backImage, back)
        XCTAssertEqual(viewModel.selfie, selfie)
        XCTAssertEqual(viewModel.progress?.index, viewModel.progress?.count)

        await viewModel.retrySend()
        XCTAssertEqual(viewModel.phase, .submitted)
        XCTAssertNil(viewModel.sendFailure)
        let sent = await service.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.front, sent.last?.front, "the same pictures, not new ones")
        XCTAssertEqual(sent.first?.back, sent.last?.back)
    }

    /// A refused face check is said at the top of the face step it goes back
    /// to, and goes once the face check is done again.
    func testAFaceCheckToRedoSaysWhyOnTheFaceStep() async {
        let viewModel = make(service: RefusingUploadService(code: .livenessMismatch), zone: zone)
        viewModel.choose(.passport)
        await viewModel.useCapturedPhoto(image())
        viewModel.confirmDetails()
        viewModel.sweepCompleted(sweep())
        await eventually(viewModel.phase == .liveness && viewModel.stepNotice != nil)
        XCTAssertNil(viewModel.toast)
        viewModel.sweepCompleted(sweep())
        XCTAssertNil(viewModel.stepNotice)
    }

    // MARK: - The transport

    /// The submission goes through the transport's counted upload, and what
    /// it counts reaches the flow.
    func testTheServiceUploadsThroughTheCountedPath() async throws {
        let network = CountingNetwork()
        let service = VerificationService(network: network, tokens: StaticAccessTokenProvider(), analytics: RecordingAnalyticsClient())
        let seen = Fractions()
        let documentCase = try await service.submitDocument(
            DocumentSubmission(documentType: .passport, front: Data([1]), selfie: Data([2]))
        ) { fraction in seen.append(fraction) }
        XCTAssertEqual(documentCase.id, "case-1")
        XCTAssertEqual(network.uploadedPaths, ["/verification/document"])
        XCTAssertEqual(seen.values, [0.5, 1])
    }

    /// A transport that cannot count — every test double — still sends.
    func testATransportThatCannotCountStillSends() async throws {
        let network = StubNetworkClient(responses: [CountingNetwork.caseJSON])
        let documentCase = try await network.upload(
            APIRequest(path: "/verification/document", method: .post, body: Data([1])),
            as: DocumentCase.self,
            progress: { _ in XCTFail("nothing to count") }
        )
        XCTAssertEqual(documentCase.id, "case-1")
        XCTAssertEqual(network.lastRequest?.path, "/verification/document")
    }
}

// MARK: - Doubles

/// Holds a step open until the test lets it go.
private actor ReadingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Double] = []
    func append(_ value: Double) { lock.withLock { seen.append(value) } }
    var values: [Double] { lock.withLock { seen } }
}

/// The verification calls the flow does not exercise here.
private protocol PassThroughVerification: VerificationServiceProtocol {}
extension PassThroughVerification {
    func setNationality(_ code: String) async throws -> VerificationStatusReport { VerificationStatusReport(status: .unstarted) }
    func setDateOfBirth(_ day: String) async throws -> VerificationStatusReport { VerificationStatusReport(status: .unstarted) }
    func startNafath(nationalID: String) async throws -> NafathStart { throw APIError.cancelled }
    func pollNafath(requestID: String) async throws -> NafathPoll { throw APIError.cancelled }
    func latestDocumentCase() async throws -> DocumentCase? { nil }
    func withdrawDocument() async throws -> VerificationStatusReport { VerificationStatusReport(status: .unstarted) }
    func appealVerification(message: String) async throws -> VerificationAppealReceipt { throw APIError.cancelled }
}

private func submittedCase() -> DocumentCase {
    DocumentCase(id: "case-1", status: .submitted, documentType: "passport", submittedAt: Date(), verificationStatus: .pendingReview)
}

/// An upload the test moves along by hand.
private actor SteppedUploadService: PassThroughVerification {
    private var progress: (@Sendable (Double) -> Void)?
    private var answer: CheckedContinuation<Void, Never>?
    private var finished = false

    func report(_ fraction: Double) async {
        while progress == nil { await Task.yield() }
        progress?(fraction)
    }

    func finish() async {
        while answer == nil && !finished { await Task.yield() }
        finished = true
        answer?.resume()
        answer = nil
    }

    func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        try await submitDocument(submission, progress: { _ in })
    }

    func submitDocument(_ submission: DocumentSubmission, progress: @escaping @Sendable (Double) -> Void) async throws -> DocumentCase {
        self.progress = progress
        if !finished {
            await withCheckedContinuation { answer = $0 }
        }
        return submittedCase()
    }
}

/// No connection the first time, fine the second.
private actor FlakyUploadService: PassThroughVerification {
    private(set) var sent: [DocumentSubmission] = []

    func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        sent.append(submission)
        if sent.count == 1 { throw APIError.transport("The Internet connection appears to be offline.") }
        return submittedCase()
    }
}

/// Refuses every submission with one code.
private actor RefusingUploadService: PassThroughVerification {
    let code: APIErrorCode
    init(code: APIErrorCode) { self.code = code }

    func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        throw APIError.api(code: code, message: "One frame per sector in the trace", status: 400)
    }
}

/// A transport that counts: half the bytes, then all of them.
private final class CountingNetwork: NetworkClient, @unchecked Sendable {
    static let caseJSON = """
    {"id": "case-1", "status": "submitted", "document_type": "passport", "nationality": null,
     "mrz_valid": false, "liveness_passed": false, "submitted_at": "2026-10-01T10:00:00Z",
     "verification_status": "pending_review"}
    """
    private let lock = NSLock()
    private var paths: [String] = []
    var uploadedPaths: [String] { lock.withLock { paths } }

    func send<Response: Decodable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        XCTFail("the document went without being counted: \(request.path)")
        throw APIError.cancelled
    }
    func send(_ request: APIRequest) async throws {}
    func sendData(_ request: APIRequest) async throws -> Data { Data() }

    func upload<Response: Decodable>(
        _ request: APIRequest,
        as type: Response.Type,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Response {
        lock.withLock { paths.append(request.path) }
        progress(0.5)
        progress(1)
        return try JSONCoding.decoder.decode(Response.self, from: Data(Self.caseJSON.utf8))
    }
}
