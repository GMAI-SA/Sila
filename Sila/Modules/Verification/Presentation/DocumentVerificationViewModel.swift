import Foundation
import Observation

/// Which screen of the document flow is showing.
public enum DocumentPhase: Equatable, Sendable {
    /// The birthdate, exactly as printed on the document. Asked first.
    case birthdate
    /// Picking passport / ID card / residence permit.
    case chooseDocument
    /// Photographing the data page or the front of the card.
    case captureFront
    /// Photographing the back of a card.
    case captureBack
    /// Showing what the zone said — or that it could not be read.
    case review
    /// The live head-turn.
    case liveness
    /// Ready to send, with the consent card beside the Send button (contract
    /// v34 §7.2). Only while the server announces a consent version; without
    /// one the flow sends straight after the head-turn, as before.
    case send
    /// `POST /verification/document` in flight: the upload's progress, then
    /// the server checking what arrived.
    case submitting
    /// The pictures did not reach the server — no connection, a timeout, a
    /// server error. Everything is kept; "Try again" sends the same again.
    case sendFailed
    /// Under review. The only way through is a reviewer's decision.
    case submitted
    /// This document already verified a Sila account — **not** a failure.
    /// The way forward is signing in to that account.
    case identityUsed
    /// Under Sila's minimum age. Terminal.
    case underAge
    /// The zone's expiry is in the past. A different document is needed.
    case documentExpired
    /// The document is Saudi. One person, one account: this person verifies
    /// through Nafath, which is instant, and is sent there.
    case useNafath
    /// The zone's birthdate is not the one the person declared. Caught on
    /// the device before anything is uploaded — on the server this closes
    /// the account — so the person can correct the claim or retake.
    case dateOfBirthMismatch
}

/// One side of a document.
public enum DocumentSide: String, Equatable, Sendable {
    case front, back
}

/// Why a photo or file chosen for a side could not be used, in words.
public enum DocumentImportProblem: Equatable, Sendable {
    /// Not a picture or a PDF the phone can open.
    case unreadableFile
    /// Photos handed back nothing — an iCloud original that would not
    /// download, usually.
    case notDownloaded

    /// The sentence the capture step shows.
    public var message: String {
        switch self {
        case .unreadableFile: return L10n.t("document.upload.error.unreadableFile")
        case .notDownloaded: return L10n.t("document.upload.error.notDownloaded")
        }
    }
}

/// Where a submission is while ``DocumentPhase/submitting`` shows.
public enum DocumentSubmissionStage: Equatable, Sendable {
    /// The pictures are going up; the fraction of bytes sent, `0…1`.
    case uploading(Double)
    /// Every byte arrived; the server is checking them and has not answered.
    case checking
}

/// Drives ``DocumentVerificationScreen``.
///
/// Four properties of this type are contracts:
///
/// **The birthdate is the one thing the person types, and it is a claim.**
/// It is asked first, sent to the server, and tested against the document's
/// zone here and on the server. A document that says otherwise stops the
/// flow before an upload; a child's answer stops it before a document.
///
/// **Nothing read off the document is typed.** Nationality, birth date and
/// expiry come from the zone the camera read and the check digits verified.
/// The person can retake the photo; they cannot edit a field.
///
/// **Nothing read off the document reaches analytics.** Events carry the
/// document type and the structured error code, never a nationality, a
/// number, a name or a birthdate. `DocumentVerificationTests` asserts it.
///
/// **Images exist only as this object's state.** They are captured by the
/// flow, sent once, and released when the flow ends.
@MainActor
@Observable
public final class DocumentVerificationViewModel {

    // MARK: Outputs

