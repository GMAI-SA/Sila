import Foundation

/// Everything the Safety module can ask the backend to do.
///
/// The seam every safety surface depends on; ``SafetyService`` and
/// ``SafetyServiceMock`` are interchangeable behind it, which is what lets the
/// paths that matter most — a block that severs two follows, a self-harm report,
/// a suspension somebody is appealing — be driven end to end without a network
/// and without doing any of it to a real account.
///
/// **Block and mute take a desired state, not an action.** Both verbs are
/// idempotent server-side: blocking somebody you have already blocked succeeds,
/// and so does the reverse. Modelling them as `setBlocked(_:handle:)` rather
/// than `block()`/`unblock()` means a stale button on a second device cannot
/// produce an error, and a retry cannot produce a double.
///
/// **The two suspension calls are deliberately on this protocol and not on
/// `AccountServiceProtocol`.** They are the only two endpoints a suspended
/// account may call, and keeping them next to the routing that sends people
/// there is what stops somebody adding a third by accident.
public protocol SafetyServiceProtocol: Sendable {

    // MARK: Blocking

    /// Blocks or unblocks an account, `POST`/`DELETE /users/{handle}/block`.
    ///
    /// - Parameters:
    ///   - blocked: The state the user asked for.
    ///   - handle: The account. Any casing, with or without an `@`.
    /// - Returns: Whether the account is blocked afterwards.
    /// - Throws: ``APIErrorCode/selfBlock`` (400) when the handle is the
    ///   viewer's own, ``APIErrorCode/userNotFound`` (404) for an unknown one,
    ///   ``APIErrorCode/rateLimited`` (429).
    func setBlocked(_ blocked: Bool, handle: String) async throws -> Bool

    /// Everyone the viewer has blocked, `GET /me/blocks`.
    func fetchBlocked() async throws -> [SafetyRelation]

    // MARK: Muting

    /// Mutes or unmutes an account, `POST`/`DELETE /users/{handle}/mute`.
    ///
    /// - Returns: Whether the account is muted afterwards.
    /// - Throws: ``APIErrorCode/selfMute`` (400), ``APIErrorCode/userNotFound``
    ///   (404), ``APIErrorCode/rateLimited`` (429).
    func setMuted(_ muted: Bool, handle: String) async throws -> Bool

    /// Everyone the viewer has muted, `GET /me/mutes`.
    func fetchMuted() async throws -> [SafetyRelation]

    // MARK: Reporting

    /// Files a report, `POST /reports`.
    ///
    /// - Returns: The receipt. Its `support` object — when there is one — is the
    ///   server saying this needs help rather than a reference number, and the
    ///   client must lead with it. See ``ReportOutcome``.
    /// - Throws: ``APIErrorCode/selfReport`` (400),
    ///   ``APIErrorCode/invalidReason`` (400), ``APIErrorCode/postNotFound``
    ///   (404), ``APIErrorCode/userNotFound`` (404),
    ///   ``APIErrorCode/rateLimited`` (429).
    func submitReport(_ request: ReportRequest) async throws -> ReportReceipt

    /// Everything the viewer has reported, `GET /me/reports`.
    func fetchReports() async throws -> [Report]

    // MARK: Suspension

    /// The viewer's suspension record, `GET /me/suspension`.
    ///
    /// **Answers while suspended**, which is the only reason the suspension
    /// screen can say anything more specific than "you are suspended".
    func fetchSuspension() async throws -> Suspension

    /// Appeals a suspension, `POST /me/appeal`.
    ///
    /// One per suspension. A second attempt is refused rather than queued.
    /// - Throws: ``APIErrorCode/alreadyAppealed`` (409) when one is already on
    ///   file — which the screen treats as the state it describes, not as an
    ///   error, because "you already appealed" is an answer to the question the
    ///   person was asking.
    func submitAppeal(message: String) async throws -> SuspensionAppeal
}
