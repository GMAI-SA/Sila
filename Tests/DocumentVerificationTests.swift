import XCTest
@testable import Sila

/// The document flow: the phases, the refusals that are not failures, the
/// wire shape — and the privacy contract that nothing read off a document
/// reaches analytics.
@MainActor
final class DocumentVerificationTests: XCTestCase {

    private let front = Data("front-jpeg".utf8)
    private let back = Data("back-jpeg".utf8)
    private let selfie = Data("selfie-jpeg".utf8)
    private let turn = Data("turn-jpeg".utf8)

    private func makeViewModel(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient = RecordingAnalyticsClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> DocumentVerificationViewModel {
        DocumentVerificationViewModel(service: service, analytics: analytics, now: now)
    }

    /// Walks a view model to the point of submission with a verified US zone.
    private func reachLiveness(_ viewModel: DocumentVerificationViewModel, type: DocumentType = .passport) {
        viewModel.choose(type)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        if type.hasBack { viewModel.acceptBack(jpeg: back) }
        viewModel.confirmDetails()
        XCTAssertEqual(viewModel.phase, .liveness)
    }

    private func waitForSubmit(_ viewModel: DocumentVerificationViewModel) async {
        for _ in 0..<50 where viewModel.phase == .submitting || viewModel.phase == .liveness {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Phases

    func testAPassportGoesFrontThenReview() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.passport)
        XCTAssertEqual(viewModel.phase, .captureFront)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        XCTAssertEqual(viewModel.phase, .review, "a passport has one side")
        XCTAssertTrue(viewModel.zoneIsReadable)
        XCTAssertEqual(viewModel.mrz?.nationality, "US")
        XCTAssertEqual(viewModel.maskedDocumentNumber, "••••••678")
        XCTAssertTrue(viewModel.canContinueFromReview)
    }

    func testACardGoesFrontThenBackThenReview() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.nationalId)
        viewModel.acceptFront(jpeg: front, recognisedText: nil)
        XCTAssertEqual(viewModel.phase, .captureBack)
        viewModel.acceptBack(jpeg: back)
        XCTAssertEqual(viewModel.phase, .review)
    }

    func testAnUnreadableZoneStillContinuesToAReviewer() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: "nothing like a zone")
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertFalse(viewModel.zoneIsReadable)
        XCTAssertTrue(viewModel.canContinueFromReview, "a person reads the document instead")
    }

    func testAZoneThatNamesNoCountryCannotContinue() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "UTO"))
        XCTAssertTrue(viewModel.zoneIsReadable)
        XCTAssertTrue(viewModel.zoneHasNoCountry)
        XCTAssertFalse(viewModel.canContinueFromReview, "no country, no badge")
        viewModel.confirmDetails()
        XCTAssertEqual(viewModel.phase, .review)
    }

    func testAnExpiredDocumentIsStoppedBeforeTheBackIsPhotographed() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.nationalId)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA", expiry: "200101"))
        XCTAssertEqual(viewModel.phase, .documentExpired)
        viewModel.startAgain()
        XCTAssertEqual(viewModel.phase, .chooseDocument)
        XCTAssertNil(viewModel.frontImage)
    }

    func testASaudiDocumentIsSentToNafathBeforeAnythingIsUploaded() async {
        let service = VerificationServiceMock(scenario: .approved)
        let viewModel = makeViewModel(service: service)
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "SAU"))
        XCTAssertEqual(viewModel.phase, .useNafath, "one person, one account")
        XCTAssertNil(viewModel.frontImage)
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty, "nothing goes over the wire")
    }

    func testASaudiIssuedPermitIsSentToNafathToo() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.residencePermit)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "EGY", issuing: "SAU"))
        XCTAssertEqual(viewModel.phase, .useNafath)
    }

    func testTheServersUseNafathAnswerIsHandledTheSameWay() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .useNafath))
        reachLiveness(viewModel)
        viewModel.livenessCompleted(selfie: selfie, turn: nil, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .useNafath)
        XCTAssertNil(viewModel.toast, "not an error")
    }

    func testRetakeDropsTheZoneReadFromTheOldPhoto() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.retakeFront()
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertNil(viewModel.mrz)
        XCTAssertNil(viewModel.frontImage)
    }

    // MARK: - Submitting

    func testTheSelfieSequenceSubmitsAndReleasesTheImages() async {
        let service = VerificationServiceMock(scenario: .approved)
        let viewModel = makeViewModel(service: service)
        reachLiveness(viewModel)

        viewModel.livenessCompleted(selfie: selfie, turn: turn, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)

        XCTAssertEqual(viewModel.phase, .submitted)
        XCTAssertEqual(viewModel.submittedCase?.status, .submitted)
        XCTAssertEqual(viewModel.submittedCase?.verificationStatus, .pendingReview)
        XCTAssertNil(viewModel.frontImage, "images do not outlive the request")
        XCTAssertNil(viewModel.selfie)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["submitDocument"])
    }

    func testIdentityAlreadyUsedIsNotAFailure() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .identityAlreadyUsed))
        reachLiveness(viewModel)
        viewModel.livenessCompleted(selfie: selfie, turn: nil, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .identityUsed)
        XCTAssertNil(viewModel.toast)
    }

    func testUnderAgeIsTerminalWithTheServersWords() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .underMinimumAge))
        reachLiveness(viewModel)
        viewModel.livenessCompleted(selfie: selfie, turn: nil, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .underAge)
        XCTAssertFalse(viewModel.underAgeMessage.isEmpty)
    }

    func testAServerSideZoneRefusalSendsThePersonBackToTheCamera() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .invalidNationalId))
        reachLiveness(viewModel)
        viewModel.livenessCompleted(selfie: selfie, turn: nil, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertNil(viewModel.mrz)
        XCTAssertNotNil(viewModel.toast)
    }

    func testAlreadyVerifiedAndReviewPendingReadAsDone() async {
        for scenario in [VerificationServiceMock.MockScenario.alreadyVerified, .unavailable] {
            let viewModel = makeViewModel(service: VerificationServiceMock(scenario: scenario))
            reachLiveness(viewModel)
            viewModel.livenessCompleted(selfie: selfie, turn: nil, challenges: LivenessChallenge.allCases)
            await waitForSubmit(viewModel)
            XCTAssertEqual(viewModel.phase, .submitted, "\(scenario)")
        }
    }

    func testOfflineKeepsThePersonOnTheSelfieStepWithAToast() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .offline))
        reachLiveness(viewModel)
        viewModel.livenessCompleted(selfie: selfie, turn: nil, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .liveness)
        XCTAssertNotNil(viewModel.toast)
        XCTAssertNotNil(viewModel.frontImage, "nothing was sent, so nothing is released")
    }

    // MARK: - Privacy

    func testNothingReadOffTheDocumentReachesAnalytics() async {
        let analytics = RecordingAnalyticsClient()
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .approved), analytics: analytics)
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.confirmDetails()
        viewModel.livenessCompleted(selfie: selfie, turn: turn, challenges: LivenessChallenge.allCases)
        await waitForSubmit(viewModel)

        XCTAssertTrue(analytics.events.contains(.documentVerificationStarted))
        XCTAssertTrue(analytics.events.contains(.livenessCompleted))
        for entry in analytics.recorded {
            for (key, value) in entry.properties {
                XCTAssertFalse(value.contains("X12345678"), "\(entry.event) leaked the document number via \(key)")
                XCTAssertFalse(value.contains("DOE"), "\(entry.event) leaked the name via \(key)")
                XCTAssertNotEqual(value, "US", "\(entry.event) leaked the nationality via \(key)")
                XCTAssertNotEqual(value, "USA", "\(entry.event) leaked the nationality via \(key)")
                XCTAssertFalse(value.contains("900101"), "\(entry.event) leaked the birth date via \(key)")
            }
        }
    }

    // MARK: - Wire shape

    func testTheFormCarriesEveryPartUnderTheServersNames() throws {
        let zone = try XCTUnwrap(MRZParser.parse(MRZParserTests.passport(number: "X12345678", nationality: "USA")))
        let submission = DocumentSubmission(
            documentType: .nationalId, front: front, back: back, selfie: selfie, turn: turn,
            mrz: zone, challenges: LivenessChallenge.allCases
        )
        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)

        for name in ["document_type", "mrz", "liveness", "front", "back", "selfie", "turn"] {
            XCTAssertTrue(body.contains("name=\"\(name)\""), "missing part \(name)")
        }
        XCTAssertTrue(body.contains("national_id"))
        XCTAssertTrue(body.contains("[\"look_straight\",\"turn_left\",\"turn_right\"]"))
        XCTAssertTrue(body.contains(zone.text))
        XCTAssertTrue(body.contains("filename=\"front.jpg\""))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testAnInvalidZoneIsNeverSent() throws {
        // Flip the birth-date check digit (line 2, column 20) so exactly one
        // digit guards the wrong value.
        var lines = MRZParserTests.passport(number: "X12345678", nationality: "USA").components(separatedBy: "\n")
        var second = Array(lines[1])
        second[19] = second[19] == "9" ? "0" : Character(String(Int(String(second[19]))! + 1))
        lines[1] = String(second)
        let broken = try XCTUnwrap(MRZParser.parse(lines.joined(separator: "\n")))
        XCTAssertFalse(broken.isValid)
        let submission = DocumentSubmission(documentType: .passport, front: front, selfie: selfie, mrz: broken)
        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"mrz\""))
        XCTAssertFalse(body.contains("name=\"back\""))
        XCTAssertFalse(body.contains("name=\"liveness\""))
    }

    func testTheCaseDecodesTheServersShape() throws {
        let json = """
        {
          "id": "8b1d2f4e-0000-4000-8000-000000000001",
          "status": "submitted",
          "document_type": "passport",
          "nationality": "us",
          "mrz_valid": true,
          "liveness_passed": true,
          "submitted_at": "2026-09-06T20:00:00Z",
          "reviewed_at": null,
          "rejection_reason": null,
          "verification_status": "pending_review"
        }
        """
        let decoded = try JSONCoding.decoder.decode(DocumentCase.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .submitted)
        XCTAssertEqual(decoded.nationality, "US", "normalised like every other code")
        XCTAssertTrue(decoded.mrzValid)
        XCTAssertEqual(decoded.verificationStatus, .pendingReview)
        XCTAssertNil(decoded.reviewedAt)
    }

    func testAnUnknownStatusReadsAsStillWaiting() throws {
        let json = #"{"id": "x", "status": "escalated", "document_type": "passport"}"#
        let decoded = try JSONCoding.decoder.decode(DocumentCase.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .submitted)
        XCTAssertNil(decoded.nationality)
    }

    // MARK: - Liveness engine

    func testTheSequenceNeedsAHeldStraightLookThenTwoOppositeTurns() {
        let engine = LivenessEngine()
        let frame = Data("f".utf8)

        for _ in 0..<LivenessEngine.holdFrames { engine.observe(yaw: 0.02, faceVisible: true, frame: frame) }
        XCTAssertEqual(engine.completed, [.lookStraight])
        XCTAssertEqual(engine.selfie, frame)

        for _ in 0..<LivenessEngine.holdFrames { engine.observe(yaw: 0.5, faceVisible: true, frame: frame) }
        XCTAssertEqual(engine.completed, [.lookStraight, .turnLeft])
        XCTAssertNotNil(engine.turnFrame)

        // Turning the same way again is not the second turn.
        for _ in 0..<LivenessEngine.holdFrames { engine.observe(yaw: 0.5, faceVisible: true, frame: frame) }
        XCTAssertEqual(engine.completed.count, 2)
        XCTAssertFalse(engine.isFinished)

        for _ in 0..<LivenessEngine.holdFrames { engine.observe(yaw: -0.5, faceVisible: true, frame: frame) }
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.completed, LivenessChallenge.allCases)
    }

    func testAGlanceDoesNotCount() {
        let engine = LivenessEngine()
        let frame = Data("f".utf8)
        for _ in 0..<(LivenessEngine.holdFrames - 1) { engine.observe(yaw: 0.0, faceVisible: true, frame: frame) }
        engine.observe(yaw: 0.6, faceVisible: true, frame: frame)
        XCTAssertTrue(engine.completed.isEmpty, "the hold restarts when the pose breaks")
        XCTAssertNil(engine.selfie)
    }

    func testLosingTheFaceResetsTheHold() {
        let engine = LivenessEngine()
        let frame = Data("f".utf8)
        for _ in 0..<(LivenessEngine.holdFrames - 1) { engine.observe(yaw: 0.0, faceVisible: true, frame: frame) }
        engine.observe(yaw: nil, faceVisible: false, frame: nil)
        XCTAssertFalse(engine.faceVisible)
        engine.observe(yaw: 0.0, faceVisible: true, frame: frame)
        XCTAssertTrue(engine.completed.isEmpty)
    }
}