    public private(set) var phase: DocumentPhase
    public private(set) var documentType: DocumentType?
    public private(set) var frontImage: Data?
    public private(set) var backImage: Data?
    /// The zone as parsed from the front photo, when one was found. May be
    /// present and invalid — the review screen says so.
    public private(set) var mrz: MRZ?
    public private(set) var selfie: Data?
    public private(set) var turnFrame: Data?
    public private(set) var completedChallenges: [LivenessChallenge] = []
    /// The live head-turn, once it finished.
    public private(set) var sweep: LivenessSweep?
    public private(set) var isSubmitting = false
    public private(set) var isSavingBirthdate = false
    /// The birthdate on file, as `YYYY-MM-DD`, once declared.
    public private(set) var declaredDateOfBirth: String?
    /// What the picker shows. Defaults to a plausible adult so the wheel does
    /// not open on today's date and make somebody scroll thirty years.
    public var birthdateSelection: Date
    /// The case the server opened, once ``phase`` is ``DocumentPhase/submitted``.
    public private(set) var submittedCase: DocumentCase?
    /// The server's sentence for the under-age refusal.
    public private(set) var underAgeMessage = ""
    /// Banner message.
    public var toast: SLToastMessage?
    /// Where the front and back images came from.
    public private(set) var frontSource: DocumentSource = .camera
    public private(set) var backSource: DocumentSource = .camera
    /// The side being read on the phone right now — a chosen photo coming
    /// down from iCloud, a PDF or HEIC being turned into a picture, the zone
    /// being read off the front. The step says "Reading your document…"
    /// until it is done, so a pick never looks like a tap that did nothing.
    public private(set) var reading: DocumentSide?
    /// The picture being read, once there is one to show beside the words.
    public private(set) var readingPreview: Data?
    /// Why a chosen photo or file was not accepted, on the capture screen.
    public private(set) var importProblem: DocumentImportProblem?
    /// A plain sentence at the top of the step the person was sent back to,
    /// and why: the server could not verify the zone, the face check has to
    /// be done again. Gone once they move on.
    public private(set) var stepNotice: String?
    /// How far the submission has got, while ``phase`` is
    /// ``DocumentPhase/submitting``.
    public private(set) var submissionStage: DocumentSubmissionStage = .uploading(0)
    /// Why the pictures did not go, on ``DocumentPhase/sendFailed``.
    public private(set) var sendFailure: String?
    /// The submission can still be taken back: it was accepted by this flow,
    /// or the server said one is already waiting (contract v25).
    public private(set) var canWithdraw = false
    /// The in-place "are you sure" before a withdrawal.
    public var isConfirmingWithdrawal = false
    public private(set) var isWithdrawing = false

    // MARK: The consent card (contract v34)

    /// The consent version the server announces, read when the flow opens and
    /// again just before sending; `nil` while it keeps nothing past the
    /// decision — then there is no card and the old wording stays.
    public private(set) var consentVersion: String?
    /// The box on the card. Starts unticked, every time; never remembered
    /// between submissions, and cleared by every retake.
    public var consentTicked = false
    /// Said on the send step when the server's offer changed under the
    /// person ("Something changed on our side…").
    public private(set) var consentNotice: String?
    /// The submission in flight, or the one that went, carried the tick —
    /// the "kept encrypted in your verification file" wording.
    public private(set) var sentWithConsent = false

    /// The card is on screen: there is something to consent to.
    public var offersConsent: Bool { consentVersion != nil }

    /// Send is always enabled (contract v34 §7.2, *Deviation 3*): the tick is
    /// optional, and an unticked submission simply keeps nothing.
    public var canSend: Bool { !isSubmitting }
    /// Reads the zone off a JPEG. Injectable so tests need no Vision.
    var zoneReader: @Sendable (Data) async -> String? = { jpeg in
        DocumentTextReader.zone(from: await DocumentTextReader.lines(in: jpeg))
    }
    /// Turns a chosen photo or file into the camera's JPEG, off the main
    /// thread: a PDF or a 48-megapixel HEIC takes long enough to freeze the
    /// screen otherwise. Injectable so a test can hold it open.
    var converter: @Sendable (Data, Bool?) async -> Data? = { data, isPDF in
        await Task.detached(priority: .userInitiated) {
            DocumentImport.jpeg(from: data, isPDF: isPDF)
        }.value
    }

    /// Something is being read: the pickers wait.
    public var isImporting: Bool { reading != nil }

    /// Why a chosen photo or file was not accepted, in words.
    public var importError: String? { importProblem?.message }

    /// The side the capture step is photographing, if it is one.
    public var captureSide: DocumentSide? {
        switch phase {
        case .captureFront: return .front
        case .captureBack: return .back
        default: return nil
        }
    }

