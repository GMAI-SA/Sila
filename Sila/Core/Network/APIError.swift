import Foundation

/// Machine-readable error codes the SocialSA backend returns inside
/// `{"detail": {"code": ..., "message": ...}}`.
public enum APIErrorCode: String, Sendable, Equatable {
    /// Registration attempted with an address that already has an account.
    case emailTaken = "email_taken"
    /// Wrong email/password pair on sign-in.
    case invalidCredentials = "invalid_credentials"
    /// The submitted OTP does not match.
    case otpInvalid = "otp_invalid"
    /// The submitted OTP is past its lifetime.
    case otpExpired = "otp_expired"
    /// Too many wrong OTP guesses — a fresh code must be requested.
    case otpAttemptsExceeded = "otp_attempts_exceeded"
    /// Credentials were correct but the address has never been confirmed.
    case emailUnverified = "email_unverified"
    /// The caller is being throttled.
    case rateLimited = "rate_limited"
    /// No usable bearer token reached the server.
    ///
    /// Undocumented in either contract, but what the deployed backend actually
    /// answers on an unauthenticated request — without this the raw
    /// "Missing bearer token" would be shown to the user.
    case unauthorized = "unauthorized"

    // MARK: Phase 2 — Nafath identity verification

    /// `POST /verification/nafath/start` from an account that is already
    /// verified (HTTP 409). Not a failure — the wall just needs refreshing.
    case alreadyVerified = "already_verified"
    /// The submitted number is not a plausible National ID / Iqama (HTTP 400).
    case invalidNationalId = "invalid_national_id"
    /// This identity is already attached to a *different* Sila account
    /// (HTTP 409). One person, one account — the answer is signing in to the
    /// account that exists, and the copy has to say so rather than read as an
    /// error to retry.
    case identityAlreadyUsed = "identity_already_used"
    /// The Nafath integration is down (HTTP 503). Try later; nothing was lost.
    case verificationUnavailable = "verification_unavailable"
    /// The verified identity is under Sila's minimum age (HTTP 403). There is
    /// nothing to retry and nothing to correct — the server's message is shown
    /// as-is.
    case underMinimumAge = "under_minimum_age"

    // MARK: Contract v2 — feed & social

    /// The requested post id does not exist (or is no longer visible).
    case postNotFound = "post_not_found"
    /// The thread's scope excludes this viewer — see `viewer.reply_block_reason`.
    case replyNotAllowed = "reply_not_allowed"
    /// `GET /feed/country` from an account with no verified country.
    case noCountry = "no_country"
    /// A post body longer than ``FeedConstants/maximumPostLength``.
    case textTooLong = "text_too_long"
    /// Delete or edit attempted on someone else's post.
    case notPostAuthor = "not_post_author"
    /// The requested handle is already in use.
    case handleTaken = "handle_taken"
    /// The requested handle breaks the `[a-z0-9_]{3,20}` rule.
    case invalidHandle = "invalid_handle"
    /// An account tried to follow itself.
    case selfFollow = "self_follow"
    /// No active account has that handle.
    ///
    /// Returned by every `/users/{handle}` route for an unknown handle **and**
    /// for a deactivated one — the lookup filters `deactivated == False`, so the
    /// two are deliberately indistinguishable. An error that admitted the second
    /// case would leak the existence of an account that asked to be gone.
    case userNotFound = "user_not_found"

    // MARK: Contract v3 — compose & search

    /// `POST /posts` from an account that has not completed identity
    /// verification. Reading is open to everyone; speaking is not.
    case unverified
    /// The `scope` / `scope_country` / `scope_region` combination was rejected —
    /// e.g. a country thread opened for a country the author is not verified in.
    case invalidScope = "invalid_scope"
    /// A search query shorter than ``SearchConstants/minimumQueryLength``.
    case queryTooShort = "query_too_short"

    // MARK: Contract v4 — interests & preferences

    /// `PUT /me/preferences` carried a topic id outside the server's taxonomy.
    case unknownTopic = "unknown_topic"
    /// `PUT /me/preferences` carried something that is not an ISO-3166 alpha-2 code.
    case invalidCountry = "invalid_country"

    // MARK: Contract v5 — account management

