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

    /// The caller's most recent document case, or `nil` when there has never
    /// been one.
    func latestDocumentCase() async throws -> DocumentCase?

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
}
