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
    /// `POST /verification/document` in flight.
    case submitting
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

    private let service: VerificationServiceProtocol
    private let analytics: AnalyticsClient
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - service: Verification backend.
    ///   - analytics: Event sink. Nothing tracked here carries document data.
    ///   - declaredDateOfBirth: The claim already on file, from the wall's
    ///     status report. When present the birthdate step is skipped.
    ///   - now: Clock, injectable so "expired" is testable.
    public init(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient,
        declaredDateOfBirth: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let declared = ISODay.normalised(declaredDateOfBirth)
        let calendar = Calendar(identifier: .gregorian)
        self.service = service
        self.analytics = analytics
        self.now = now
        self.declaredDateOfBirth = declared
        self.phase = declared == nil ? .birthdate : .chooseDocument
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

    /// `true` when the zone belongs to somebody Nafath already knows — a
    /// Saudi nationality, or a Saudi-issued document such as an Iqama.
    public var zoneIsNafathOnly: Bool {
        guard zoneIsReadable, let mrz else { return false }
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
        case .submitting, .submitted: return (count, count)
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
        phase = .birthdate
    }

    /// Chooses the document and moves to the front capture.
    public func choose(_ type: DocumentType) {
        documentType = type
        phase = .captureFront
        analytics.track(.documentVerificationStarted, properties: ["document_type": type.wireValue])
    }

    /// Accepts the front photo and whatever text the camera recognised on it.
    ///
    /// The zone is parsed with the OCR-repair pass; the strict parse is what
    /// decides validity either way. An expired document, a Saudi one, and a
    /// zone that contradicts the declared birthdate are all stopped here —
    /// there is no point photographing the back.
    public func acceptFront(jpeg: Data, recognisedText: String?) {
        frontImage = jpeg
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
        phase = documentType?.hasBack == true ? .captureBack : .review
    }

    /// Accepts the back photo.
    public func acceptBack(jpeg: Data) {
        backImage = jpeg
        phase = .review
    }

    /// Discards the front photo (and the zone read from it) for another try.
    public func retakeFront() {
        frontImage = nil
        backImage = nil
        mrz = nil
        phase = .captureFront
    }

    /// The person confirmed the details read off the document.
    public func confirmDetails() {
        guard canContinueFromReview else { return }
        phase = .liveness
    }

    /// The live head-turn finished. Submits immediately: there is nothing
    /// left for the person to decide.
    public func sweepCompleted(_ sweep: LivenessSweep) {
        self.sweep = sweep
        self.selfie = sweep.straightFrame
        analytics.track(.livenessCompleted, properties: ["sectors": String(sweep.frames.count)])
        Task { await submit() }
    }

    /// The legacy three-pose sequence finished. Kept for a client without a
    /// face tracker; submits the same way.
    public func livenessCompleted(selfie: Data, turn: Data?, challenges: [LivenessChallenge]) {
        self.selfie = selfie
        self.turnFrame = turn
        self.completedChallenges = challenges
        self.sweep = nil
        analytics.track(.livenessCompleted, properties: ["challenges": String(challenges.count)])
        Task { await submit() }
    }

    /// Sends everything to `/verification/document`.
    public func submit() async {
        guard let documentType, let frontImage, let selfie, !isSubmitting else { return }
        isSubmitting = true
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

        do {
            submittedCase = try await service.submitDocument(submission)
            releaseImages()
            phase = .submitted
        } catch let error as APIError {
            handleSubmitFailure(error)
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
            phase = .liveness
        }
    }

    /// Back to the document choice, for a different document. The birthdate
    /// on file stays: it was the person's, not the document's.
    public func startAgain() {
        documentType = nil
        releaseImages()
        mrz = nil
        completedChallenges = []
        sweep = nil
        submittedCase = nil
        underAgeMessage = ""
        phase = declaredDateOfBirth == nil ? .birthdate : .chooseDocument
    }

    // MARK: - Internals

    private func releaseImages() {
        frontImage = nil
        backImage = nil
        selfie = nil
        turnFrame = nil
        sweep = nil
    }

    private func handleSubmitFailure(_ error: APIError) {
        switch error.code {
        case .alreadyVerified, .reviewPending:
            releaseImages()
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
            toast = .error(error.userMessage)
            mrz = nil
            frontImage = nil
            backImage = nil
            phase = .captureFront
        case .livenessMismatch, .tooManyFrames:
            toast = .error(error.userMessage)
            sweep = nil
            selfie = nil
            phase = .liveness
        default:
            toast = .error(error.userMessage)
            phase = .liveness
        }
    }
}
