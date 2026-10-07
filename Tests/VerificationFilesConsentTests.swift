import UIKit
import XCTest
@testable import Sila

/// Contract v34 (verification files), the iPhone's part, mirroring §11:
/// the consent parts travel only with the tick and are not signed; the card
/// shows only while the server announces a version, in one language, starts
/// unticked and never blocks Send; the tick is cleared by a retake; the case
/// and the status decode with and without the new keys; the copy follows
/// `retention`; and Settings › Privacy › Verification photos shows only with
/// kept photos and withdraws them.
@MainActor
final class VerificationFilesConsentTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private let selfie = Data("selfie-jpeg".utf8)

    private func image() -> Data {
        let size = CGSize(width: 1200, height: 760)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private var zone: String { MRZParserTests.passport(number: "X12345678", nationality: "USA") }

    private func sweep() -> LivenessSweep {
        LivenessSweep(
            straight: LivenessSample(yaw: 0.01, pitch: 0.0, t: 0),
            straightFrame: selfie,
            frames: (0..<8).map { LivenessFrame(sector: $0, sample: LivenessSample(yaw: 0.4, pitch: 0.1, t: Double($0) + 1), jpeg: selfie) },
            duration: 9
        )
    }

    private func make(_ service: VerificationServiceProtocol) -> DocumentVerificationViewModel {
        let viewModel = DocumentVerificationViewModel(
            service: service, analytics: RecordingAnalyticsClient(), declaredDateOfBirth: "1990-01-01"
        )
        let known = zone
        viewModel.zoneReader = { _ in known }
        return viewModel
    }

    /// Photographs a passport and does the face check.
    private func walkToTheEnd(_ viewModel: DocumentVerificationViewModel) async {
        viewModel.choose(.passport)
        await viewModel.useCapturedPhoto(image())
        viewModel.confirmDetails()
        viewModel.sweepCompleted(sweep())
    }

    private func eventually(_ condition: @autoclosure () -> Bool, _ message: String = "") async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - The form (§7.3)

    func testTheConsentPartsTravelOnlyWithTheTickRightAfterTheSource() {
        var submission = DocumentSubmission(documentType: .passport, front: Data([1]), selfie: Data([2]))
        XCTAssertNil(submission.fieldValue("consent_version"))
        XCTAssertNil(submission.fieldValue("consent_locale"))
        XCTAssertEqual(submission.textFields.map(\.name), ["document_type", "document_source"])

        submission.consent = RetentionConsent(version: "vf1", locale: "ar")
        XCTAssertEqual(
            submission.textFields.map(\.name),
            ["document_type", "document_source", "consent_version", "consent_locale"]
        )
        XCTAssertEqual(submission.fieldValue("consent_version"), "vf1")
        XCTAssertEqual(submission.fieldValue("consent_locale"), "ar")

        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"consent_version\"\r\n\r\nvf1"), body)
        XCTAssertTrue(body.contains("name=\"consent_locale\"\r\n\r\nar"))
    }

    func testTheLocaleIsEnOrAr() {
        XCTAssertEqual(RetentionConsent(version: "vf1", locale: "ar").locale, "ar")
        XCTAssertEqual(RetentionConsent(version: "vf1", locale: "en").locale, "en")
        XCTAssertEqual(RetentionConsent(version: "vf1", locale: "fr").locale, "en")
    }

    /// v32 §4 is unchanged: the App Attest client data is byte-identical
    /// with and without consent.
    func testTheClientDataIsTheSameWithAndWithoutConsent() throws {
        var plain = DocumentSubmission(documentType: .passport, front: Data([1]), selfie: Data([2]), sweep: sweep())
        plain.source = .camera
        var ticked = plain
        ticked.consent = RetentionConsent(version: "vf1", locale: "en")
        XCTAssertEqual(
            try AppAttestClientData(challenge: "c-1", submission: plain).encoded(),
            try AppAttestClientData(challenge: "c-1", submission: ticked).encoded()
        )
    }

    // MARK: - What comes back (§2.1, §7.4)

    func testTheStatusDecodesTheAnnouncementAndTheKeptPhotos() throws {
        let json = #"""
        {"status":"verified","retention_consent_version":"vf1","retention_consent_required":true,
         "verification_photos":{"kept_attempts":2,"consented_at":"2026-10-01T09:00:00Z"}}
        """#
        let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.retentionConsentVersion, "vf1")
        XCTAssertTrue(report.retentionConsentRequired)
        XCTAssertEqual(report.verificationPhotos?.keptAttempts, 2)
        XCTAssertNotNil(report.verificationPhotos?.consentedAt)
    }

    func testAnOlderServersStatusOffersNothing() throws {
        for json in [#"{"status":"unstarted"}"#,
                     #"{"status":"unstarted","retention_consent_version":null,"verification_photos":null}"#,
                     #"{"status":"unstarted","retention_consent_version":""}"#] {
            let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
            XCTAssertNil(report.retentionConsentVersion, json)
            XCTAssertFalse(report.retentionConsentRequired, json)
            XCTAssertNil(report.verificationPhotos, json)
        }
    }

    func testTheCaseDecodesWithAndWithoutRetention() throws {
        let kept = try JSONCoding.decoder.decode(DocumentCase.self, from: Data(
            #"{"id":"c1","status":"rejected","retention":"with_account","images_kept":true}"#.utf8))
        XCTAssertEqual(kept.retention, .withAccount)
        XCTAssertTrue(kept.imagesKept)
        XCTAssertTrue(kept.photosKeptInFile)

        let old = try JSONCoding.decoder.decode(DocumentCase.self, from: Data(#"{"id":"c2","status":"submitted"}"#.utf8))
        XCTAssertEqual(old.retention, .untilDecision)
        XCTAssertFalse(old.imagesKept)
        XCTAssertFalse(old.photosKeptInFile)

        let unknown = try JSONCoding.decoder.decode(DocumentCase.self, from: Data(
            #"{"id":"c3","status":"submitted","retention":"forever","images_kept":true}"#.utf8))
        XCTAssertEqual(unknown.retention, .untilDecision, "unknown values decode as until_decision")
        XCTAssertFalse(unknown.photosKeptInFile)

        let withdrawn = try JSONCoding.decoder.decode(DocumentCase.self, from: Data(
            #"{"id":"c4","status":"approved","retention":"with_account","images_kept":false}"#.utf8))
        XCTAssertFalse(withdrawn.photosKeptInFile, "consent withdrawn: nothing kept, the old copy")
    }

    // MARK: - The card (§7.2)

    func testNoAnnouncementNoCardTheFlowSendsAsBefore() async {
        let service = VerificationServiceMock()
        let viewModel = make(service)
        await viewModel.loadConsentOffer()
        XCTAssertFalse(viewModel.offersConsent)
        await walkToTheEnd(viewModel)
        await eventually(viewModel.phase == .submitted, "sent straight after the face check")
        let consent = await service.lastConsent
        XCTAssertNil(consent)
        XCTAssertFalse(viewModel.sentWithConsent)
    }

    func testAnAnnouncementShowsTheCardUntickedAndSendWorksWithoutTheTick() async {
        let service = VerificationServiceMock(consentVersion: "vf1")
        let viewModel = make(service)
        await viewModel.loadConsentOffer()
        XCTAssertTrue(viewModel.offersConsent)
        await walkToTheEnd(viewModel)
        await eventually(viewModel.phase == .send, "the step that sends, with the card")
        XCTAssertFalse(viewModel.consentTicked, "the box starts unticked")
        XCTAssertTrue(viewModel.canSend, "Send is enabled without the tick")
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("submitDocument"), "nothing goes before Send")

        await viewModel.send()
        XCTAssertEqual(viewModel.phase, .submitted)
        let consent = await service.lastConsent
        XCTAssertNil(consent, "unticked sends no consent parts")
        XCTAssertFalse(viewModel.sentWithConsent)
        XCTAssertEqual(viewModel.submittedCase?.retention, .untilDecision)
    }

    func testTickedSendsExactlyTheAnnouncedVersionInTheCardsLanguage() async {
        L10n.use("ar")
        let service = VerificationServiceMock(consentVersion: "vf1")
        let viewModel = make(service)
        await viewModel.loadConsentOffer()
        await walkToTheEnd(viewModel)
        await eventually(viewModel.phase == .send)
        viewModel.consentTicked = true
        XCTAssertTrue(viewModel.canSend, "Send is enabled with the tick too")
        await viewModel.send()
        XCTAssertEqual(viewModel.phase, .submitted)
        let consent = await service.lastConsent
        XCTAssertEqual(consent, RetentionConsent(version: "vf1", locale: "ar"))
        XCTAssertTrue(viewModel.sentWithConsent)
        XCTAssertEqual(viewModel.submittedCase?.retention, .withAccount)
    }

    func testTheTickIsClearedByARetakeAndByStartingAgain() async {
        let viewModel = make(VerificationServiceMock(consentVersion: "vf1"))
        await viewModel.loadConsentOffer()
        await walkToTheEnd(viewModel)
        await eventually(viewModel.phase == .send)
        viewModel.consentTicked = true
        viewModel.retakeFront()
        XCTAssertFalse(viewModel.consentTicked, "a retake asks again")

        await viewModel.useCapturedPhoto(image())
        viewModel.confirmDetails()
        viewModel.sweepCompleted(sweep())
        await eventually(viewModel.phase == .send)
        XCTAssertFalse(viewModel.consentTicked, "back at the card, unticked")
        viewModel.consentTicked = true
        viewModel.startAgain()
        XCTAssertFalse(viewModel.consentTicked)
    }

    func testTheServerCanMakeTheTickRequired() async {
        let viewModel = make(VerificationServiceMock(consentVersion: "vf1", consentRequired: true))
        await viewModel.loadConsentOffer()
        await walkToTheEnd(viewModel)
        await eventually(viewModel.phase == .send)
        XCTAssertFalse(viewModel.canSend, "required: not without the tick")
        await viewModel.send()
        XCTAssertEqual(viewModel.phase, .send)
        viewModel.consentTicked = true
        XCTAssertTrue(viewModel.canSend)
    }

    /// The switch went off between the card and Send: nothing goes, the
    /// person is told, and the next Send goes without consent.
    func testAnOfferThatChangedBeforeSendIsShownAgainFirst() async {
        let service = VerificationServiceMock(consentVersion: "vf1")
        let viewModel = make(service)
        await viewModel.loadConsentOffer()
        await walkToTheEnd(viewModel)
        await eventually(viewModel.phase == .send)
        viewModel.consentTicked = true
        await service.setConsentVersion(nil)

        await viewModel.send()
        XCTAssertEqual(viewModel.phase, .send)
        XCTAssertEqual(viewModel.consentNotice, L10n.t("error.consentChanged"))
        XCTAssertFalse(viewModel.consentTicked)
        XCTAssertFalse(viewModel.offersConsent, "no card now: the old wording")
        var calls = await service.recordedCalls
        XCTAssertFalse(calls.contains("submitDocument"))

        await viewModel.send()
        XCTAssertEqual(viewModel.phase, .submitted)
        calls = await service.recordedCalls
        XCTAssertTrue(calls.contains("submitDocument"))
        let consent = await service.lastConsent
        XCTAssertNil(consent)
    }

    /// `409 consent_not_offered` / `400 consent_version_unknown`: back to the
    /// card with the pictures kept, the error copy, the box unticked.
    func testARefusedConsentGoesBackToTheCardWithThePicturesKept() async {
        for code in [APIErrorCode.consentNotOffered, .consentVersionUnknown] {
            let viewModel = make(ConsentRefusingService(code: code))
            await viewModel.loadConsentOffer()
            await walkToTheEnd(viewModel)
            await eventually(viewModel.phase == .send)
            viewModel.consentTicked = true
            await viewModel.send()
            XCTAssertEqual(viewModel.phase, .send, "\(code)")
            XCTAssertEqual(viewModel.consentNotice, L10n.t("error.consentChanged"))
            XCTAssertFalse(viewModel.consentTicked)
            XCTAssertNotNil(viewModel.frontImage, "nothing has to be taken twice")
            XCTAssertNotNil(viewModel.selfie)
        }
    }

    // MARK: - Copy (§7.2, §7.5)

    func testEveryNewStringIsThereInBothLanguagesAndTheArabicCardIsArabicOnly() {
        let keys = ["document.consent.title"] + RetentionConsentCard.lineKeys + [
            "document.consent.checkbox", "document.consent.link", "document.privacy.offer",
            "document.submitting.message.kept", "auth.rejected.screened.message.kept", "error.consentChanged",
            "document.send.title", "document.send.message", "document.send.button",
            "settings.privacy.verificationPhotos.row", "settings.privacy.verificationPhotos.detail",
            "settings.privacy.verificationPhotos.button", "settings.privacy.verificationPhotos.confirm",
            "settings.privacy.verificationPhotos.done", "account.section.privacy"
        ]
        for key in keys {
            let english = L10n.withLanguage("en") { L10n.t(key) }
            let arabic = L10n.withLanguage("ar") { L10n.t(key) }
            XCTAssertNotEqual(english, key, "missing English: \(key)")
            XCTAssertNotEqual(arabic, key, "missing Arabic: \(key)")
            XCTAssertNotEqual(english, arabic, "not translated: \(key)")
            XCTAssertFalse(arabic.contains("سلة"), "the brand is صلة: \(key)")
        }
        let card = (["document.consent.title"] + RetentionConsentCard.lineKeys + ["document.consent.checkbox"])
            .map { key in L10n.withLanguage("ar") { L10n.t(key) } }
            .joined()
        XCTAssertNil(card.range(of: "[A-Za-z]", options: .regularExpression), "one language on the card: \(card)")
        XCTAssertTrue(L10n.withLanguage("ar") { L10n.t("document.consent.line2") }.contains("صلة"))
    }

    func testTheOldWordingStaysAndTheNewOneSaysKept() {
        L10n.use("en")
        XCTAssertTrue(L10n.t("document.submitting.message").contains("deleted the moment a reviewer decides"))
        XCTAssertTrue(L10n.t("document.submitting.message.kept").contains("kept encrypted in your verification file"))
        XCTAssertTrue(L10n.t("document.privacy").contains("deleted once reviewed"))
        XCTAssertTrue(L10n.t("document.privacy.offer").contains("unless you choose below"))
        XCTAssertTrue(L10n.t("auth.rejected.screened.message").contains("deleted"))
        XCTAssertTrue(L10n.t("auth.rejected.screened.message.kept").contains("stay in your verification file"))
        XCTAssertTrue(L10n.plural("account.delete.effect.permanent", 30, 30).contains("your verification photos"))
    }

    // MARK: - Settings › Privacy › Verification photos (§7.8)

    func testThePhotosRowShowsOnlyWithKeptPhotosAndWithdraws() async {
        let none = VerificationPhotosViewModel(service: VerificationServiceMock())
        await none.load()
        XCTAssertFalse(none.showsRow)

        let service = VerificationServiceMock(keptPhotos: VerificationPhotos(keptAttempts: 2, consentedAt: Date()))
        let viewModel = VerificationPhotosViewModel(service: service)
        var toasts: [SLToastMessage] = []
        viewModel.onToast = { toasts.append($0) }
        await viewModel.load()
        XCTAssertTrue(viewModel.showsRow)
        XCTAssertTrue(viewModel.detail.hasPrefix(L10n.t("settings.privacy.verificationPhotos.detail.undated")))

        viewModel.isConfirming = true
        await viewModel.withdraw()
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.contains("withdrawPhotoConsent"))
        XCTAssertEqual(calls.last, "verificationStatus", "the status is read again afterwards")
        XCTAssertFalse(viewModel.showsRow, "nothing kept: the row goes")
        XCTAssertFalse(viewModel.isConfirming)
        XCTAssertEqual(toasts.last?.text, L10n.t("settings.privacy.verificationPhotos.done"))
    }

    func testTheRowSurvivesTheSwitchGoingOff() async {
        let service = VerificationServiceMock(consentVersion: nil, keptPhotos: VerificationPhotos(keptAttempts: 1))
        let viewModel = VerificationPhotosViewModel(service: service)
        await viewModel.load()
        XCTAssertTrue(viewModel.showsRow)
    }

    // MARK: - The routes

    func testTheWithdrawalPostsToTheContractsRoute() async throws {
        let network = StubNetworkClient(responses: [#"{"withdrawn_cases":2,"photos_deleted":1}"#])
        let service = VerificationService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
        let answer = try await service.withdrawPhotoConsent()
        XCTAssertEqual(answer, PhotoConsentWithdrawal(withdrawnCases: 2, photosDeleted: 1))
        XCTAssertEqual(network.lastRequest?.path, "/verification/photos/withdraw-consent")
        XCTAssertEqual(network.lastRequest?.method, .post)
    }

    func testTheFlowReadsTheStatusRoute() async throws {
        let network = StubNetworkClient(responses: [#"{"status":"unstarted","retention_consent_version":"vf1"}"#])
        let service = VerificationService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
        let report = try await service.verificationStatus()
        XCTAssertEqual(report.retentionConsentVersion, "vf1")
        XCTAssertEqual(network.lastRequest?.path, "/verification/status")
    }
}

// MARK: - Doubles

/// Announces `vf1` and then refuses the consent on the send, as a server
/// whose switch moved between the two calls would.
private actor ConsentRefusingService: VerificationServiceProtocol {
    let code: APIErrorCode
    init(code: APIErrorCode) { self.code = code }

    private var reads = 0
    func verificationStatus() async throws -> VerificationStatusReport {
        reads += 1
        return VerificationStatusReport(status: .unstarted, retentionConsentVersion: "vf1")
    }
    func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        throw APIError.api(code: code, message: "refused", status: code == .consentNotOffered ? 409 : 400)
    }
    func setNationality(_ code: String) async throws -> VerificationStatusReport { VerificationStatusReport(status: .unstarted) }
    func setDateOfBirth(_ day: String) async throws -> VerificationStatusReport { VerificationStatusReport(status: .unstarted) }
    func startNafath(nationalID: String) async throws -> NafathStart { throw APIError.cancelled }
    func pollNafath(requestID: String) async throws -> NafathPoll { throw APIError.cancelled }
    func latestDocumentCase() async throws -> DocumentCase? { nil }
    func withdrawDocument() async throws -> VerificationStatusReport { VerificationStatusReport(status: .unstarted) }
    func appealVerification(message: String) async throws -> VerificationAppealReceipt { throw APIError.cancelled }
}