    /// The source sent with the submission: a chosen image on either side
    /// counts, the front first.
    public var documentSource: DocumentSource {
        frontSource != .camera ? frontSource : backSource
    }

    private let service: VerificationServiceProtocol
    private let analytics: AnalyticsClient
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - service: Verification backend.
    ///   - analytics: Event sink. Nothing tracked here carries document data.
    ///   - declaredDateOfBirth: The claim already on file, from the wall's
    ///     status report. When present the birthdate step is skipped.
    ///   - documentType: The document to photograph again, when the pre-screen
    ///     turned the last one away: the flow opens on its camera. Only with a
    ///     birthdate on file — the claim still comes first.
    ///   - now: Clock, injectable so "expired" is testable.
    public init(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient,
        declaredDateOfBirth: String? = nil,
        nafathAvailable: Bool = false,
        documentType: DocumentType? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.nafathAvailable = nafathAvailable
        let declared = ISODay.normalised(declaredDateOfBirth)
        let calendar = Calendar(identifier: .gregorian)
        self.service = service
        self.analytics = analytics
        self.now = now
        self.declaredDateOfBirth = declared
        if declared != nil, let documentType {
            self.documentType = documentType
            self.phase = .captureFront
        } else {
            self.phase = declared == nil ? .birthdate : .chooseDocument
        }
        self.birthdateSelection = ISODay.date(declared ?? "")
            ?? calendar.date(byAdding: .year, value: -25, to: now()) ?? now()
    }

    // MARK: Derived state

    /// `true` when a zone was found and every check digit verified.
    public var zoneIsReadable: Bool { mrz?.isValid == true }

    /// `true` when the zone is fine but names no country — stateless or a UN
    /// document. The badge cannot be produced from it; the person is told.
    public var zoneHasNoCountry: Bool { zoneIsReadable && mrz?.nationality == nil }

    /// Nationalities and issuers whose people verify through Nafath, never
    /// here. Mirrors the server's `NAFATH_ONLY`.
    public static let nafathOnly: Set<String> = ["SA"]

    /// Whether Nafath is live for this account. While it is "coming soon",
    /// Saudi documents are welcome here like any other.
    public let nafathAvailable: Bool

    /// `true` when the zone belongs to somebody Nafath already knows — a
    /// Saudi nationality, or a Saudi-issued document such as an Iqama — and
    /// Nafath is actually open to send them to.
    public var zoneIsNafathOnly: Bool {
        guard nafathAvailable, zoneIsReadable, let mrz else { return false }
        return Self.nafathOnly.contains(mrz.nationality ?? "") || Self.nafathOnly.contains(mrz.issuingCountry ?? "")
    }

    /// `true` when the zone's expiry date is in the past.
    public var zoneIsExpired: Bool {
        guard let expiry = mrz?.expiryDate, zoneIsReadable else { return false }
        return expiry < now()
    }

    /// `true` when the zone's birthdate is not the one the person declared.
    /// Certain, because the zone's check digits verified; caught here so the
    /// server never has to close the account over a slip on the wheel.
    public var zoneContradictsBirthdate: Bool {
        guard zoneIsReadable, let born = mrz?.dateOfBirth, let declaredDateOfBirth else { return false }
        return ISODay.string(born) != declaredDateOfBirth
    }

    /// The document number with everything but its tail hidden — enough to
    /// recognise which document was read, not enough to copy it.
    public var maskedDocumentNumber: String? {
        guard let number = mrz?.documentNumber, !number.isEmpty else { return nil }
        let visible = number.suffix(3)
        return String(repeating: "•", count: max(0, number.count - visible.count)) + visible
    }

    /// Whether the review screen may continue to the face.
    public var canContinueFromReview: Bool {
        frontImage != nil && !zoneIsExpired && !zoneHasNoCountry && !zoneContradictsBirthdate
    }

    /// Whether the birthdate on the wheel can be sent: in the past, and not
    /// absurdly so. The server's rule; repeated here to save a round trip.
    public var canSubmitBirthdate: Bool {
        let calendar = Calendar(identifier: .gregorian)
        guard birthdateSelection <= now() else { return false }
        let years = calendar.dateComponents([.year], from: birthdateSelection, to: now()).year ?? 0
        return years <= 120 && !isSavingBirthdate
    }

