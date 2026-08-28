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