    /// The uploaded file could not be decoded as an image (HTTP 400).
    case invalidImage = "invalid_image"
    /// The upload is over 5 MB, or over 50 megapixels (HTTP 413).
    case imageTooLarge = "image_too_large"
    /// `PUT /me/phone` was given something that is not E.164 (HTTP 400).
    case invalidPhone = "invalid_phone"
    /// The new password is the same as the current one (HTTP 400).
    case passwordUnchanged = "password_unchanged"
    /// The requested address is the one already on the account (HTTP 400).
    case emailUnchanged = "email_unchanged"
    /// `POST /me/delete` arrived without `confirm: "DELETE"` (HTTP 400).
    case confirmationRequired = "confirmation_required"
    /// `POST /me/delete/cancel` on an account with nothing to cancel (HTTP 400).
    case notPendingDeletion = "not_pending_deletion"
    /// The account is scheduled for deletion (HTTP 403).
    ///
    /// Not a 401: the credentials are perfectly good. Every authenticated call
    /// answers this until the deletion is cancelled, which is why the client
    /// routes it to the recovery screen rather than showing it as an error.
    case accountDeactivated = "account_deactivated"

    // MARK: Safety — block, mute, report, suspension

    /// An account tried to block itself (HTTP 400).
    case selfBlock = "self_block"
    /// An account tried to mute itself (HTTP 400).
    case selfMute = "self_mute"
    /// An account tried to report itself (HTTP 400).
    case selfReport = "self_report"
    /// `POST /reports` carried a reason outside the server's list (HTTP 400).
    ///
    /// Unreachable from the picker, which is built out of ``ReportReason`` — it
    /// exists for a build talking to a server whose vocabulary has moved on.
    case invalidReason = "invalid_reason"
    /// There is a block between the viewer and this thread (HTTP 403).
    ///
    /// Deliberately says nothing about **which** direction. Whether somebody
    /// blocked you or you blocked them, the outcome is the same and the client
    /// has no business turning a safety tool into a notification.
    case blocked
    /// The account is suspended (HTTP 403).
    ///
    /// Not a 401: the credentials are good. Every authenticated call answers
    /// this except `GET /me/suspension` and `POST /me/appeal`, which is why the
    /// client routes it to the suspension screen rather than showing it as an
    /// error with a Retry button that can only produce it again.
    case accountSuspended = "account_suspended"
    /// A second appeal against the same suspension (HTTP 409).
    case alreadyAppealed = "already_appealed"

    // MARK: Voice rooms

    /// The room's scope excludes this account from **speaking**.
    ///
    /// Never from listening: there is no code for that, because there is no
    /// such refusal. Anyone may enter any room.
    case scopeNotAllowed = "scope_not_allowed"
    /// The host removed this account from **this room**.
    ///
    /// Per-room and nothing more. It is not a block, it changes nothing about
    /// the account, and it does not follow anybody into another room — which is
    /// why it has its own code and its own sentence rather than borrowing
    /// ``blocked``'s.
    case removedFromRoom = "removed_from_room"
    /// The room is over. Nothing was recorded, so there is nothing to rejoin.
    case roomEnded = "room_ended"
    /// A host-only call from somebody who is not the host.
    case notRoomHost = "not_room_host"
    /// The stage has as many speakers as it will hold.
    case stageFull = "stage_full"
    /// A host tried to move themselves off their own stage.
    case cannotDemoteHost = "cannot_demote_host"
    /// The room id does not exist.
    case notFound = "not_found"

    /// Anything the client does not recognise.
    case unknown

    /// Maps a raw server code to a case, defaulting to ``unknown``.
    public init(serverCode: String) {
        self = APIErrorCode(rawValue: serverCode) ?? .unknown
    }
}

/// Every failure the networking layer can produce.
public enum APIError: Error, Equatable, Sendable {
    /// A structured `detail` object came back from the API.
    case api(code: APIErrorCode, message: String, status: Int)
    /// A non-2xx response we could not parse into ``api(code:message:status:)``.
    case http(status: Int, message: String)
    /// The response body did not match the expected shape.
    case decoding(String)
    /// URLSession failed (offline, DNS, TLS, timeout…).
    case transport(String)
    /// No credentials available for a call that requires them.
    case unauthenticated
    /// The device refused or failed the biometric prompt.
    case biometricFailed(String)

    /// The structured code when one is available.
    public var code: APIErrorCode? {
        if case let .api(code, _, _) = self { return code }
        return nil
    }

