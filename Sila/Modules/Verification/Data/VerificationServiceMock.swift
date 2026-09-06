import Foundation

/// Scripted ``VerificationServiceProtocol`` used by tests, previews and the
/// `-mockVerification` launch argument.
///
/// Pick a ``MockScenario`` and the whole flow behaves consistently with it: a
/// tester can walk from the wall, through either route, to the exact terminal
/// state they want to see — without a backend and without spending a real
/// identity or a real passport.
public actor VerificationServiceMock: VerificationServiceProtocol {

    /// The canned journeys the mock can play. The same scenario drives both
    /// routes, so a tester picks one word and sees the same outcome whichever
    /// door they walk through.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Nafath: pending for a couple of polls, then approved.
        /// Document: submitted, then the latest case reads `approved`.
        case approved
        /// Nafath: pending, then rejected with a reason.
        /// Document: submitted, then the latest case reads `rejected`.
        case rejected
        /// Nafath: pending forever — the request expires.
        /// Document: submitted, and stays under review.
        case expires
        /// Either start answers 409 `already_verified`.
        case alreadyVerified
        /// Nafath start answers 400 `invalid_national_id`;
        /// document submit answers 400 `invalid_mrz`.
        case invalidNationalId
        /// Either start answers 409 `identity_already_used`.
        case identityAlreadyUsed
        /// Nafath start answers 503 `verification_unavailable`;
        /// document submit answers 409 `review_pending`.
        case unavailable
        /// Nafath poll / document submit answer 403 `under_minimum_age`.
        case underMinimumAge
        /// Every call fails with a transport error.
        case offline
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// How many polls answer `pending` before the terminal state.
    public let pendingPolls: Int

    /// How long a mock request lives. Short by default so the `expires`
    /// scenario is watchable; tests pass what they need.
    public let requestLifetime: TimeInterval

    /// Artificial latency, in seconds, applied to every call.
    private let latency: Double

    /// Calls recorded for test assertions. Deliberately **never** includes the
    /// national ID, the zone, or anything read off a document — the mock
    /// honours the same privacy contract as the real service, so a test that
    /// inspects it proves the right thing.
    public private(set) var recordedCalls: [String] = []

    private var pollCount = 0
    private var submitted: DocumentCase?

    /// The fixed number the waiting screen shows in mock runs.
    public static let mockRandomNumber = "42"

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which journey to play. Defaults to ``MockScenario/approved``.
    ///   - pendingPolls: Polls that answer `pending` first. Defaults to 2.
    ///   - requestLifetime: Seconds until the mock request expires.
    ///   - latency: Seconds of simulated network delay. Tests pass `0`.
    public init(
        scenario: MockScenario = .approved,
        pendingPolls: Int = 2,
        requestLifetime: TimeInterval = 90,
        latency: Double = 0
    ) {
        self.scenario = scenario
        self.pendingPolls = pendingPolls
        self.requestLifetime = requestLifetime
        self.latency = latency
    }

    /// Switches scenario mid-flight (used by previews).
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
        pollCount = 0
        submitted = nil
    }

    // MARK: - Nafath

    public func startNafath(nationalID: String) async throws -> NafathStart {
        record("startNafath")
        try await delay()
        try failIfOffline()

        switch scenario {
        case .alreadyVerified:
            throw APIError.api(
                code: .alreadyVerified,
                message: "This account is already verified.",
                status: 409
            )
        case .invalidNationalId:
            throw APIError.api(
                code: .invalidNationalId,
                message: "That is not a valid National ID or Iqama number.",
                status: 400
            )
        case .identityAlreadyUsed:
            throw APIError.api(
                code: .identityAlreadyUsed,
                message: "This identity is already linked to another account.",
                status: 409
            )
        case .unavailable:
            throw APIError.api(
                code: .verificationUnavailable,
                message: "Verification is temporarily unavailable.",
                status: 503
            )
        default:
            pollCount = 0
            return NafathStart(
                requestId: "mock-nafath-\(UUID().uuidString.prefix(8))",
                randomNumber: Self.mockRandomNumber,
                expiresAt: Date().addingTimeInterval(requestLifetime),
                provider: "nafath"
            )
        }
    }

    public func pollNafath(requestID: String) async throws -> NafathPoll {
        record("pollNafath")
        try await delay()
        try failIfOffline()

        if scenario == .underMinimumAge {
            throw APIError.api(
                code: .underMinimumAge,
                message: "Sila is available to people aged 13 and over.",
                status: 403
            )
        }

        pollCount += 1
        guard pollCount > pendingPolls else {
            return NafathPoll(status: .pending, verificationStatus: .inProgress)
        }

        switch scenario {
        case .approved:
            return NafathPoll(
                status: .approved,
                verificationStatus: .verified,
                countryCode: "SA"
            )
        case .rejected:
            return NafathPoll(
                status: .rejected,
                verificationStatus: .unstarted,
                rejectionReason: "The Nafath request was declined from the Nafath app."
            )
        case .expires:
            // The mock stays pending; the view model's own expiry clock is
            // what ends the wait — exactly as it would against the real API.
            return NafathPoll(status: .pending, verificationStatus: .inProgress)
        default:
            return NafathPoll(status: .pending, verificationStatus: .inProgress)
        }
    }

    // MARK: - Document + selfie

    public func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        record("submitDocument")
        try await delay()
        try failIfOffline()

        switch scenario {
        case .alreadyVerified:
            throw APIError.api(code: .alreadyVerified, message: "This account is already verified.", status: 409)
        case .invalidNationalId:
            throw APIError.api(
                code: .invalidMrz,
                message: "The machine-readable zone could not be verified. Retake the photo in good light.",
                status: 400
            )
        case .identityAlreadyUsed:
            throw APIError.api(
                code: .identityAlreadyUsed,
                message: "That document is already verified on another account.",
                status: 409
            )
        case .unavailable:
            throw APIError.api(
                code: .reviewPending,
                message: "A submission is already waiting for review.",
                status: 409
            )
        case .underMinimumAge:
            throw APIError.api(
                code: .underMinimumAge,
                message: "You must be at least 13 to use Sila.",
                status: 403
            )
        default:
            let documentCase = DocumentCase(
                id: "mock-case-\(UUID().uuidString.prefix(8))",
                status: .submitted,
                documentType: submission.documentType.wireValue,
                nationality: submission.mrz?.nationality ?? "US",
                mrzValid: submission.mrz?.isValid ?? false,
                livenessPassed: Set(submission.challenges) == Set(LivenessChallenge.allCases),
                submittedAt: Date(),
                verificationStatus: .pendingReview
            )
            submitted = documentCase
            return documentCase
        }
    }

    public func latestDocumentCase() async throws -> DocumentCase? {
        record("latestDocumentCase")
        try await delay()
        try failIfOffline()
        guard let submitted else { return nil }

        switch scenario {
        case .approved:
            return DocumentCase(
                id: submitted.id,
                status: .approved,
                documentType: submitted.documentType,
                nationality: submitted.nationality,
                mrzValid: submitted.mrzValid,
                livenessPassed: submitted.livenessPassed,
                submittedAt: submitted.submittedAt,
                reviewedAt: Date(),
                verificationStatus: .verified
            )
        case .rejected:
            return DocumentCase(
                id: submitted.id,
                status: .rejected,
                documentType: submitted.documentType,
                nationality: submitted.nationality,
                mrzValid: submitted.mrzValid,
                livenessPassed: submitted.livenessPassed,
                submittedAt: submitted.submittedAt,
                reviewedAt: Date(),
                rejectionReason: "The selfie does not match the photo on the document.",
                verificationStatus: .rejected
            )
        default:
            return submitted
        }
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
}
