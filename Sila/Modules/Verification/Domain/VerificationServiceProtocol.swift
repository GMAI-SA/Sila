import Foundation

/// Everything the Verification module can ask the backend to do.
///
/// The seam ``NafathVerificationViewModel`` and
/// ``DocumentVerificationViewModel`` depend on; the real implementation
/// (``VerificationService``) and the scripted one (``VerificationServiceMock``)
/// are interchangeable.
///
/// Two routes, one contract. The national ID passed to
/// ``startNafath(nationalID:)`` and the zone inside a ``DocumentSubmission``
/// are sent once and discarded. Implementations must not store them, log
/// them, or attach them to an analytics event — the number is somebody's
/// government identity, and this protocol's contract is that it exists exactly
/// as long as the request does.
public protocol VerificationServiceProtocol: Sendable {

    // MARK: The claim

    /// Records what the person says their nationality is — the first step
    /// of verification, and the claim every route then tests.
    ///
    /// - Throws: ``APIError`` with ``APIErrorCode/invalidCountry`` for a code
    ///   that is not a country, ``APIErrorCode/alreadyVerified`` once the
    ///   badge exists.
    func setNationality(_ code: String) async throws -> VerificationStatusReport

    /// Records what the person says their birthdate is — asked on the
    /// document route, tested against the document exactly as the nationality
    /// is. A child's answer closes the account here, before any document.
    ///
    /// - Parameter day: `YYYY-MM-DD`, as printed on the document.
    /// - Throws: ``APIError`` with ``APIErrorCode/invalidDateOfBirth``,
    ///   ``APIErrorCode/alreadyVerified``, or ``APIErrorCode/underMinimumAge``
    ///   (terminal, the server's words).
    func setDateOfBirth(_ day: String) async throws -> VerificationStatusReport

    // MARK: Nafath

    /// Opens a Nafath request for `nationalID`.
    ///
    /// - Returns: The request id to poll, the two-digit number the person must
    ///   tap in the Nafath app, and the request's expiry.
    /// - Throws: ``APIError`` with:
    ///   - ``APIErrorCode/alreadyVerified`` — the account is already through;
    ///   - ``APIErrorCode/invalidNationalId`` — the server refused the number;
    ///   - ``APIErrorCode/identityAlreadyUsed`` — this identity belongs to a
    ///     different Sila account;
    ///   - ``APIErrorCode/verificationUnavailable`` — Nafath is down.
    func startNafath(nationalID: String) async throws -> NafathStart

    /// Reads where the request stands. Called every few seconds until a
    /// terminal status or the request's expiry.
    ///
    /// - Throws: ``APIError`` with ``APIErrorCode/underMinimumAge`` when the
    ///   verified identity is under Sila's minimum age — terminal, and the
    ///   server's message is what the user reads.
    func pollNafath(requestID: String) async throws -> NafathPoll

    // MARK: Document + selfie

    /// Uploads a document and selfie sequence for a reviewer.
    ///
    /// - Returns: The case, in ``DocumentCaseStatus/submitted``; the account
    ///   is now `pending_review`.
    /// - Throws: ``APIError`` with:
    ///   - ``APIErrorCode/alreadyVerified``, ``APIErrorCode/reviewPending``;
    ///   - ``APIErrorCode/invalidMrz`` — a check digit failed server-side;
    ///   - ``APIErrorCode/documentExpired``;
    ///   - ``APIErrorCode/identityAlreadyUsed`` — this document already
    ///     verified another account;
    ///   - ``APIErrorCode/underMinimumAge`` — terminal, server's words.
    func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase

    /// ``submitDocument(_:)``, telling `progress` how much of the upload has
    /// gone, `0…1`, so the person watches it go rather than a spinner. `1`
    /// means every byte has arrived and the server is checking them.
    func submitDocument(
        _ submission: DocumentSubmission,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DocumentCase

    /// Readies this device's App Attest key before the person reaches the
    /// submit (contract v32), so the submission only has to sign. Never
    /// throws and never holds anything up: a device that cannot attest
    /// submits without, and a person reviews the case.
    func prepareDeviceAttestation() async

    /// The caller's most recent document case, or `nil` when there has never
    /// been one.
    func latestDocumentCase() async throws -> DocumentCase?

    /// Takes back the submission still waiting for review, so a corrected
    /// one can be sent (contract v25, `POST /verification/document/withdraw`).
    ///
    /// Offered exactly while ``VerificationStatusReport/canWithdraw`` is true.
    /// - Returns: The status afterwards — `unstarted`, nothing to withdraw;
    ///   the wall offers the methods again.
    /// - Throws: ``APIError`` with ``APIErrorCode/nothingToWithdraw`` (409)
    ///   when nothing is waiting: it was already withdrawn, or decided — by a
    ///   moderator or the pre-screen — before this arrived.
    func withdrawDocument() async throws -> VerificationStatusReport

    // MARK: Contesting a decision

    /// Appeals the decision that closed the account, `POST /verification/appeal`.
    ///
    /// One per decision. A rejection, a refusal on the facts and a withdrawn
    /// badge are all appealable; a moderator decides the appeal on the
    /// dashboard, never by mail.
    /// - Throws: ``APIError`` with ``APIErrorCode/alreadyAppealed`` (409) when
    ///   one is already on file — the state it describes, not a failure — and
    ///   `nothing_to_appeal` (400) on an account that is not closed.
    func appealVerification(message: String) async throws -> VerificationAppealReceipt

    // MARK: Verification photos (contract v34)

    /// `GET /verification/status`, read by the document flow when it opens
    /// and again just before it sends: whether the consent card is offered
    /// (``VerificationStatusReport/retentionConsentVersion``).
    func verificationStatus() async throws -> VerificationStatusReport

    /// Withdraws the consent to keep verification photographs and deletes the
    /// kept ones, `POST /verification/photos/withdraw-consent`. Idempotent:
    /// nothing kept answers `0, 0`.
    /// - Throws: ``APIError`` with ``APIErrorCode/rateLimited`` past 5 an hour.
    func withdrawPhotoConsent() async throws -> PhotoConsentWithdrawal
}

extension VerificationServiceProtocol {
    /// A service that cannot read the status offers no consent card: the
    /// flow behaves exactly as before v34.
    public func verificationStatus() async throws -> VerificationStatusReport {
        throw APIError.cancelled
    }

    public func withdrawPhotoConsent() async throws -> PhotoConsentWithdrawal {
        throw APIError.cancelled
    }

    /// Nothing to ready: a service without App Attest (a mock, a preview)
    /// submits without it.
    public func prepareDeviceAttestation() async {}

    /// A service that cannot count bytes submits as it always has and says
    /// nothing until the answer.
    public func submitDocument(
        _ submission: DocumentSubmission,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DocumentCase {
        try await submitDocument(submission)
    }
}
