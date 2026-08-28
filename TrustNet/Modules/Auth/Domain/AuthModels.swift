import Foundation

// MARK: - Token

/// The bearer credentials for an authenticated session.
///
/// Persisted in the keychain; **the password that produced it is never stored.**
/// The refresh token rotates on every `/auth/refresh` call, so the stored value
/// must be replaced — not merged — after each refresh.
public struct AuthToken: Codable, Equatable, Sendable {

    /// Short-lived bearer token sent as `Authorization: Bearer …`.
    public let accessToken: String
    /// Single-use token exchanged at `/auth/refresh` for a fresh pair.
    public let refreshToken: String
    /// Absolute expiry of ``accessToken``.
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// `true` once ``expiresAt`` is in the past.
    public var isExpired: Bool { expiresAt <= Date() }

    /// `true` when the token expires within `leeway` seconds — refresh proactively.
    /// - Parameter leeway: Safety margin in seconds. Defaults to 60.
    public func expiresSoon(leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSinceNow <= leeway
    }
}

// MARK: - Verification status

/// Where a user sits in the identity-verification pipeline.
///
/// Decoded from the backend's `snake_case` values by
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`, which does **not**
/// touch enum *values* — hence the explicit raw values below.
public enum VerificationStatus: String, Codable, Equatable, Sendable, CaseIterable {
    /// Never opened the verification wizard.
    case unstarted
    /// Started but not submitted.
    case inProgress = "in_progress"
    /// Submitted; a reviewer has not decided yet.
    case pendingReview = "pending_review"
    /// Approved — full access to TrustNet.
    case verified
    /// Declined — the account is locked.
    case rejected

    /// Unknown future values decode as ``unstarted`` rather than failing the
    /// whole response.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VerificationStatus(rawValue: raw) ?? .unstarted
    }

    /// Only ``verified`` may pass the wall.
    public var grantsAccess: Bool { self == .verified }
}

// MARK: - User

/// The authenticated account as the backend describes it.
public struct AuthUser: Codable, Equatable, Sendable, Identifiable {

    public let id: UUID
    public let email: String
    /// Chosen display name; `nil` until the user sets one.
    public let displayName: String?
    /// Whether the email address has been confirmed by OTP.
    public let emailVerified: Bool
    /// Identity-verification stage.
    public let verificationStatus: VerificationStatus
    public let createdAt: Date

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        emailVerified: Bool,
        verificationStatus: VerificationStatus,
        createdAt: Date
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.emailVerified = emailVerified
        self.verificationStatus = verificationStatus
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, displayName, emailVerified, verificationStatus, createdAt
    }

    /// Tolerant decoder: a missing optional or a malformed `id` must not blow
    /// away an otherwise valid session response.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .id)) ?? ""
            id = UUID(uuidString: raw) ?? UUID()
        }
        email = (try? container.decode(String.self, forKey: .email)) ?? ""
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        emailVerified = (try? container.decode(Bool.self, forKey: .emailVerified)) ?? false
        verificationStatus = (try? container.decode(VerificationStatus.self, forKey: .verificationStatus)) ?? .unstarted
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// Two-letter monogram for ``TNAvatar``.
    public var initials: String {
        if let displayName, !displayName.isEmpty {
            let parts = displayName.split(separator: " ")
            let letters = parts.prefix(2).compactMap { $0.first }
            if !letters.isEmpty { return String(letters) }
        }
        return String(email.prefix(2))
    }
}

// MARK: - Wire shapes

/// `TokenPair` as returned by `/auth/login`, `/auth/otp/verify` and `/auth/refresh`.
///
/// Flattened on decode into a ``AuthToken`` (persisted) plus an ``AuthUser``
/// (cached), because those two have very different storage lifetimes.
public struct TokenPair: Decodable, Equatable, Sendable {

    public let token: AuthToken
    public let user: AuthUser

    public init(token: AuthToken, user: AuthUser) {
        self.token = token
        self.user = user
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = AuthToken(
            accessToken: try container.decode(String.self, forKey: .accessToken),
            refreshToken: try container.decode(String.self, forKey: .refreshToken),
            expiresAt: try container.decode(Date.self, forKey: .expiresAt)
        )
        user = try container.decode(AuthUser.self, forKey: .user)
    }
}

/// Why an OTP is being requested. Sent as the `purpose` field.
public enum OTPPurpose: String, Codable, Sendable {
    /// Confirming a brand-new account's email address.
    case register
    /// Confirming an existing account at sign-in.
    case login
    /// Resetting a forgotten password.
    case reset

    /// Headline shown on the OTP screen.
    public var screenTitle: String {
        switch self {
        case .register: return "Confirm your email"
        case .login: return "Verify it's you"
        case .reset: return "Reset your password"
        }
    }
}

/// Result of `POST /auth/register`.
public struct RegistrationResult: Decodable, Equatable, Sendable {
    /// Server-side id of the freshly created account.
    public let userId: UUID
    /// Whether the confirmation email actually went out.
    public let otpSent: Bool

    public init(userId: UUID, otpSent: Bool) {
        self.userId = userId
        self.otpSent = otpSent
    }

    private enum CodingKeys: String, CodingKey {
        case userId, otpSent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? container.decode(UUID.self, forKey: .userId) {
            userId = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .userId)) ?? ""
            userId = UUID(uuidString: raw) ?? UUID()
        }
        otpSent = (try? container.decode(Bool.self, forKey: .otpSent)) ?? true
    }
}

/// Result of `POST /auth/otp/request`.
public struct OTPSendResult: Decodable, Equatable, Sendable {
    /// Whether the code was dispatched.
    public let sent: Bool
    /// Seconds the client must wait before offering "Resend".
    public let resendAfterSeconds: Int

    public init(sent: Bool, resendAfterSeconds: Int) {
        self.sent = sent
        self.resendAfterSeconds = resendAfterSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case sent, resendAfterSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sent = (try? container.decode(Bool.self, forKey: .sent)) ?? true
        resendAfterSeconds = (try? container.decode(Int.self, forKey: .resendAfterSeconds))
            ?? AppConfig.defaultOTPResendSeconds
    }
}

/// Result of `GET /verification/status`.
public struct VerificationStatusReport: Decodable, Equatable, Sendable {
    public let status: VerificationStatus
    /// Populated only when ``status`` is ``VerificationStatus/rejected``.
    public let rejectionReason: String?
    public let submittedAt: Date?
    public let reviewedAt: Date?

    public init(
        status: VerificationStatus,
        rejectionReason: String? = nil,
        submittedAt: Date? = nil,
        reviewedAt: Date? = nil
    ) {
        self.status = status
        self.rejectionReason = rejectionReason
        self.submittedAt = submittedAt
        self.reviewedAt = reviewedAt
    }

    private enum CodingKeys: String, CodingKey {
        case status, rejectionReason, submittedAt, reviewedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(VerificationStatus.self, forKey: .status)) ?? .unstarted
        rejectionReason = try? container.decodeIfPresent(String.self, forKey: .rejectionReason)
        submittedAt = try? container.decodeIfPresent(Date.self, forKey: .submittedAt)
        reviewedAt = try? container.decodeIfPresent(Date.self, forKey: .reviewedAt)
    }
}

// MARK: - Request bodies

struct RegisterRequestBody: Encodable {
    let email: String
    let password: String
}

struct OTPRequestBody: Encodable {
    let email: String
    let purpose: String
}

struct OTPVerifyBody: Encodable {
    let email: String
    let code: String
    let purpose: String
}

struct LoginRequestBody: Encodable {
    let email: String
    let password: String
}

struct RefreshRequestBody: Encodable {
    let refreshToken: String
}
