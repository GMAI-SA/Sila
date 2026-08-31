import Foundation
import Observation

/// Drives ``SuspensionScreen``.
///
/// The screen it drives is not an error screen, and this model is built so it
/// cannot become one. There is no generic failure path that ends in "Something
/// went wrong, try again": the only two endpoints that answer for a suspended
/// account are `GET /me/suspension` and `POST /me/appeal`, both are modelled
/// here, and everything else the app might have tried has already been routed
/// away from by ``SuspensionMonitor``.
///
/// Two behaviours are worth stating outright.
///
/// **`until == nil` means indefinite.** It does not mean "unknown" and it
/// certainly does not mean "today". A screen that rendered a missing date as a
/// blank line would leave somebody waiting for an expiry that is never coming.
///
/// **`409 already_appealed` is an answer, not a failure.** It says the thing the
/// person was trying to find out — their appeal is already in — so it lands as
/// the appealed state rather than as red text.
@MainActor
@Observable
public final class SuspensionViewModel {

    /// The record, once the server has described it.
    public private(set) var suspension: Suspension?
    /// `true` during the first load.
    public private(set) var isLoading = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the record could not be read.
    ///
    /// Only ever a transport problem: this endpoint answers while suspended, so
    /// a failure here means the network, not the state. The screen still renders
    /// — it already knows the account is suspended — and offers to look again.
    public private(set) var loadError: String?

    /// The appeal text, as typed.
    public var appealMessage = ""
    /// `true` while the appeal is being sent.
    public private(set) var isSubmittingAppeal = false
    /// Why the appeal was refused.
    public private(set) var appealError: String?

    /// Banner message.
    public var toast: SLToastMessage?

    private let service: SafetyServiceProtocol
    private let analytics: AnalyticsClient
    private let monitor: SuspensionMonitor?
    private let onSignOut: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - service: Safety backend.
    ///   - analytics: Event sink.
    ///   - monitor: Told what the server said, so a suspension that has been
    ///     lifted lets the person back into the app instead of stranding them
    ///     here until they reinstall.
    ///   - onSignOut: Ends the session.
    public init(
        service: SafetyServiceProtocol,
        analytics: AnalyticsClient,
        monitor: SuspensionMonitor? = nil,
        onSignOut: (@MainActor () -> Void)? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.monitor = monitor
        self.onSignOut = onSignOut
    }

    // MARK: - Derived state

    /// The server's own reason, or the sentence that admits there is none.
    ///
    /// Never invented. This is the only account somebody gets of what they are
    /// alleged to have done, and a plausible-sounding client-side guess would be
    /// a client-side accusation.
    public var reasonText: String {
        suspension?.reason ?? SafetyCopy.suspendedNoReason
    }

    /// `true` when the server gave a reason.
    public var hasServerReason: Bool { suspension?.reason != nil }

    /// When it lifts, said the way somebody would ask.
    public var expiryText: String {
        guard let suspension else { return SafetyCopy.suspendedIndefinite }
        guard let until = suspension.until else { return SafetyCopy.suspendedIndefinite }
        return "This suspension lifts on \(Self.dateFormatter.string(from: until))."
    }

    /// `true` when there is no end date.
    public var isIndefinite: Bool { suspension?.until == nil }

    /// The appeal already on file, or `nil`.
    public var appeal: SuspensionAppeal? { suspension?.appeal }

    /// `true` when the appeal form belongs on screen.
    ///
    /// One appeal per suspension, so the form is *replaced* by its receipt
    /// rather than left there disabled — a form that cannot be sent is an
    /// invitation to keep trying.
    public var showsAppealForm: Bool { appeal == nil }

    /// What the receipt says once an appeal is in.
    public func appealReceipt(now: Date = Date()) -> String {
        guard let appeal else { return SafetyCopy.appealSubmitted }
        guard let submitted = appeal.submittedAt else {
            return "\(appeal.status.label). \(SafetyCopy.appealSubmitted)"
        }
        _ = now
        return "Sent \(Self.dateFormatter.string(from: submitted)) — \(appeal.status.label). "
            + SafetyCopy.appealSubmitted
    }

    /// Whether the appeal may be sent.
    public var canSubmitAppeal: Bool {
        appealValidationError == nil && !isSubmittingAppeal && showsAppealForm
    }

    /// Why the appeal is not ready, or `nil`.
    public var appealValidationError: String? {
        let trimmed = appealMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > SafetyLimits.maximumAppealLength {
            return "Appeals are at most \(SafetyLimits.maximumAppealLength) characters."
        }
        if trimmed.count < SafetyLimits.minimumAppealLength {
            return "Say what you think happened — an empty appeal gives a reviewer nothing to weigh."
        }
        return nil
    }

    /// Characters left, which may be negative.
    public var appealRemaining: Int {
        SafetyLimits.maximumAppealLength
            - appealMessage.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    // MARK: - Loading

    /// Reads the record. Safe on every appearance.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Reads it unconditionally — the "check again" path.
    public func reload() async {
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let loaded = try await service.fetchSuspension()
            suspension = loaded
            // Told either way. `suspended: false` is how somebody whose
            // suspension expired, or whose appeal was upheld, gets back in.
            monitor?.adopt(loaded)
        } catch {
            // Not routed to itself: this endpoint answers *because* the account
            // is suspended, so a failure here is the network and nothing else.
            loadError = APIError.wrapping(error).userMessage
        }
    }

    // MARK: - Appealing

    /// Sends the one appeal this suspension allows.
    public func submitAppeal() async {
        guard canSubmitAppeal else { return }
        isSubmittingAppeal = true
        appealError = nil
        defer { isSubmittingAppeal = false }

        do {
            let receipt = try await service.submitAppeal(message: appealMessage)
            suspension = (suspension ?? Suspension(suspended: true)).adopting(receipt)
            appealMessage = ""
            analytics.track(.appealSubmitted)
            toast = .success("Your appeal is in. A human will read it.")
        } catch {
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .alreadyAppealed {
                // Not a failure: it is the answer to the question. An appeal
                // sent from another device, or a double tap, lands here — and
                // the honest response is to show the appeal, not red text.
                analytics.track(.appealAlreadyOnFile)
                suspension = (suspension ?? Suspension(suspended: true))
                    .adopting(SuspensionAppeal(submittedAt: nil, status: .pending))
                appealMessage = ""
                toast = .info("You had already appealed. That one still stands.")
                return
            }
            appealError = wrapped.userMessage
        }
    }

    /// Leaves the session.
    public func signOut() {
        onSignOut?()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
