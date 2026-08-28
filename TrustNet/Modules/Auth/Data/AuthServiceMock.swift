import Foundation

/// Scripted ``AuthServiceProtocol`` used by tests, previews and the
/// `-mockAuth` launch argument.
///
/// Pick a ``MockScenario`` and every method behaves consistently with it, so a
/// tester can walk the whole flow and land on the wall state they want to see
/// without a backend.
///
/// ```swift
/// let service = AuthServiceMock(scenario: .rejected)
/// ```
public actor AuthServiceMock: AuthServiceProtocol {

    /// The canned journeys the mock can play.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Happy path, but the user has never opened the verification wizard.
        case unstarted
        /// The user abandoned the wizard part-way.
        case inProgress
        /// Documents submitted, awaiting a reviewer.
        case pendingReview
        /// Fully verified — the wall lets them through.
        case verified
        /// Declined, with a reason.
        case rejected
        /// `/auth/login` answers 403 `email_unverified`, forcing the OTP screen.
        case emailUnverified
        /// `/auth/login` answers 401 `invalid_credentials`.
        case invalidCredentials
        /// `/auth/otp/verify` answers `otp_invalid`.
        case otpAlwaysInvalid
        /// Every call fails with a transport error.
        case offline

        /// The verification status the mocked user carries.
        var verificationStatus: VerificationStatus {
            switch self {
            case .inProgress: return .inProgress
            case .pendingReview: return .pendingReview
            case .verified: return .verified
            case .rejected: return .rejected
            default: return .unstarted
            }
        }

        /// Rejection copy surfaced on the rejected screen.
        var rejectionReason: String? {
            self == .rejected
                ? "The photo of your ID was too blurry for our reviewers to read the document number."
                : nil
        }
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// The 6-digit code the mock accepts. Any other code is rejected.
    public let acceptedCode: String

    /// Artificial latency, in seconds, applied to every call.
    private let latency: Double

    /// The biometry this mock reports. A `let` on an actor is safe to read
    /// from outside, which is what lets it satisfy the synchronous protocol
    /// requirement without a hop.
    public let availableBiometry: BiometryKind

    private var storedPair: TokenPair?
    private var biometricAccount: String?

    /// Calls recorded for test assertions.
    public private(set) var recordedCalls: [String] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which journey to play. Defaults to ``MockScenario/pendingReview``.
    ///   - acceptedCode: The OTP the mock treats as correct.
    ///   - latency: Seconds of simulated network delay. Tests pass `0`.
    ///   - biometry: What ``availableBiometry`` reports.
    ///   - hasBiometricCredential: Seeds a saved biometric account.
    public init(
        scenario: MockScenario = .pendingReview,
        acceptedCode: String = "123456",
        latency: Double = 0,
        biometry: BiometryKind = .faceID,
        hasBiometricCredential: Bool = false
    ) {
        self.scenario = scenario
        self.acceptedCode = acceptedCode
        self.latency = latency
        self.availableBiometry = biometry
        self.biometricAccount = hasBiometricCredential ? "saved@trustnet.app" : nil
        if hasBiometricCredential {
            self.storedPair = Self.makePair(email: "saved@trustnet.app", scenario: scenario)
        }
    }

    /// Switches scenario mid-flight (used by previews and UI test hooks).
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - AuthServiceProtocol

    public func register(email: String, password: String) async throws -> RegistrationResult {
        record("register")
        try await delay()
        try failIfOffline()
        if email.lowercased() == "taken@trustnet.app" {
            throw APIError.api(code: .emailTaken, message: "Email already registered", status: 409)
        }
        return RegistrationResult(userId: UUID(), otpSent: true)
    }

    public func sendOTP(email: String, purpose: OTPPurpose) async throws -> OTPSendResult {
        record("sendOTP:\(purpose.rawValue)")
        try await delay()
        try failIfOffline()
        return OTPSendResult(sent: true, resendAfterSeconds: AppConfig.defaultOTPResendSeconds)
    }

    public func verifyOTP(email: String, code: String, purpose: OTPPurpose) async throws -> TokenPair {
        record("verifyOTP")
        try await delay()
        try failIfOffline()
        if scenario == .otpAlwaysInvalid || code != acceptedCode {
            throw APIError.api(code: .otpInvalid, message: "Incorrect code", status: 400)
        }
        let pair = Self.makePair(email: email, scenario: scenario, emailVerified: true)
        storedPair = pair
        return pair
    }

    public func signIn(email: String, password: String) async throws -> TokenPair {
        record("signIn")
        try await delay()
        try failIfOffline()
        switch scenario {
        case .invalidCredentials:
            throw APIError.api(code: .invalidCredentials, message: "Bad credentials", status: 401)
        case .emailUnverified:
            throw APIError.api(code: .emailUnverified, message: "Email not verified", status: 403)
        default:
            let pair = Self.makePair(email: email, scenario: scenario, emailVerified: true)
            storedPair = pair
            biometricAccount = email
            return pair
        }
    }

    public func signInBiometric() async throws -> TokenPair {
        record("signInBiometric")
        try await delay()
        try failIfOffline()
        guard let account = biometricAccount else {
            throw APIError.biometricFailed("No saved TrustNet sign-in on this device.")
        }
        let pair = Self.makePair(email: account, scenario: scenario, emailVerified: true)
        storedPair = pair
        return pair
    }

    public func refreshToken(_ token: AuthToken) async throws -> TokenPair {
        record("refreshToken")
        try await delay()
        try failIfOffline()
        guard let existing = storedPair else { throw APIError.unauthenticated }
        let rotated = TokenPair(
            token: AuthToken(
                accessToken: "mock-access-\(UUID().uuidString.prefix(8))",
                refreshToken: "mock-refresh-\(UUID().uuidString.prefix(8))",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            user: existing.user
        )
        storedPair = rotated
        return rotated
    }

    public func signOut() async throws {
        record("signOut")
        try await delay()
        storedPair = nil
        biometricAccount = nil
    }

    public func currentUser() async throws -> AuthUser {
        record("currentUser")
        try await delay()
        try failIfOffline()
        guard let pair = storedPair else { throw APIError.unauthenticated }
        return pair.user
    }

    public func verificationStatus() async throws -> VerificationStatusReport {
        record("verificationStatus")
        try await delay()
        try failIfOffline()
        return VerificationStatusReport(
            status: scenario.verificationStatus,
            rejectionReason: scenario.rejectionReason,
            submittedAt: scenario.verificationStatus == .unstarted ? nil : Date().addingTimeInterval(-7200),
            reviewedAt: scenario == .rejected || scenario == .verified ? Date().addingTimeInterval(-600) : nil
        )
    }

    public func biometricEmail() async -> String? {
        biometricAccount
    }

    // MARK: - Internals

    private func record(_ call: String) {
        recordedCalls.append(call)
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }

    /// Builds a deterministic token pair for a scenario.
    static func makePair(
        email: String,
        scenario: MockScenario,
        emailVerified: Bool = false
    ) -> TokenPair {
        TokenPair(
            token: AuthToken(
                accessToken: "mock-access-token",
                refreshToken: "mock-refresh-token",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            user: AuthUser(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
                email: email,
                displayName: nil,
                emailVerified: emailVerified,
                verificationStatus: scenario.verificationStatus,
                createdAt: Date().addingTimeInterval(-86_400),
                handle: "aziz",
                // Only a verified account carries a country badge, which is what
                // makes the composer's "My Country" scope appear or not appear
                // in a mocked run.
                countryCode: scenario.verificationStatus == .verified ? "SA" : nil
            )
        )
    }
}
