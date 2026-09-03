import Foundation

/// Scripted ``VerificationServiceProtocol`` used by tests, previews and the
/// `-mockVerification` launch argument.
///
/// Pick a ``MockScenario`` and the whole flow behaves consistently with it: a
/// tester can walk from the wall, through the ID form, to the exact terminal
/// state they want to see — without a backend and without spending a real
/// identity.
public actor VerificationServiceMock: VerificationServiceProtocol {

    /// The canned journeys the mock can play.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Pending for a couple of polls, then approved.
        case approved
        /// Pending for a couple of polls, then rejected with a reason.
        case rejected
        /// Pending forever — the request expires.
        case expires
        /// `start` answers 409 `already_verified`.
        case alreadyVerified
        /// `start` answers 400 `invalid_national_id`.
        case invalidNationalId
        /// `start` answers 409 `identity_already_used`.
        case identityAlreadyUsed
        /// `start` answers 503 `verification_unavailable`.
        case unavailable
        /// The poll answers 403 `under_minimum_age`.
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
    /// national ID — the mock honours the same privacy contract as the real
    /// service, so a test that inspects it proves the right thing.
    public private(set) var recordedCalls: [String] = []

    private var pollCount = 0

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
    }

    // MARK: - VerificationServiceProtocol

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
