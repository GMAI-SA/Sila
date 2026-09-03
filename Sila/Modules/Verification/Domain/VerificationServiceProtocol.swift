import Foundation

/// Everything the Verification module can ask the backend to do.
///
/// The seam ``NafathVerificationViewModel`` depends on; the real
/// implementation (``VerificationService``) and the scripted one
/// (``VerificationServiceMock``) are interchangeable.
///
/// The national ID passed to ``startNafath(nationalID:)`` is sent once and
/// discarded. Implementations must not store it, log it, or attach it to an
/// analytics event — the number is somebody's government identity, and this
/// protocol's contract is that it exists exactly as long as the request does.
public protocol VerificationServiceProtocol: Sendable {

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
}
