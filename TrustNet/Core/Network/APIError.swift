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
                return "That email already has a TrustNet account. Try signing in instead."
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
            case .unverified:
                return "Only verified humans can post. Everyone can read TrustNet — finish identity verification to speak."
            case .invalidScope:
                return "That audience isn't available for this post."
            case .queryTooShort:
                return "Type at least \(SearchConstants.minimumQueryLength) characters to search."
            case .unknownTopic:
                // The whole PUT is rejected, so nothing was stored — say that
                // rather than leaving the user unsure what got through.
                return "TrustNet's topic list has changed, so nothing was saved. Reload this screen and try again."
            case .invalidCountry:
                return "Country codes are two letters, like SA or JP."
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
