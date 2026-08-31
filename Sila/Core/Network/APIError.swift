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
                return "That email already has a Sila account. Try signing in instead."
            case .invalidCredentials:
                return "That email and password don't match."
            case .otpInvalid:
                return "That code isn't right. Check the digits and try again."
            case .otpExpired:
                return "That code has expired. Request a new one."
            case .otpAttemptsExceeded:
                return "Too many incorrect attempts. Request a new code."
            case .emailUnverified:
                return "Confirm your email address to continue."
            case .rateLimited:
                return "Too many requests. Wait a moment and try again."
            case .unauthorized:
                return "Your session has ended. Please sign in again."
            case .postNotFound:
                return "That post is no longer available."
            case .replyNotAllowed:
                // The card and the detail screen show the specific
                // `reply_block_reason`; this is the fallback if one slips past.
                return "You can't reply to this thread."
            case .noCountry:
                return "Your country flag comes from identity verification. Verify to unlock My Country."
            case .textTooLong:
                return "That post is longer than \(FeedConstants.maximumPostLength) characters."
            case .notPostAuthor:
                return "You can only delete your own posts."
            case .handleTaken:
                return "That handle is already taken."
            case .invalidHandle:
                return "Handles are 3–20 characters of letters, numbers and underscores."
            case .selfFollow:
                return "You can't follow yourself."
            case .userNotFound:
                // Phrased as a fact about the handle, not as a failure of the
                // request: there is nothing to retry, and the profile screen
                // shows this without a Try Again button for that reason.
                return "This account isn't available."
            case .unverified:
                return "Only verified humans can post. Everyone can read Sila — finish identity verification to speak."
            case .invalidScope:
                return "That audience isn't available for this post."
            case .queryTooShort:
                return "Type at least \(SearchConstants.minimumQueryLength) characters to search."
            case .unknownTopic:
                // The whole PUT is rejected, so nothing was stored — say that
                // rather than leaving the user unsure what got through.
                return "Sila's topic list has changed, so nothing was saved. Reload this screen and try again."
            case .invalidCountry:
                return "Country codes are two letters, like SA or JP."
            case .invalidImage:
                return "That file couldn't be read as an image. Pick a photo instead."
            case .imageTooLarge:
                return "That image is too big. Pick one under 5 MB."
            case .invalidPhone:
                return "Use international format, starting with a plus and a country code — for example +966501234567."
            case .passwordUnchanged:
                return "That is already your password. Choose a different one."
            case .emailUnchanged:
                return "That is already your email address."
            case .confirmationRequired:
                return "Type DELETE exactly to confirm."
            case .notPendingDeletion:
                return "This account isn't scheduled for deletion."
            case .accountDeactivated:
                // Shown only if this ever reaches a screen: the deactivation
                // monitor is meant to route it to the recovery screen first.
                return "This account is scheduled for deletion. Cancel the deletion to use it again."
            case .selfBlock:
                return "You can't block yourself."
            case .selfMute:
                return "You can't mute yourself."
            case .selfReport:
                return "You can't report yourself."
            case .invalidReason:
                return "Sila's list of reasons has changed, so nothing was sent. Reopen this form and try again."
            case .blocked:
                // Says a block exists, never who made it. Turning a safety tool
                // into a notification is exactly what nobody signed up for.
                return "You can't reply here. There's a block between you and this account."
            case .accountSuspended:
                // Shown only if this ever reaches a screen: the suspension
                // monitor is meant to route it to the suspension screen first.
                return "This account is suspended."
            case .alreadyAppealed:
                return "You've already appealed this suspension. One appeal is all Sila accepts."
            case .unknown:
                return message.isEmpty ? "Something went wrong. Please try again." : message
            }
        case let .http(status, message):
            return message.isEmpty ? "Request failed (\(status))." : message
        case .decoding:
            return "We couldn't read the server's response. Please try again."
        case let .transport(message):
            return "Network problem: \(message)"
        case .unauthenticated:
            return "Your session has ended. Please sign in again."
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
