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
    /// Approved — full access to Sila.
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

    /// Unique, lowercase handle generated from the email on first use.
    ///
    /// Added by contract v2. `nil` on a session cached by an older build, or
    /// from a server that has not deployed v2 yet.
    public let handle: String?

    /// The **country-verified** flag: ISO-3166 alpha-2, or `nil`.
    ///
    /// Written only by the verification pipeline, and served only while the
    /// account is verified — a revoked account reports `nil` here, which is what
    /// closes the country-thread loophole. The composer's scope picker reads
    /// this and nothing else; it is never inferred from a locale or an IP.
    public let countryCode: String?

    /// Remote avatar image, or `nil` for the monogram fallback.
    public let avatarURL: URL?

    /// E.164 contact number, when the account carries one.
    ///
    /// Present for phone-registered accounts — whose ``email`` is a machine
    /// placeholder — and optional everywhere else. Decoded tolerantly like
    /// every other optional here.
    public let phone: String?

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        emailVerified: Bool,
        verificationStatus: VerificationStatus,
        createdAt: Date,
        handle: String? = nil,
        countryCode: String? = nil,
        avatarURL: URL? = nil,
        phone: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.emailVerified = emailVerified
        self.verificationStatus = verificationStatus
        self.createdAt = createdAt
        self.handle = handle
        self.countryCode = CountryCode.normalised(countryCode)
        self.avatarURL = avatarURL
        self.phone = phone
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, displayName, emailVerified, verificationStatus, createdAt
        case handle, countryCode, phone
        case avatarURL = "avatarUrl"
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
        handle = (try? container.decodeIfPresent(String.self, forKey: .handle)) ?? nil
        // An unrecognised code is dropped, not rendered: a flag the client
        // cannot name would be a guess, and the badge is never a guess.
        countryCode = CountryCode.normalised(
            (try? container.decodeIfPresent(String.self, forKey: .countryCode)) ?? nil
        )
        // See the note in `UserSummary.init(from:)`: the wire carries a
        // root-relative path, so it has to be resolved against the API origin
        // or it decodes into a hostless URL that never loads.
        avatarURL = AppConfig.mediaURL(
            (try? container.decodeIfPresent(String.self, forKey: .avatarURL)) ?? nil
        )
        phone = (try? container.decodeIfPresent(String.self, forKey: .phone)) ?? nil
    }

    /// The handle as it is rendered, with the `@`, when the account has one.
    public var atHandle: String? {
        guard let handle, !handle.isEmpty else { return nil }
        return "@\(handle)"
    }

    /// What the Face ID / Touch ID prompt should call this account.
    ///
    /// Preference order: the handle, the phone, the email — because a
    /// phone-registered account's email is a placeholder
    /// (`…@phone.sila.invalid`), and showing machine noise at the exact moment
    /// the prompt is asking for trust reads as a compromise, not a shortcut.
    /// The email survives as the last resort: an email-registered account with
    /// no handle yet has nothing truer to show.
    public var biometricIdentityLabel: String {
        if let atHandle { return atHandle }
        if let phone, !phone.isEmpty { return phone }
        return email
    }

    /// Two-letter monogram for ``SLAvatar``.
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
        case .register: return L10n.t("auth.otp.navTitle.register")
        case .login: return L10n.t("auth.otp.navTitle.login")
        case .reset: return L10n.t("auth.otp.navTitle.reset")
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
    /// The nationality the person declared — the claim verification tests.
    /// `nil` until they have chosen one.
    public let nationality: String?
    /// The person's appeal against the current decision, when they filed one.
    /// Only ever present while ``status`` is ``VerificationStatus/rejected``.
    public let appeal: VerificationAppealReceipt?
    /// The birthdate the person declared, as `YYYY-MM-DD`. Asked on the
    /// document route and tested against the document; `nil` until given.
    public let dateOfBirth: String?

    public init(
        status: VerificationStatus,
        rejectionReason: String? = nil,
        submittedAt: Date? = nil,
        reviewedAt: Date? = nil,
        nationality: String? = nil,
        appeal: VerificationAppealReceipt? = nil,
        dateOfBirth: String? = nil
    ) {
        self.status = status
        self.rejectionReason = rejectionReason
        self.submittedAt = submittedAt
        self.reviewedAt = reviewedAt
        self.nationality = nationality
        self.appeal = appeal
        self.dateOfBirth = dateOfBirth
    }

    private enum CodingKeys: String, CodingKey {
        case status, rejectionReason, submittedAt, reviewedAt, nationality, appeal, dateOfBirth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(VerificationStatus.self, forKey: .status)) ?? .unstarted
        rejectionReason = try? container.decodeIfPresent(String.self, forKey: .rejectionReason)
        submittedAt = try? container.decodeIfPresent(Date.self, forKey: .submittedAt)
        reviewedAt = try? container.decodeIfPresent(Date.self, forKey: .reviewedAt)
        nationality = CountryCode.normalised(try? container.decodeIfPresent(String.self, forKey: .nationality))
        appeal = try? container.decodeIfPresent(VerificationAppealReceipt.self, forKey: .appeal)
        dateOfBirth = ISODay.normalised((try? container.decodeIfPresent(String.self, forKey: .dateOfBirth)) ?? nil)
    }
}