    /// Where the person is, for the progress bar: `(step, of)`. `nil` on the
    /// terminal screens, which are not steps.
    public var progress: (index: Int, count: Int)? {
        let hasBack = documentType?.hasBack ?? true
        let count = hasBack ? 7 : 6
        switch phase {
        case .birthdate: return (1, count)
        case .chooseDocument: return (2, count)
        case .captureFront: return (3, count)
        case .captureBack: return (4, count)
        case .review: return (hasBack ? 5 : 4, count)
        case .liveness: return (hasBack ? 6 : 5, count)
        case .send, .submitting, .sendFailed, .submitted: return (count, count)
        case .identityUsed, .underAge, .documentExpired, .useNafath, .dateOfBirthMismatch: return nil
        }
    }

    // MARK: Actions

    /// Sends the birthdate on the wheel. A child's answer ends here.
    public func submitBirthdate() async {
        guard canSubmitBirthdate else { return }
        isSavingBirthdate = true
        defer { isSavingBirthdate = false }
        let day = ISODay.string(birthdateSelection)
        do {
            let report = try await service.setDateOfBirth(day)
            declaredDateOfBirth = report.dateOfBirth ?? day
            analytics.track(.birthdateDeclared)
            phase = .chooseDocument
        } catch let error as APIError {
            switch error.code {
            case .underMinimumAge:
                underAgeMessage = error.userMessage
                phase = .underAge
            case .alreadyVerified:
                phase = .submitted
            default:
                toast = .error(error.userMessage)
            }
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
        }
    }

    /// Back to the wheel, from the mismatch screen: the claim is changeable
    /// until it has been proved, and a slip on a wheel is not a lie.
    public func changeBirthdate() {
        frontImage = nil
        backImage = nil
        mrz = nil
        stepNotice = nil
        phase = .birthdate
    }

    /// Chooses the document and moves to the front capture.
    public func choose(_ type: DocumentType) {
        documentType = type
        phase = .captureFront
        analytics.track(.documentVerificationStarted, properties: ["document_type": type.wireValue])
    }

    /// Back from the first camera to the document choice — a retake opens on
    /// the document used last, and that may have been the mistake.
    public func changeDocument() {
        guard phase == .captureFront else { return }
        documentType = nil
        frontSource = .camera
        backSource = .camera
        importProblem = nil
        stepNotice = nil
        releaseImages()
        mrz = nil
        phase = .chooseDocument
    }

    /// Accepts the front photo and whatever text the camera recognised on it.
    ///
    /// The zone is parsed with the OCR-repair pass; the strict parse is what
    /// decides validity either way. An expired document, a Saudi one, and a
    /// zone that contradicts the declared birthdate are all stopped here —
    /// there is no point photographing the back. A back already taken (the
    /// front was retaken from the review) is kept: the review comes next.
    public func acceptFront(jpeg: Data, recognisedText: String?) {
        frontImage = jpeg
        importProblem = nil
        stepNotice = nil
        mrz = recognisedText.flatMap { MRZParser.parseRepairing($0) }
        if zoneIsNafathOnly {
            releaseImages()
            phase = .useNafath
            return
        }
        if zoneIsExpired {
            phase = .documentExpired
            return
        }
        if zoneContradictsBirthdate {
            phase = .dateOfBirthMismatch
            return
        }
        phase = documentType?.hasBack == true && backImage == nil ? .captureBack : .review
    }

    /// Accepts the back photo.
    public func acceptBack(jpeg: Data) {
        backImage = jpeg
        importProblem = nil
        phase = .review
    }

    /// The camera's "Use this photo": the front is read for its zone first,
    /// under "Reading your document…", and both sides then move on exactly
    /// as an upload does.
    /// - Parameter knownZone: The zone, when the caller already has it (the
    ///   simulator's sample photo). Read off the picture otherwise.
    public func useCapturedPhoto(_ jpeg: Data, knownZone: String? = nil) async {
        guard let side = captureSide, reading == nil else { return }
        importProblem = nil
        guard side == .front else {
            backSource = .camera
            acceptBack(jpeg: jpeg)
            return
        }
        reading = .front
        readingPreview = jpeg
        defer { finishReading() }
        let text: String?
        if let knownZone { text = knownZone } else { text = await zoneReader(jpeg) }
        guard phase == .captureFront else { return }
        frontSource = .camera
        acceptFront(jpeg: jpeg, recognisedText: text)
    }

