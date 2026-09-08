import XCTest
@testable import Sila

/// The document flow: the birthdate claim, the phases, the refusals that are
/// not failures, the wire shape — and the privacy contract that nothing read
/// off a document reaches analytics.
@MainActor
final class DocumentVerificationTests: XCTestCase {

    private let front = Data("front-jpeg".utf8)
    private let back = Data("back-jpeg".utf8)
    private let selfie = Data("selfie-jpeg".utf8)
    private let turn = Data("turn-jpeg".utf8)

    /// The default test passport carries 1990-01-01, so this claim matches it.
    private let declared = "1990-01-01"

    private func makeViewModel(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient = RecordingAnalyticsClient(),
        declared: String? = "1990-01-01",
        now: @escaping @Sendable () -> Date = Date.init
    ) -> DocumentVerificationViewModel {
        DocumentVerificationViewModel(service: service, analytics: analytics, declaredDateOfBirth: declared, now: now)
    }

    private func sweep() -> LivenessSweep {
        LivenessSweep(
            straight: LivenessSample(yaw: 0.01, pitch: 0.0, t: 0),
            straightFrame: selfie,
            frames: (0..<8).map { LivenessFrame(sector: $0, sample: LivenessSample(yaw: 0.4, pitch: 0.1, t: Double($0) + 1), jpeg: turn) },
            duration: 9
        )
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

    // MARK: - The birthdate claim

    func testTheBirthdateIsAskedFirstWhenThereIsNoneOnFile() async {
        let service = VerificationServiceMock()
        let viewModel = makeViewModel(service: service, declared: nil)
        XCTAssertEqual(viewModel.phase, .birthdate)
        XCTAssertEqual(viewModel.progress?.index, 1)
        viewModel.birthdateSelection = ISODay.date("1990-01-01")!
        await viewModel.submitBirthdate()
        XCTAssertEqual(viewModel.phase, .chooseDocument)
        XCTAssertEqual(viewModel.declaredDateOfBirth, "1990-01-01")
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["setDateOfBirth"])
    }

    func testAClaimAlreadyOnFileSkipsTheWheel() {
        let viewModel = makeViewModel(service: VerificationServiceMock(), declared: "1988-03-09")
        XCTAssertEqual(viewModel.phase, .chooseDocument)
        XCTAssertEqual(viewModel.declaredDateOfBirth, "1988-03-09")
    }

