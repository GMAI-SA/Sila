import XCTest
@testable import Sila

/// Contract v25 on iOS: taking a submission back, the pre-screen's reasons
/// and the retake they lead to, and a wall that notices a decision while it
/// waits.
@MainActor
final class VerificationPolishTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private func status(_ json: String) throws -> VerificationStatusReport {
        try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
    }

    // MARK: - The wire

    func testCanWithdrawIsReadAndAnOlderServerNeverOffersIt() throws {
        XCTAssertTrue(try status(#"{"status": "pending_review", "can_withdraw": true}"#).canWithdraw)
        XCTAssertFalse(try status(#"{"status": "pending_review"}"#).canWithdraw)
        XCTAssertFalse(try status(#"{"status": "pending_review", "can_withdraw": "yes"}"#).canWithdraw,
                       "a value that is not a bool reads as no, never as a failed decode")
    }

    func testTheWithdrawalPostsNothingToItsRouteAndReadsTheStatusBack() async throws {
        let analytics = RecordingAnalyticsClient()
        let network = StubNetworkClient(responses: [
            """
            {"status": "unstarted", "rejection_reason": null, "submitted_at": null, "reviewed_at": null,
             "nationality": "US", "date_of_birth": "1990-01-01", "appeal": null, "can_withdraw": false,
             "methods": {"nafath": "coming_soon", "document": "available"}}
            """
        ])
        let service = VerificationService(network: network, tokens: StaticAccessTokenProvider(), analytics: analytics)

        let report = try await service.withdrawDocument()

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/verification/document/withdraw")
        XCTAssertEqual(request.method, .post)
        XCTAssertNil(request.body, "the route takes no body")
        XCTAssertEqual(report.status, .unstarted)
        XCTAssertFalse(report.canWithdraw)
        XCTAssertEqual(report.nationality, "US")
        XCTAssertEqual(analytics.events, [.documentWithdrawn])
    }

    func testNothingToWithdrawIsTypedTrackedByCodeAndSaidInWords() async {
        let analytics = RecordingAnalyticsClient()
        let network = StubNetworkClient(error: .api(code: .nothingToWithdraw,
                                                    message: "There is no submission waiting for review", status: 409))
        let service = VerificationService(network: network, tokens: StaticAccessTokenProvider(), analytics: analytics)
        do {
            _ = try await service.withdrawDocument()
            XCTFail("expected the refusal")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .nothingToWithdraw)
            XCTAssertEqual(error.userMessage, L10n.t("error.nothingToWithdraw"))
        } catch {
            XCTFail("untyped: \(error)")
        }
        XCTAssertEqual(analytics.events, [.documentWithdrawRefused])
        XCTAssertEqual(analytics.recorded.first?.properties, ["code": "nothing_to_withdraw"])
        XCTAssertEqual(APIErrorCode(serverCode: "nothing_to_withdraw"), .nothingToWithdraw)
    }

    // MARK: - The pre-screen's reasons

    /// The server's decision-email sentences (email_service.DECISION_REASONS),
    /// which the email sends in both languages because the machine cannot
    /// choose one. The app can, and shows the reader's.
    private let serverSentences: [String: (en: String, ar: String)] = [
        "not_a_document": (
            "The picture you sent as your identity document does not show an identity document. Photograph the document itself — your passport's photo page or your ID card — and submit again.",
            "الصورة التي أرسلتها على أنها وثيقة الهوية لا تُظهر وثيقة هوية. صوّر الوثيقة نفسها — صفحة الصورة في جوازك أو بطاقة هويتك — وأرسلها مرة أخرى."
        ),
        "unreadable_document": (
            "Your identity document could not be read: the picture is too blurred, dark or cropped. Photograph it again in good light, flat and whole, and submit again.",
            "تعذّرت قراءة وثيقة هويتك: الصورة مشوشة أو مظلمة أو مقصوصة. صوّرها مرة أخرى في إضاءة جيدة، مسطّحة وكاملة، وأرسلها مرة أخرى."
        ),
        "no_face": (
            "Your selfie does not show a face. Take the selfie again, looking at the camera, and submit again.",
            "صورتك الذاتية لا تُظهر وجهاً. التقطها مرة أخرى وأنت تنظر إلى الكاميرا، وأرسلها مرة أخرى."
        ),
        "not_genuine": (
            "The document you sent is not a genuine identity document — it is a specimen, a sample, a screenshot or a drawing. Photograph your own document and submit again.",
            "الوثيقة التي أرسلتها ليست وثيقة هوية حقيقية — بل نموذج أو عيّنة أو لقطة شاشة أو رسم. صوّر وثيقتك أنت وأرسلها مرة أخرى."
        ),
    ]

    func testEveryPreScreenReasonReadsAsTheServersSentenceInBothLanguages() throws {
        XCTAssertEqual(Set(VerificationRejection.screeningReasons), Set(serverSentences.keys))
        for (code, sentence) in serverSentences {
            XCTAssertTrue(VerificationRejection.isScreening(code))
            XCTAssertTrue(VerificationRejection.isMachineReason(code), "\(code) must follow the interface language")
            XCTAssertTrue(L10n.use("en"))
            XCTAssertEqual(VerificationRejection.display(code), sentence.en, code)
            XCTAssertTrue(L10n.use("ar"), "the build has no Arabic resources")
            XCTAssertEqual(VerificationRejection.display(code), sentence.ar, code)
        }
    }

    func testABirthdateMismatchHasASentenceAndAReviewersWordsStayTheirs() {
        XCTAssertNotEqual(VerificationRejection.display("date_of_birth_mismatch"), "date_of_birth_mismatch")
        XCTAssertTrue(VerificationRejection.isMachineReason("date_of_birth_mismatch"))
        XCTAssertFalse(VerificationRejection.isScreening("date_of_birth_mismatch"), "new pictures do not fix a claim")
        // An unmapped code still renders as a rejection, in the reviewer's words.
        XCTAssertEqual(VerificationRejection.display("Blurry — the corners are cut off"), "Blurry — the corners are cut off")
        XCTAssertFalse(VerificationRejection.isScreening("Blurry — the corners are cut off"))
        XCTAssertFalse(VerificationRejection.isScreening(nil))
    }

    // MARK: - The retake

    func testARetakeNamesTheDocumentTheLastCaseWasAbout() {
        let card = DocumentCase(id: "c1", status: .rejected, documentType: "national_id", rejectionReason: "no_face")
        XCTAssertEqual(DocumentRetake(latest: card).documentType, .nationalId)
        let unknown = DocumentCase(id: "c2", status: .rejected, documentType: "driving_licence")
        XCTAssertNil(DocumentRetake(latest: unknown).documentType, "a document this build does not offer opens the choice")
        XCTAssertNil(DocumentRetake(latest: nil).documentType)
    }

    func testARetakeOpensOnTheCameraOfThatDocument() {
        let viewModel = DocumentVerificationViewModel(service: VerificationServiceMock(), analytics: RecordingAnalyticsClient(),
                                                      declaredDateOfBirth: "1990-01-01", documentType: .residencePermit)
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertEqual(viewModel.documentType, .residencePermit)
        XCTAssertEqual(viewModel.progress?.index, 3)
    }

    func testTheBirthdateStillComesFirstWhenThereIsNone() {
        let viewModel = DocumentVerificationViewModel(service: VerificationServiceMock(), analytics: RecordingAnalyticsClient(),
                                                      declaredDateOfBirth: nil, documentType: .passport)
        XCTAssertEqual(viewModel.phase, .birthdate)
        XCTAssertNil(viewModel.documentType)
    }

    func testTheFirstCameraCanGoBackToTheDocumentChoice() {
        let viewModel = DocumentVerificationViewModel(service: VerificationServiceMock(), analytics: RecordingAnalyticsClient(),
                                                      declaredDateOfBirth: "1990-01-01", documentType: .passport)
        viewModel.importFailed()
        viewModel.changeDocument()
        XCTAssertEqual(viewModel.phase, .chooseDocument)
        XCTAssertNil(viewModel.documentType)
        XCTAssertNil(viewModel.importError)
        viewModel.choose(.nationalId)
        XCTAssertEqual(viewModel.phase, .captureFront)
    }

    func testTheSessionCarriesTheRetakeToOneWallOnly() async {
        let session = AuthSession(service: AuthServiceMock(scenario: .screenedOut),
                                  store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
                                  analytics: RecordingAnalyticsClient())
        session.retryVerification(retaking: DocumentRetake(documentType: .passport))
        XCTAssertEqual(session.route, .verificationWall(.rejected))
        XCTAssertEqual(session.documentRetake, DocumentRetake(documentType: .passport))
        session.retryVerification()
        XCTAssertNil(session.documentRetake, "\"Try another way\" offers the routes, not the camera")
    }

    func testThePreScreenScenarioRejectsWithACodeAndBothClaims() async throws {
        let report = try await AuthServiceMock(scenario: .screenedOut).verificationStatus()
        XCTAssertEqual(report.status, .rejected)
        XCTAssertEqual(report.rejectionReason, "not_a_document")
        XCTAssertEqual(report.nationality, "US")
        XCTAssertEqual(report.dateOfBirth, "1990-01-01")
        XCTAssertFalse(report.canWithdraw, "a decided case cannot be taken back")
    }

    // MARK: - Withdrawing from the under-review screen

    private func submitted(_ scenario: VerificationServiceMock.MockScenario = .expires)
        async -> (DocumentVerificationViewModel, VerificationServiceMock) {
        let service = VerificationServiceMock(scenario: scenario)
        let viewModel = DocumentVerificationViewModel(service: service, analytics: RecordingAnalyticsClient(),
                                                      declaredDateOfBirth: "1990-01-01")
        viewModel.choose(.passport)
        viewModel.acceptFront(jpeg: Data("front".utf8),
                              recognisedText: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.confirmDetails()
        viewModel.livenessCompleted(selfie: Data("selfie".utf8), turn: nil, challenges: LivenessChallenge.allCases)
        for _ in 0..<50 where viewModel.phase != .submitted && viewModel.phase != .liveness {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<50 where viewModel.phase == .liveness || viewModel.phase == .submitting {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (viewModel, service)
    }

    func testASubmissionWaitingForReviewCanBeTakenBack() async throws {
        let (viewModel, service) = await submitted()
        XCTAssertEqual(viewModel.phase, .submitted)
        XCTAssertTrue(viewModel.canWithdraw)
        viewModel.isConfirmingWithdrawal = true

        let outcome = await viewModel.withdraw()

        guard case let .withdrawn(report) = outcome else { return XCTFail("expected a withdrawal, got \(outcome)") }
        XCTAssertEqual(report.status, .unstarted)
        XCTAssertFalse(report.canWithdraw)
        XCTAssertFalse(viewModel.canWithdraw, "once is enough")
        XCTAssertFalse(viewModel.isConfirmingWithdrawal)
        XCTAssertNil(viewModel.submittedCase)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls.suffix(2), ["submitDocument", "withdrawDocument"])
        let again = await viewModel.withdraw()
        XCTAssertEqual(again, .failed, "nothing is offered twice")
    }

    func testACaseDecidedFirstIsNotAFailure() async {
        // The pre-screen answers within a minute: the withdrawal can arrive second.
        let (viewModel, _) = await submitted(.rejected)
        XCTAssertTrue(viewModel.canWithdraw)
        let outcome = await viewModel.withdraw()
        XCTAssertEqual(outcome, .nothingWaiting)
        XCTAssertFalse(viewModel.canWithdraw)
        XCTAssertNil(viewModel.toast, "the wall says where it stands; this screen says nothing")
    }

    func testOneAlreadyWaitingCanBeTakenBackFromHere() async {
        // `review_pending`: a submission from another device is still waiting.
        let (viewModel, _) = await submitted(.unavailable)
        XCTAssertEqual(viewModel.phase, .submitted)
        XCTAssertTrue(viewModel.canWithdraw)
    }

    func testAVerifiedAccountIsOfferedNothingToTakeBack() async {
        let (viewModel, _) = await submitted(.alreadyVerified)
        XCTAssertEqual(viewModel.phase, .submitted)
        XCTAssertFalse(viewModel.canWithdraw)
    }

    func testAWithdrawalThatDidNotArriveSaysSo() async {
        let (viewModel, service) = await submitted()
        await service.setScenario(.offline)
        let outcome = await viewModel.withdraw()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(viewModel.canWithdraw, "still waiting, so still offered")
        XCTAssertNotNil(viewModel.toast)
    }

    // MARK: - The wall

    private func wall(
        _ scenario: AuthServiceMock.MockScenario,
        status: VerificationStatus,
        verification: VerificationServiceProtocol? = VerificationServiceMock(),
        onDecision: (@MainActor () async -> Void)? = nil
    ) -> VerificationWallViewModel {
        let viewModel = VerificationWallViewModel(status: status, service: AuthServiceMock(scenario: scenario),
                                                  verification: verification, analytics: RecordingAnalyticsClient(),
                                                  onDecision: onDecision)
        viewModel.pause = { _ in }
        return viewModel
    }

    func testTheWallOffersTheWithdrawalExactlyWhenTheServerDoes() async {
        let waiting = wall(.pendingReview, status: .pendingReview)
        XCTAssertFalse(waiting.canWithdraw, "nothing is offered before the server has said")
        await waiting.refresh()
        XCTAssertTrue(waiting.canWithdraw)

        let decided = wall(.rejected, status: .rejected)
        await decided.refresh()
        XCTAssertFalse(decided.canWithdraw)

        let killSwitch = wall(.pendingReview, status: .pendingReview, verification: nil)
        await killSwitch.refresh()
        XCTAssertFalse(killSwitch.canWithdraw, "no verification module, no withdrawal")
    }

    func testWithdrawingFromTheWallStartsItAgain() async {
        let viewModel = wall(.pendingReview, status: .pendingReview)
        await viewModel.refresh()
        viewModel.isConfirmingWithdrawal = true
        let outcome = await viewModel.withdraw()
        guard case .withdrawn = outcome else { return XCTFail("expected a withdrawal, got \(outcome)") }
        XCTAssertEqual(viewModel.status, .unstarted)
        XCTAssertFalse(viewModel.canWithdraw)
        XCTAssertFalse(viewModel.isConfirmingWithdrawal)
        XCTAssertEqual(viewModel.presentation.primaryActionTitle, L10n.t("auth.wall.unstarted.action"))
        // Straight to the method choice: both claims are on file.
        XCTAssertEqual(VerificationWallViewModel.startStep(declared: viewModel.declaredNationality,
                                                           nafathAvailable: viewModel.nafathAvailable), .chooseMethod)
    }

    func testAWithdrawalThatArrivesSecondSaysSoAndHandsTheDecisionOn() async {
        var handedOn = 0
        let service = AuthServiceMock(scenario: .pendingReview)
        let viewModel = VerificationWallViewModel(status: .pendingReview, service: service,
                                                  verification: VerificationServiceMock(scenario: .rejected),
                                                  analytics: RecordingAnalyticsClient(),
                                                  onDecision: { handedOn += 1 })
        await viewModel.refresh()
        await service.setScenario(.screenedOut)
        let outcome = await viewModel.withdraw()
        XCTAssertEqual(outcome, .nothingWaiting)
        XCTAssertEqual(viewModel.toast?.text, L10n.t("error.nothingToWithdraw"))
        XCTAssertEqual(viewModel.status, .rejected)
        XCTAssertEqual(handedOn, 1, "the rejected screen carries the reason, the retake and the appeal")
    }

    func testTheWallWatchesUntilTheDecisionAndHandsARejectionOn() async {
        var handedOn = 0
        let service = AuthServiceMock(scenario: .pendingReview)
        let viewModel = VerificationWallViewModel(status: .pendingReview, service: service,
                                                  analytics: RecordingAnalyticsClient(),
                                                  onDecision: { handedOn += 1 })
        var reads = 0
        viewModel.pause = { _ in
            reads += 1
            // The pre-screen answers on the third look.
            if reads == 3 { await service.setScenario(.screenedOut) }
        }

        await viewModel.watchForDecision(attempts: 10)

        XCTAssertEqual(reads, 3, "it stops at the answer")
        XCTAssertEqual(viewModel.status, .rejected)
        XCTAssertEqual(viewModel.rejectionReason, "not_a_document")
        XCTAssertEqual(handedOn, 1)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls.filter { $0 == "verificationStatus" }.count, 3)
    }

    func testTheWallStopsWatchingWhenNothingIsUnderReview() async {
        let viewModel = wall(.rejected, status: .rejected)
        var reads = 0
        viewModel.pause = { _ in reads += 1 }
        await viewModel.watchForDecision()
        XCTAssertEqual(reads, 0)
    }

    func testTheWatchIsBoundedAndQuiet() async {
        let service = AuthServiceMock(scenario: .offline)
        let viewModel = VerificationWallViewModel(status: .pendingReview, service: service, analytics: RecordingAnalyticsClient())
        viewModel.pause = { _ in }
        await viewModel.watchForDecision(attempts: 4)
        let calls = await service.recordedCalls
        XCTAssertEqual(calls.count, 4)
        XCTAssertNil(viewModel.toast, "a background read says nothing when it fails")
    }

    func testARejectionTheWallOpenedOnIsNotHandedOnAgain() async {
        // "Try another way" puts a rejected account on the wall on purpose.
        var handedOn = 0
        let viewModel = wall(.rejected, status: .rejected, onDecision: { handedOn += 1 })
        await viewModel.refresh()
        XCTAssertEqual(handedOn, 0)
    }
}