    // MARK: Uploading instead of photographing

    /// A photo or file was chosen for the current side. It is turned into
    /// the camera's JPEG and — on the front — read for the zone exactly as a
    /// photo would be, so expiry, nationality and birthdate are checked the
    /// same way, through the same `acceptFront`. A zoneless front goes to a
    /// reviewer exactly as a zoneless photo does, passports included: the
    /// review step says the zone could not be read and offers another try,
    /// as it does for the camera. Refusing an upload the camera would have
    /// let through made the passport camera-only whenever the reader missed.
    public func importDocument(_ data: Data, isPDF: Bool? = nil, source: DocumentSource) async {
        await importDocument(source: source) { (data, isPDF) }
    }

    /// ``importDocument(_:isPDF:source:)`` for a pick whose bytes are still
    /// on their way — a Photos item coming down from iCloud. "Reading your
    /// document…" shows from the moment of the pick, not from the moment the
    /// bytes arrive; `load` answering `nil` is said as such.
    public func importDocument(source: DocumentSource, load: @escaping () async -> (Data, Bool?)?) async {
        guard let side = captureSide, reading == nil else { return }
        let startedOn = phase
        reading = side
        readingPreview = nil
        importProblem = nil
        defer { finishReading() }
        guard let (data, isPDF) = await load() else {
            if phase == startedOn { importProblem = .notDownloaded }
            return
        }
        let converted = await converter(data, isPDF)
        // Cancelled, or the document changed, while this was being read.
        guard phase == startedOn else { return }
        guard let jpeg = converted else {
            importProblem = .unreadableFile
            return
        }
        readingPreview = jpeg
        analytics.track(.documentUploaded, properties: ["source": source.rawValue, "step": side.rawValue])
        if side == .back {
            backSource = source
            acceptBack(jpeg: jpeg)
            return
        }
        let text = await zoneReader(jpeg)
        guard phase == startedOn else { return }
        frontSource = source
        acceptFront(jpeg: jpeg, recognisedText: text)
    }

    /// The picker or the file browser handed back nothing readable — an
    /// iCloud photo that would not download, a file that would not open.
    /// Said on the capture screen rather than swallowed.
    public func importFailed(_ problem: DocumentImportProblem = .unreadableFile) {
        guard captureSide != nil else { return }
        importProblem = problem
    }

    /// The camera took over again on this side.
    public func clearImportError() {
        importProblem = nil
    }

    /// Discards the front photo (and the zone read from it) for another try.
    /// The back, when there is one, stays: it was not the problem.
    public func retakeFront() {
        consentTicked = false
        frontSource = .camera
        frontImage = nil
        mrz = nil
        importProblem = nil
        stepNotice = nil
        phase = .captureFront
    }

    /// Discards the back photo for another try, keeping the front.
    public func retakeBack() {
        guard documentType?.hasBack == true, frontImage != nil else { return }
        consentTicked = false
        backSource = .camera
        backImage = nil
        importProblem = nil
        stepNotice = nil
        phase = .captureBack
    }

    /// The person confirmed the details read off the document.
    public func confirmDetails() {
        guard canContinueFromReview else { return }
        phase = .liveness
    }

    /// The live head-turn finished. Submits immediately: there is nothing
    /// left for the person to decide.
    public func sweepCompleted(_ sweep: LivenessSweep) {
        stepNotice = nil
        self.sweep = sweep
        self.selfie = sweep.straightFrame
        analytics.track(.livenessCompleted, properties: ["sectors": String(sweep.frames.count)])
        Task { await proceedAfterLiveness() }
    }

    /// The legacy three-pose sequence finished. Kept for a client without a
    /// face tracker; submits the same way.
    public func livenessCompleted(selfie: Data, turn: Data?, challenges: [LivenessChallenge]) {
        stepNotice = nil
        self.selfie = selfie
        self.turnFrame = turn
        self.completedChallenges = challenges
        self.sweep = nil
        analytics.track(.livenessCompleted, properties: ["challenges": String(challenges.count)])
        Task { await proceedAfterLiveness() }
    }

