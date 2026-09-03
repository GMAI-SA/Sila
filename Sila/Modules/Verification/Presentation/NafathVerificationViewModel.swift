import Foundation
import Observation

/// Which screen of the Nafath flow is showing.
public enum NafathPhase: Equatable, Sendable {
    /// Collecting the National ID / Iqama number.
    case enterID
    /// A request exists; the person is tapping the number in the Nafath app
    /// while we poll.
    case waiting
    /// Verified. The only way through the wall.
    case approved
    /// Nafath declined the request. Starting again is offered.
    case rejected
    /// The request lapsed before Nafath answered. Starting again is offered.
    case expired
    /// This identity already has a Sila account — **not** a failure. The way
    /// forward is signing in to that account, and the copy says so.
    case identityUsed
    /// The verified identity is under Sila's minimum age. Terminal; there is
    /// nothing to retry and nothing to correct.
    case underAge
}

/// Drives ``NafathVerificationScreen``.
///
/// Two properties of this type are contracts, not implementation details:
///
/// **The national ID exists only as the field's live text.** On a successful
/// start it is cleared; it is never persisted, never echoed into copy, and
/// never attached to an analytics event. `NafathPrivacyTests` asserts the
/// analytics half of that.
///
/// **Polling is bounded.** Every ~3 seconds until a terminal status, or until
/// `expires_at` passes — whichever comes first. A dropped poll is retried on
/// the next tick rather than surfaced; the expiry clock is what ends a wait
/// the server never answers.
@MainActor
@Observable
public final class NafathVerificationViewModel {

    // MARK: Inputs

    /// The typed National ID / Iqama number. Cleared the moment the server
    /// accepts it.
    public var nationalID = ""

    // MARK: Outputs

    /// Which screen of the flow is showing.
    public private(set) var phase: NafathPhase = .enterID
    /// `true` once Start has been pressed at least once.
    public private(set) var didAttemptSubmit = false
    /// `true` while `/verification/nafath/start` is in flight.
    public private(set) var isSubmitting = false
    /// The two-digit number to tap in the Nafath app, while ``phase`` is
    /// ``NafathPhase/waiting``.
    public private(set) var randomNumber = ""
    /// When the open request lapses.
    public private(set) var expiresAt: Date?
    /// The server's reason, when the request was rejected and it gave one.
    public private(set) var rejectionReason: String?
    /// The server's sentence for the under-age refusal.
    public private(set) var underAgeMessage = ""
    /// The server's complaint about the typed number, shown inline.
    private var serverIDError: String?
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: VerificationServiceProtocol
    private let analytics: AnalyticsClient
    private let pollInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async -> Void

    private var requestID: String?

    /// - Parameters:
    ///   - service: Verification backend.
    ///   - analytics: Event sink. Nothing tracked here ever carries the ID.
    ///   - pollInterval: Seconds between polls. Tests pass `0`.
    ///   - now: Clock, injectable so expiry is testable.
    ///   - sleeper: Waits between polls. Defaults to `Task.sleep`.
    public init(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient,
        pollInterval: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = Date.init,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.service = service
        self.analytics = analytics
        self.pollInterval = pollInterval
        self.now = now
        self.sleeper = sleeper
    }

    // MARK: Derived state

    /// Inline error under the ID field.
    public var idError: String? {
        if let serverIDError { return serverIDError }
        guard didAttemptSubmit else { return nil }
        return NationalID.isValid(nationalID) ? nil : L10n.t("verification.field.nationalId.error")
    }

    /// Whether the Start button is tappable.
    public var canSubmit: Bool {
        NationalID.isValid(nationalID) && !isSubmitting
    }

    // MARK: Actions

    /// Sends the number to `/verification/nafath/start`.
    ///
    /// On success the field is cleared — the ID's job is done and it is not
    /// kept around — and the phase moves to ``NafathPhase/waiting``.
    public func submit() async {
        didAttemptSubmit = true
        serverIDError = nil
        guard NationalID.isValid(nationalID), !isSubmitting else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let start = try await service.startNafath(nationalID: nationalID)
            // Sent once; gone. Nothing that outlives the request holds it.
            nationalID = ""
            requestID = start.requestId
            randomNumber = start.randomNumber
            expiresAt = start.expiresAt
            phase = .waiting
        } catch let error as APIError {
            handleStartFailure(error)
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
        }
    }

    /// Polls until a terminal state or expiry. Runs inside the screen's
    /// `.task`, so dismissing the screen cancels it.
    public func pollUntilDone() async {
        guard phase == .waiting, let requestID, let expiresAt else { return }

        while phase == .waiting, !Task.isCancelled {
            guard now() < expiresAt else {
                adoptExpired()
                return
            }

            await sleeper(pollInterval)
            guard phase == .waiting, !Task.isCancelled else { return }
            // The clock may have run out during the sleep; do not poll a
            // request the screen has already promised to treat as dead.
            guard now() < expiresAt else {
                adoptExpired()
                return
            }

            do {
                let poll = try await service.pollNafath(requestID: requestID)
                adopt(poll)
            } catch let error as APIError where error.code == .underMinimumAge {
                underAgeMessage = error.userMessage
                phase = .underAge
                analytics.track(.nafathRejected, properties: ["code": "under_minimum_age"])
            } catch {
                // A dropped poll is not an answer. The next tick retries, and
                // the expiry clock bounds how long that can go on.
                continue
            }
        }
    }

    /// Returns to the ID form after an expired or rejected request.
    public func startAgain() {
        phase = .enterID
        didAttemptSubmit = false
        serverIDError = nil
        requestID = nil
        randomNumber = ""
        expiresAt = nil
        rejectionReason = nil
    }

    // MARK: - Internals

    private func handleStartFailure(_ error: APIError) {
        switch error.code {
        case .alreadyVerified:
            // Not a failure: the account is already through the wall. The
            // approved screen's Continue is what refreshes the session.
            nationalID = ""
            phase = .approved
        case .invalidNationalId:
            serverIDError = error.userMessage
        case .identityAlreadyUsed:
            nationalID = ""
            phase = .identityUsed
        case .underMinimumAge:
            nationalID = ""
            underAgeMessage = error.userMessage
            phase = .underAge
            analytics.track(.nafathRejected, properties: ["code": "under_minimum_age"])
        default:
            toast = .error(error.userMessage)
        }
    }

    private func adopt(_ poll: NafathPoll) {
        switch poll.status {
        case .pending:
            break
        case .approved:
            phase = .approved
            analytics.track(.nafathApproved)
        case .rejected:
            rejectionReason = poll.rejectionReason
            phase = .rejected
            analytics.track(.nafathRejected)
        case .expired:
            adoptExpired()
        }
    }

    private func adoptExpired() {
        guard phase == .waiting else { return }
        phase = .expired
        analytics.track(.nafathExpired)
    }
}