/// A calendar day as the server writes it: `YYYY-MM-DD`, no time, no zone.
///
/// Birthdates travel as days rather than instants on purpose: a `Date` at
/// midnight UTC displays as the day before in Riyadh, and a birthdate off by
/// one is a mismatch that closes an account.
public enum ISODay {

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The string, when it is a real day; `nil` otherwise.
    public static func normalised(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard formatter.date(from: raw) != nil else { return nil }
        return raw
    }

    /// `date` as a day, read in UTC — which is how the zone parser makes it.
    public static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// The day as a `Date` at midnight UTC.
    public static func date(_ day: String) -> Date? {
        formatter.date(from: day)
    }
}

/// Where an appeal against a verification decision has got to.
///
/// The server's vocabulary is `pending | upheld | overturned`; *upheld* means
/// the **decision** stands, *overturned* means the appeal succeeded. Anything
/// this build does not know reads as ``unknown``, which the screen shows as
/// "submitted" — an appeal that reached the server is on file whatever its
/// state is called.
public enum VerificationAppealStatus: String, Sendable, Equatable, Hashable {
    case pending
    case upheld
    case overturned
    case unknown

    public init(serverValue: String) {
        self = VerificationAppealStatus(rawValue: serverValue.lowercased()) ?? .unknown
    }

    /// The sentence the person reads.
    public var label: String {
        switch self {
        case .pending, .unknown: return L10n.t("auth.rejected.appeal.status.pending")
        case .upheld: return L10n.t("auth.rejected.appeal.status.upheld")
        case .overturned: return L10n.t("auth.rejected.appeal.status.overturned")
        }
    }
}

/// An appeal on file against a verification decision.
///
/// From `/verification/status` (`appeal`) or the answer to
/// `POST /verification/appeal`. One per decision: the server refuses a
/// second with `already_appealed`, which the screen treats as the state it
/// describes rather than as an error.
public struct VerificationAppealReceipt: Decodable, Equatable, Sendable {

    /// The server's limit on an appeal's length.
    public static let maximumLength = 1_000

    public let id: String?
    public let status: VerificationAppealStatus
    /// When it was sent, or `nil` when the server did not say.
    public let submittedAt: Date?

    public init(id: String? = nil, status: VerificationAppealStatus = .pending, submittedAt: Date? = nil) {
        self.id = id
        self.status = status
        self.submittedAt = submittedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, submittedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        status = VerificationAppealStatus(serverValue: (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "pending")
        submittedAt = try? container.decodeIfPresent(Date.self, forKey: .submittedAt)
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
