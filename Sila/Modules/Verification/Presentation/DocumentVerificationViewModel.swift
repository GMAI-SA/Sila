import Foundation
import Observation

/// Which screen of the document flow is showing.
public enum DocumentPhase: Equatable, Sendable {
    /// Picking passport / ID card / residence permit.
    case chooseDocument
    /// Photographing the data page or the front of the card.
    case captureFront
    /// Photographing the back of a card.
    case captureBack
    /// Showing what the zone said — or that it could not be read.
    case review
    /// The selfie sequence.
    case liveness
    /// `POST /verification/document` in flight.
    case submitting
    /// Under review. The only way through is a reviewer's decision.
    case submitted
    /// This document already verified a Sila account — **not** a failure.
    /// The way forward is signing in to that account.
    case identityUsed
    /// The zone's birth date is under Sila's minimum age. Terminal.
    case underAge
    /// The zone's expiry is in the past. A different document is needed.
    case documentExpired
    /// The document is Saudi. One person, one account: this person verifies
    /// through Nafath, which is instant, and is sent there.
    case useNafath
}

/// Drives ``DocumentVerificationScreen``.
///
/// Three properties of this type are contracts:
///
/// **Nothing read off the document is typed.** Nationality, birth date and
/// expiry come from the zone the camera read and the check digits verified.
/// The person can retake the photo; they cannot edit a field.
///
/// **Nothing read off the document reaches analytics.** Events carry the
/// document type and the structured error code, never a nationality, a
/// number or a name. `DocumentVerificationTests` asserts it.
///
/// **Images exist only as this object's state.** They are captured by the
/// flow, sent once, and released when the flow ends.
@MainActor
@Observable
public final class DocumentVerificationViewModel {

    // MARK: Outputs

    public private(set) var phase: DocumentPhase = .chooseDocument
    public private(set) var documentType: DocumentType?
    public private(set) var frontImage: Data?
    public private(set) var backImage: Data?
    /// The zone as parsed from the front photo, when one was found. May be
    /// present and invalid — the review screen says so.
    public private(set) var mrz: MRZ?
    public private(set) var selfie: Data?
    public private(set) var turnFrame: Data?
    public private(set) var completedChallenges: [LivenessChallenge] = []
    public private(set) var isSubmitting = false
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
    ///   - now: Clock, injectable so "expired" is testable.
    public init(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.analytics = analytics
        self.now = now
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

    /// The document number with everything but its tail hidden — enough to
    /// recognise which document was read, not enough to copy it.
    public var maskedDocumentNumber: String? {
        guard let number = mrz?.documentNumber, !number.isEmpty else { return nil }
        let visible = number.suffix(3)
        return String(repeating: "•", count: max(0, number.count - visible.count)) + visible
    }

    /// Whether the review screen may continue to the selfie.
    public var canContinueFromReview: Bool {
        frontImage != nil && !zoneIsExpired && !zoneHasNoCountry
    }

    // MARK: Actions

    /// Chooses the document and moves to the front capture.
    public func choose(_ type: DocumentType) {
        documentType = type
        phase = .captureFront
        analytics.track(.documentVerificationStarted, properties: ["document_type": type.wireValue])
    }

    /// Accepts the front photo and whatever text the camera recognised on it.
    ///
    /// The zone is parsed with the OCR-repair pass; the strict parse is what
    /// decides validity either way. An expired document is stopped here —
    /// there is no point photographing its back.
    public func acceptFront(jpeg: Data, recognisedText: String?) {
        frontImage = jpeg
        mrz = recognisedText.flatMap { MRZParser.parseRepairing($0) }
        if zoneIsNafathOnly {
            // Decided here, before the back is photographed and before any
            // upload: the server would refuse it with `use_nafath` anyway.
            releaseImages()
            phase = .useNafath
            return
        }
        if zoneIsExpired {
            phase = .documentExpired
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

    /// The selfie sequence finished. Submits immediately: there is nothing
    /// left for the person to decide.
    public func livenessCompleted(selfie: Data, turn: Data?, challenges: [LivenessChallenge]) {
        self.selfie = selfie
        self.turnFrame = turn
        self.completedChallenges = challenges
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
            turn: turnFrame,
            mrz: zoneIsReadable ? mrz : nil,
            challenges: completedChallenges
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

    /// Back to the beginning, for a different document.
    public func startAgain() {
        documentType = nil
        releaseImages()
        mrz = nil
        completedChallenges = []
        submittedCase = nil
        underAgeMessage = ""
        phase = .chooseDocument
    }

    // MARK: - Internals

    private func releaseImages() {
        frontImage = nil
        backImage = nil
        selfie = nil
        turnFrame = nil
    }

    private func handleSubmitFailure(_ error: APIError) {
        switch error.code {
        case .alreadyVerified, .reviewPending:
            // Not failures: the account is already past this point. The
            // submitted screen's Done refreshes the session, which routes on.
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
        case .invalidMrz:
            // The server disagreed with a zone the device thought verified:
            // the photo is the thing to fix.
            toast = .error(error.userMessage)
            mrz = nil
            frontImage = nil
            backImage = nil
            phase = .captureFront
        default:
            toast = .error(error.userMessage)
            phase = .liveness
        }
    }
}