    /// Readies the device's App Attest key while the person photographs
    /// the document, so the submit only has to sign. Never holds the flow up.
    public func prepareDevice() async {
        await service.prepareDeviceAttestation()
    }

    /// Reads whether the server offers to keep the photographs (contract v34
    /// §2.1). Called when the flow opens; a failure leaves what was known.
    public func loadConsentOffer() async {
        guard let report = try? await service.verificationStatus() else { return }
        applyConsentOffer(report)
    }

    private func applyConsentOffer(_ report: VerificationStatusReport) {
        consentVersion = report.retentionConsentVersion
        if consentVersion == nil { consentTicked = false }
    }

    /// After the head-turn: the send step with the card while the server
    /// announces a version, otherwise straight to the upload, as before.
    public func proceedAfterLiveness() async {
        await loadConsentOffer()
        if offersConsent {
            consentTicked = false
            consentNotice = nil
            phase = .send
        } else {
            await submit()
        }
    }

    /// Send, from the card's step. Reads the offer once more first: when it
    /// changed since the card was drawn, the card is drawn again, unticked,
    /// and nothing goes until the person sends again — what they agreed to
    /// is exactly what the server records, or nothing is.
    public func send() async {
        guard phase == .send, canSend else { return }
        let shown = consentVersion
        if let report = try? await service.verificationStatus() {
            applyConsentOffer(report)
            if consentVersion != shown {
                consentTicked = false
                consentNotice = L10n.t("error.consentChanged")
                return
            }
        }
        consentNotice = nil
        await submit()
    }

    /// The consent parts to send: only with the tick, and only the version
    /// the server announced, in the language the card was drawn in.
    var consentToSend: RetentionConsent? {
        guard consentTicked, let consentVersion else { return nil }
        return RetentionConsent(version: consentVersion, locale: L10n.languageCode)
    }

    /// Sends everything to `/verification/document`: "Uploading… 42%" as
    /// the bytes go, "Checking your documents…" once they have all arrived,
    /// and then the server's answer — never back to a screen with no word.
    public func submit() async {
        guard let documentType, let frontImage, let selfie, !isSubmitting else { return }
        isSubmitting = true
        sendFailure = nil
        submissionStage = .uploading(0)
        phase = .submitting
        defer { isSubmitting = false }

        let submission = DocumentSubmission(
            documentType: documentType,
            front: frontImage,
            back: backImage,
            selfie: selfie,
            turn: sweep == nil ? turnFrame : nil,
            mrz: zoneIsReadable ? mrz : nil,
            challenges: sweep == nil ? completedChallenges : [],
            sweep: sweep
        )
        var sent = submission
        sent.source = documentSource
        sent.consent = consentToSend
        sentWithConsent = sent.consent != nil

        do {
            // Held only as long as the request is.
            submittedCase = try await service.submitDocument(sent) { fraction in
                Task { @MainActor in self.uploadProgressed(fraction) }
            }
            releaseImages()
            canWithdraw = submittedCase?.status == .submitted
            phase = .submitted
        } catch let error as APIError {
            handleSubmitFailure(error)
        } catch {
            sendFailure = L10n.t("common.somethingWentWrong")
            phase = .sendFailed
        }
    }

    /// The share of the pictures that has gone. All of it means the server
    /// is checking them: the words change to say so.
    func uploadProgressed(_ fraction: Double) {
        guard phase == .submitting else { return }
        if fraction >= 1 {
            submissionStage = .checking
        } else if case let .uploading(sent) = submissionStage, fraction > sent {
            submissionStage = .uploading(fraction)
        }
    }