    func testAChildsAnswerIsTerminalBeforeAnyDocument() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .underMinimumAge), declared: nil)
        viewModel.birthdateSelection = Date().addingTimeInterval(-5 * 365 * 86_400)
        await viewModel.submitBirthdate()
        XCTAssertEqual(viewModel.phase, .underAge)
        XCTAssertFalse(viewModel.underAgeMessage.isEmpty)
    }

    func testAnImpossibleBirthdateCannotBeSent() {
        let viewModel = makeViewModel(service: VerificationServiceMock(), declared: nil)
        viewModel.birthdateSelection = Date().addingTimeInterval(86_400)
        XCTAssertFalse(viewModel.canSubmitBirthdate, "the future")
        viewModel.birthdateSelection = ISODay.date("1850-01-01")!
        XCTAssertFalse(viewModel.canSubmitBirthdate, "an impossible age")
        viewModel.birthdateSelection = ISODay.date("1990-01-01")!
        XCTAssertTrue(viewModel.canSubmitBirthdate)
    }

    func testADocumentThatContradictsTheClaimStopsBeforeAnythingIsUploaded() async {
        let service = VerificationServiceMock()
        let viewModel = makeViewModel(service: service, declared: "1985-05-05")
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        XCTAssertEqual(viewModel.phase, .dateOfBirthMismatch)
        XCTAssertTrue(viewModel.zoneContradictsBirthdate)
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty, "nothing goes over the wire")

        // A wheel can slip: back to it, then the same document is fine.
        viewModel.changeBirthdate()
        XCTAssertEqual(viewModel.phase, .birthdate)
        XCTAssertNil(viewModel.frontImage)
        viewModel.birthdateSelection = ISODay.date("1990-01-01")!
        await viewModel.submitBirthdate()
        XCTAssertEqual(viewModel.phase, .chooseDocument)
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        XCTAssertEqual(viewModel.phase, .review)
    }

    func testTheServersMismatchReadsTheSameWay() async {
        let viewModel = makeViewModel(service: DateOfBirthMismatchService())
        reachLiveness(viewModel)
        viewModel.sweepCompleted(sweep())
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .dateOfBirthMismatch)
    }

    func testTheClaimIsNeverInTheZoneAndNeverInAnalytics() async {
        let analytics = RecordingAnalyticsClient()
        let viewModel = makeViewModel(service: VerificationServiceMock(), analytics: analytics, declared: nil)
        viewModel.birthdateSelection = ISODay.date("1990-01-01")!
        await viewModel.submitBirthdate()
        XCTAssertTrue(analytics.events.contains(.birthdateDeclared))
        for entry in analytics.recorded {
            for (key, value) in entry.properties {
                XCTAssertFalse(value.contains("1990"), "\(entry.event) leaked the birthdate via \(key)")
            }
        }
    }

    // MARK: - Phases

    func testAPassportGoesFrontThenReview() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.passport)
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertEqual(viewModel.progress?.index, 3)
        viewModel.acceptFront(jpeg: front, recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        XCTAssertEqual(viewModel.phase, .review, "a passport has one side")
        XCTAssertEqual(viewModel.progress.map { "\($0.index)/\($0.count)" }, "4/6")
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
        XCTAssertEqual(viewModel.progress.map { "\($0.index)/\($0.count)" }, "4/7")
        viewModel.acceptBack(jpeg: back)
        XCTAssertEqual(viewModel.phase, .review)
    }

    func testAnUnreadableZoneStillContinuesToAReviewer() {
        let viewModel = makeViewModel(service: VerificationServiceMock())
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: front, recognisedText: "nothing like a zone")
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertFalse(viewModel.zoneIsReadable)
        XCTAssertFalse(viewModel.zoneContradictsBirthdate, "no zone, nothing to contradict")
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
        XCTAssertNil(viewModel.progress, "a terminal screen is not a step")
        viewModel.startAgain()
        XCTAssertEqual(viewModel.phase, .chooseDocument, "the birthdate on file stays")
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
        viewModel.sweepCompleted(sweep())
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

    func testTheHeadTurnSubmitsAndReleasesTheImages() async {
        let service = VerificationServiceMock(scenario: .approved)
        let viewModel = makeViewModel(service: service)
        reachLiveness(viewModel)
        XCTAssertEqual(viewModel.progress.map { "\($0.index)/\($0.count)" }, "5/6")

        viewModel.sweepCompleted(sweep())
        await waitForSubmit(viewModel)

        XCTAssertEqual(viewModel.phase, .submitted)
        XCTAssertEqual(viewModel.submittedCase?.status, .submitted)
        XCTAssertEqual(viewModel.submittedCase?.verificationStatus, .pendingReview)
        XCTAssertNil(viewModel.frontImage, "images do not outlive the request")
        XCTAssertNil(viewModel.selfie)
        XCTAssertNil(viewModel.sweep)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["submitDocument"])
    }

    func testIdentityAlreadyUsedIsNotAFailure() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .identityAlreadyUsed))
        reachLiveness(viewModel)
        viewModel.sweepCompleted(sweep())
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .identityUsed)
        XCTAssertNil(viewModel.toast)
    }

    func testUnderAgeIsTerminalWithTheServersWords() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .underMinimumAge))
        reachLiveness(viewModel)
        viewModel.sweepCompleted(sweep())
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .underAge)
        XCTAssertFalse(viewModel.underAgeMessage.isEmpty)
    }

    func testAServerSideZoneRefusalSendsThePersonBackToTheCamera() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .invalidNationalId))
        reachLiveness(viewModel)
        viewModel.sweepCompleted(sweep())
        await waitForSubmit(viewModel)
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertNil(viewModel.mrz)
        XCTAssertNotNil(viewModel.toast)
    }

    func testAlreadyVerifiedAndReviewPendingReadAsDone() async {
        for scenario in [VerificationServiceMock.MockScenario.alreadyVerified, .unavailable] {
            let viewModel = makeViewModel(service: VerificationServiceMock(scenario: scenario))
            reachLiveness(viewModel)
            viewModel.sweepCompleted(sweep())
            await waitForSubmit(viewModel)
            XCTAssertEqual(viewModel.phase, .submitted, "\(scenario)")
        }
    }

    func testOfflineKeepsThePersonOnTheFaceStepWithAToast() async {
        let viewModel = makeViewModel(service: VerificationServiceMock(scenario: .offline))
        reachLiveness(viewModel)
        viewModel.sweepCompleted(sweep())
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
        viewModel.sweepCompleted(sweep())
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
                XCTAssertFalse(value.contains("1990"), "\(entry.event) leaked the birth date via \(key)")
            }
        }
    }

    // MARK: - Wire shape

    func testTheFormCarriesTheRingUnderTheServersNames() throws {
        let zone = try XCTUnwrap(MRZParser.parse(MRZParserTests.passport(number: "X12345678", nationality: "USA")))
        let submission = DocumentSubmission(
            documentType: .nationalId, front: front, back: back, selfie: selfie, mrz: zone, sweep: sweep()
        )
        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)

        for name in ["document_type", "mrz", "liveness", "front", "back", "selfie", "frames"] {
            XCTAssertTrue(body.contains("name=\"\(name)\""), "missing part \(name)")
        }
        XCTAssertEqual(body.components(separatedBy: "name=\"frames\"").count - 1, 8, "one part per sector")
        XCTAssertTrue(body.contains("filename=\"turn_7.jpg\""))
        XCTAssertFalse(body.contains("name=\"turn\""), "the legacy part is not sent with a sweep")
        XCTAssertTrue(body.contains("\"version\":2"))
        XCTAssertTrue(body.contains("\"sectors\":[{\"sector\":0,"))
        XCTAssertTrue(body.contains("\"duration\":9.000"))
        XCTAssertTrue(body.contains(zone.text))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testTheLegacyThreePoseFormStillEncodes() throws {
        let submission = DocumentSubmission(
            documentType: .passport, front: front, selfie: selfie, turn: turn, challenges: LivenessChallenge.allCases
        )
        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("[\"look_straight\",\"turn_left\",\"turn_right\"]"))
        XCTAssertTrue(body.contains("name=\"turn\""))
        XCTAssertFalse(body.contains("name=\"frames\""))
    }

    func testAnInvalidZoneIsNeverSent() throws {
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

    func testTheStatusReportCarriesTheDeclaredBirthdateAsADay() throws {
        let json = #"{"status": "unstarted", "rejection_reason": null, "submitted_at": null, "reviewed_at": null, "nationality": "us", "date_of_birth": "1990-01-01"}"#
        let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.dateOfBirth, "1990-01-01")
        XCTAssertEqual(ISODay.date("1990-01-01").map(ISODay.string), "1990-01-01", "a day survives the round trip whatever the zone")
        XCTAssertNil(ISODay.normalised("not a day"))
    }

    // MARK: - The sweep engine

    private func reading(yaw: Double, pitch: Double, x: CGFloat = 0.5) -> SweepEngine.Reading {
        SweepEngine.Reading(yaw: yaw, pitch: pitch, box: CGRect(x: x - 0.2, y: 0.3, width: 0.4, height: 0.4))
    }

    func testTheSweepNeedsAStraightLookThenEveryDirection() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SweepEngine(now: { clock })
        let frame = Data("f".utf8)

        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.02, pitch: 0.01), frame: frame) }
        XCTAssertEqual(engine.straightFrame, frame)
        XCTAssertTrue(engine.covered.isEmpty)

        for sector in 0..<SweepEngine.sectors {
            let angle = Double(sector) * 2 * .pi / Double(SweepEngine.sectors)
            clock = clock.addingTimeInterval(1)
            for _ in 0..<SweepEngine.holdFrames {
                engine.observe(reading(yaw: 0.4 * sin(angle), pitch: 0.4 * cos(angle)), frame: frame)
            }
            XCTAssertTrue(engine.covered.contains(sector), "sector \(sector) was not covered")
        }
        XCTAssertTrue(engine.isFinished)
        let sweep = engine.sweep()
        XCTAssertEqual(sweep?.frames.count, 8)
        XCTAssertEqual(sweep?.frames.map(\.sector), Array(0..<8), "in the order they were turned to")
        XCTAssertEqual(sweep?.duration ?? -1, 8, accuracy: 0.001)
    }

    func testAGlanceDoesNotCoverASector() {
        let engine = SweepEngine()
        let frame = Data("f".utf8)
        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.0, pitch: 0.0), frame: frame) }
        for _ in 0..<(SweepEngine.holdFrames - 1) { engine.observe(reading(yaw: 0.5, pitch: 0.0), frame: frame) }
        engine.observe(reading(yaw: 0.0, pitch: 0.5), frame: frame)
        XCTAssertTrue(engine.covered.isEmpty, "a direction held for less than the hold does not count")
    }

    func testLosingTheFaceOrAJumpRestartsTheSweep() {
        let engine = SweepEngine()
        let frame = Data("f".utf8)
        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.0, pitch: 0.0), frame: frame) }
        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.5, pitch: 0.0), frame: frame) }
        XCTAssertEqual(engine.coveredCount, 1)

        engine.observe(nil, frame: nil)
        XCTAssertFalse(engine.faceVisible)
        XCTAssertTrue(engine.restarted, "the sequence is of one continuous face")
        XCTAssertTrue(engine.covered.isEmpty)
        XCTAssertNil(engine.straightFrame)

        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.0, pitch: 0.0), frame: frame) }
        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.5, pitch: 0.0), frame: frame) }
        XCTAssertEqual(engine.coveredCount, 1)
        engine.observe(reading(yaw: 0.5, pitch: 0.0, x: 0.9), frame: frame)
        XCTAssertTrue(engine.restarted, "a face that leapt across the frame is a different photograph")
        XCTAssertTrue(engine.covered.isEmpty)
    }

    func testSixDirectionsAreEnoughAfterAWhile() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SweepEngine(now: { clock })
        let frame = Data("f".utf8)
        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.0, pitch: 0.0), frame: frame) }
        for sector in 0..<5 {
            let angle = Double(sector) * 2 * .pi / 8
            clock = clock.addingTimeInterval(2)
            for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.4 * sin(angle), pitch: 0.4 * cos(angle)), frame: frame) }
        }
        XCTAssertFalse(engine.isFinished)
        clock = clock.addingTimeInterval(SweepEngine.leniencyAfter)
        let angle = 5 * 2 * Double.pi / 8
        for _ in 0..<SweepEngine.holdFrames { engine.observe(reading(yaw: 0.4 * sin(angle), pitch: 0.4 * cos(angle)), frame: frame) }
        XCTAssertTrue(engine.isFinished, "six of eight after thirty seconds")
        XCTAssertEqual(engine.sweep()?.frames.count, 6)
    }

    func testTheRingMapsEveryDirectionToOneSector() {
        var seen: Set<Int> = []
        for step in 0..<64 {
            let angle = Double(step) * 2 * .pi / 64
            seen.insert(SweepEngine.sector(yaw: sin(angle), pitch: cos(angle)))
        }
        XCTAssertEqual(seen, Set(0..<8))
        XCTAssertEqual(SweepEngine.sector(yaw: 0, pitch: 1), 0, "up is the top")
        XCTAssertEqual(SweepEngine.sector(yaw: 1, pitch: 0), 2, "and it runs clockwise")
    }

    // MARK: - The capture guide

    func testTheGuideAsksForCloserThenStillThenTakesThePhoto() {
        let guide = CaptureGuide()
        XCTAssertEqual(guide.state, .searching)
        guide.observe(card: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2), zoneSeen: false)
        XCTAssertEqual(guide.state, .adjust(.closer))
        guide.observe(card: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.5), zoneSeen: false)
        guide.observe(card: CGRect(x: 0.2, y: 0.3, width: 0.8, height: 0.5), zoneSeen: false)
        XCTAssertEqual(guide.state, .adjust(.steady), "it moved")
        for _ in 0..<CaptureGuide.holdFrames {
            guide.observe(card: CGRect(x: 0.2, y: 0.3, width: 0.8, height: 0.5), zoneSeen: true)
        }
        XCTAssertEqual(guide.state, .ready)
        XCTAssertTrue(guide.zoneSeen)
        guide.observe(card: nil, zoneSeen: false)
        XCTAssertEqual(guide.state, .ready, "once the photo is taking itself the guide stops moving")
        guide.reset()
        XCTAssertEqual(guide.state, .searching)
    }
}

/// A service whose submit answers the server's birthdate mismatch.
private actor DateOfBirthMismatchService: VerificationServiceProtocol {
    private let backing = VerificationServiceMock()

    func setNationality(_ code: String) async throws -> VerificationStatusReport { try await backing.setNationality(code) }
    func setDateOfBirth(_ day: String) async throws -> VerificationStatusReport { try await backing.setDateOfBirth(day) }
    func startNafath(nationalID: String) async throws -> NafathStart { try await backing.startNafath(nationalID: nationalID) }
    func pollNafath(requestID: String) async throws -> NafathPoll { try await backing.pollNafath(requestID: requestID) }
    func latestDocumentCase() async throws -> DocumentCase? { try await backing.latestDocumentCase() }
    func appealVerification(message: String) async throws -> VerificationAppealReceipt { try await backing.appealVerification(message: message) }
    func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        throw APIError.api(code: .dateOfBirthMismatch, message: "The date of birth on this document does not match the date of birth you entered", status: 403)
    }
}