    /// A sentence safe to put in front of a user.
    public var userMessage: String {
        switch self {
        case let .api(code, message, _):
            switch code {
            case .emailTaken:
                return L10n.t("error.emailTaken")
            case .invalidCredentials:
                return L10n.t("error.invalidCredentials")
            case .otpInvalid:
                return L10n.t("error.otpInvalid")
            case .otpExpired:
                return L10n.t("error.otpExpired")
            case .otpAttemptsExceeded:
                return L10n.t("error.otpAttemptsExceeded")
            case .emailUnverified:
                return L10n.t("error.emailUnverified")
            case .rateLimited:
                return L10n.t("error.rateLimited")
            case .unauthorized:
                return L10n.t("error.sessionEnded")
            case .alreadyVerified:
                return L10n.t("error.alreadyVerified")
            case .invalidNationalId:
                return L10n.t("error.invalidNationalId")
            case .identityAlreadyUsed:
                return L10n.t("error.identityAlreadyUsed")
            case .verificationUnavailable:
                return L10n.t("error.verificationUnavailable")
            case .underMinimumAge:
                // The server's sentence when it sent one: the age rule and its
                // wording are policy, and policy copy comes from the server.
                return message.isEmpty ? L10n.t("error.underMinimumAge") : message
            case .postNotFound:
                return L10n.t("error.postNotFound")
            case .replyNotAllowed:
                // The card and the detail screen show the specific
                // `reply_block_reason`; this is the fallback if one slips past.
                return L10n.t("error.replyNotAllowed")
            case .noCountry:
                return L10n.t("error.noCountry")
            case .textTooLong:
                return L10n.plural("error.textTooLong", FeedConstants.maximumPostLength)
            case .notPostAuthor:
                return L10n.t("error.notPostAuthor")
            case .handleTaken:
                return L10n.t("error.handleTaken")
            case .invalidHandle:
                return L10n.t("error.invalidHandle")
            case .selfFollow:
                return L10n.t("error.selfFollow")
            case .userNotFound:
                // Phrased as a fact about the handle, not as a failure of the
                // request: there is nothing to retry, and the profile screen
                // shows this without a Try Again button for that reason.
                return L10n.t("error.userNotFound")
            case .unverified:
                return L10n.t("error.unverified")
            case .invalidScope:
                return L10n.t("error.invalidScope")
            case .queryTooShort:
                return L10n.plural("error.queryTooShort", SearchConstants.minimumQueryLength)
            case .unknownTopic:
                // The whole PUT is rejected, so nothing was stored — say that
                // rather than leaving the user unsure what got through.
                return L10n.t("error.unknownTopic")
            case .invalidCountry:
                return L10n.t("error.invalidCountry")
            case .invalidImage:
                return L10n.t("error.invalidImage")
            case .imageTooLarge:
                return L10n.t("error.imageTooLarge")
            case .invalidPhone:
                return L10n.t("error.invalidPhone")
            case .passwordUnchanged:
                return L10n.t("error.passwordUnchanged")
            case .emailUnchanged:
                return L10n.t("error.emailUnchanged")
            case .confirmationRequired:
                return L10n.t("error.confirmationRequired")
            case .notPendingDeletion:
                return L10n.t("error.notPendingDeletion")
            case .accountDeactivated:
                // Shown only if this ever reaches a screen: the deactivation
                // monitor is meant to route it to the recovery screen first.
                return L10n.t("error.accountDeactivated")
            case .selfBlock:
                return L10n.t("error.selfBlock")
            case .selfMute:
                return L10n.t("error.selfMute")
            case .selfReport:
                return L10n.t("error.selfReport")
            case .invalidReason:
                return L10n.t("error.invalidReason")
            case .blocked:
                // Says a block exists, never who made it. Turning a safety tool
                // into a notification is exactly what nobody signed up for.
                return L10n.t("error.blocked")
            case .accountSuspended:
                // Shown only if this ever reaches a screen: the suspension
                // monitor is meant to route it to the suspension screen first.
                return L10n.t("error.accountSuspended")
            case .alreadyAppealed:
                return L10n.t("error.alreadyAppealed")
            case .scopeNotAllowed:
                // Says exactly what is refused. The room itself is still open —
                // scope governs the microphone, never the door.
                return L10n.t("error.scopeNotAllowed")
            case .removedFromRoom:
                return RoomCopy.removedFromRoom
            case .roomEnded:
                return RoomCopy.roomEnded
            case .notRoomHost:
                return L10n.t("error.notRoomHost")
            case .stageFull:
                return RoomCopy.stageFull
            case .cannotDemoteHost:
                return RoomCopy.cannotDemoteHost
            case .notFound:
                return L10n.t("error.roomNotFound")
            case .unknown:
                return message.isEmpty ? L10n.t("common.somethingWentWrong") : message
            }
        case let .http(status, message):
            return message.isEmpty ? L10n.t("error.httpStatus", SLFormat.number(status)) : message
        case .decoding:
            return L10n.t("error.decoding")
        case let .transport(message):
            return L10n.t("error.transport", message)
        case .unauthenticated:
            return L10n.t("error.sessionEnded")
        case let .biometricFailed(message):
            return message
        }
    }
}

/// The `detail` payload shape used by the backend for structured errors.
struct APIErrorEnvelope: Decodable {
    let detail: Detail

    struct Detail: Decodable {
        let code: String
        let message: String
    }
}

/// Fallback shape for FastAPI's plain-string `detail`.
struct APIErrorStringEnvelope: Decodable {
    let detail: String
}