    /// "Try again" after the pictures did not go: the same pictures and the
    /// same face, sent again. Nothing has to be taken twice.
    ///
    /// The offer is read again first, as Send does (contract v34 §7.1): when
    /// it changed since the card was drawn, the send step is drawn again
    /// (with the card, unticked, or without it), with the notice, and
    /// nothing goes until the person sends from it. A read that fails (still offline) leaves what was shown.
    public func retrySend() async {
        guard phase == .sendFailed else { return }
        let shown = consentVersion
        if let report = try? await service.verificationStatus() {
            applyConsentOffer(report)
            if consentVersion != shown {
                consentTicked = false
                sentWithConsent = false
                consentNotice = L10n.t("error.consentChanged")
                phase = .send
                return
            }
        }
        await submit()
    }

    /// Back to the document choice, for a different document. The birthdate
    /// on file stays: it was the person's, not the document's.
    public func startAgain() {
        consentTicked = false
        consentNotice = nil
        documentType = nil
        releaseImages()
        mrz = nil
        completedChallenges = []
        sweep = nil
        submittedCase = nil
        underAgeMessage = ""
        importProblem = nil
        stepNotice = nil
        sendFailure = nil
        phase = declaredDateOfBirth == nil ? .birthdate : .chooseDocument
    }

    /// Takes the submission back so a corrected one can be sent (contract
    /// v25). Asked from the under-review screen, after the in-place
    /// confirmation; the caller goes back to the method choice on
    /// ``WithdrawalOutcome/withdrawn(_:)``.
    public func withdraw() async -> WithdrawalOutcome {
        guard canWithdraw, !isWithdrawing else { return .failed }
        isWithdrawing = true
        defer { isWithdrawing = false }
        do {
            let report = try await service.withdrawDocument()
            canWithdraw = false
            isConfirmingWithdrawal = false
            submittedCase = nil
            return .withdrawn(report)
        } catch let error as APIError where error.code == .nothingToWithdraw {
            // Decided first — the pre-screen answers within a minute — or
            // already taken back. Where it stands is the wall's to show.
            canWithdraw = false
            isConfirmingWithdrawal = false
            return .nothingWaiting
        } catch let error as APIError {
            if !error.isCancellation { toast = .error(error.userMessage) }
            return .failed
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
            return .failed
        }
    }

    // MARK: - Internals

    private func releaseImages() {
        frontImage = nil
        backImage = nil
        selfie = nil
        turnFrame = nil
        sweep = nil
        readingPreview = nil
    }

    private func finishReading() {
        reading = nil
        readingPreview = nil
    }

    private func handleSubmitFailure(_ error: APIError) {
        switch error.code {
        case .alreadyVerified:
            releaseImages()
            phase = .submitted
        case .reviewPending:
            // One is already waiting — sent from another device, say: this
            // screen is the place to take that one back and start again.
            releaseImages()
            canWithdraw = true
            phase = .submitted
        case .identityAlreadyUsed:
            releaseImages()
            phase = .identityUsed
        case .underMinimumAge:
            releaseImages()
            underAgeMessage = error.userMessage
            phase = .underAge
        case .documentExpired:
            phase = .documentExpired
        case .useNafath:
            releaseImages()
            phase = .useNafath
        case .dateOfBirthMismatch:
            // The server closed the account over it; the screen says so and
            // offers the appeal path the wall carries.
            releaseImages()
            phase = .dateOfBirthMismatch
        case .dateOfBirthRequired:
            releaseImages()
            phase = .birthdate
        case .invalidMrz:
            // Said at the top of the camera it sends them back to, not in a
            // banner that is gone before the camera has started.
            stepNotice = error.userMessage
            consentTicked = false
            mrz = nil
            frontImage = nil
            backImage = nil
            phase = .captureFront
        case .consentVersionUnknown, .consentNotOffered:
            // The offer changed between the read and the send: read it
            // again, draw the card again (or none), unticked. The pictures
            // stay; nothing has to be taken twice.
            consentTicked = false
            sentWithConsent = false
            consentNotice = error.userMessage
            phase = .send
            Task { await loadConsentOffer() }
        case .livenessMismatch, .tooManyFrames:
            stepNotice = error.userMessage
            consentTicked = false
            sweep = nil
            selfie = nil
            phase = .liveness
        default:
            // No connection, a timeout, the server down: nothing about the
            // pictures was wrong, so they are kept and sent again on a tap.
            sendFailure = error.isCancellation ? L10n.t("common.somethingWentWrong") : error.userMessage
            phase = .sendFailed
        }
    }
}
