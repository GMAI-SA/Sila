import Foundation
import Observation

/// How far through the report the user is.
public enum ReportStage: Equatable, Sendable {
    /// Picking a reason, and optionally writing a line.
    case form
    /// The server has answered — with a receipt, or with help.
    case finished(ReportOutcome)
}

/// Drives ``ReportSheet``.
///
/// The whole model exists to keep one distinction honest: **a report of
/// self-harm is not a moderation request.** Somebody filing it is usually trying
/// to keep a person alive, not to get a post taken down, and answering them with
/// "Thanks, we'll review this" — or worse, with a toast that disappears after
/// three seconds — is the wrong reply to what they just did. When the server
/// attaches a `support` object the sheet leads with it, stays on screen until
/// it is dismissed deliberately, and offers the two follow-up actions as a
/// choice rather than a next step.
@MainActor
@Observable
public final class ReportViewModel {

    /// The form's contents and the rules that gate it.
    public var draft: ReportDraft

    /// Where the flow is.
    public private(set) var stage: ReportStage = .form

    /// `true` while the report is in flight.
    public private(set) var isSubmitting = false

    /// Why the last attempt failed, when it did.
    public private(set) var submissionError: String?

    private let service: SafetyServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let onClose: (@MainActor () -> Void)?
    private let onBlock: (@MainActor (SafetyTarget) -> Void)?
    private let onMute: (@MainActor (SafetyTarget) -> Void)?

    /// - Parameters:
    ///   - subject: The post or the account being reported.
    ///   - service: Safety backend.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    ///   - onClose: Dismisses the sheet.
    ///   - onBlock: Starts a block — through the same confirmation gate as
    ///     everywhere else, never straight to the endpoint.
    ///   - onMute: Mutes, in one tap.
    public init(
        subject: ReportSubject,
        service: SafetyServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        onClose: (@MainActor () -> Void)? = nil,
        onBlock: (@MainActor (SafetyTarget) -> Void)? = nil,
        onMute: (@MainActor (SafetyTarget) -> Void)? = nil
    ) {
        self.draft = ReportDraft(subject: subject)
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
        self.onClose = onClose
        self.onBlock = onBlock
        self.onMute = onMute
    }

    // MARK: - Derived state

    /// What is being reported.
    public var subject: ReportSubject { draft.subject }

    /// Who it is about.
    public var target: SafetyTarget { draft.subject.target }

    /// Every reason, in the order the picker shows them.
    public var reasons: [ReportReason] { ReportReason.allCases }

    /// The chosen reason, or `nil`.
    public var reason: ReportReason? { draft.reason }

    /// Why the report cannot be sent yet, or `nil`.
    ///
    /// Shown only once something has been picked, so an untouched form is not
    /// already telling the user off.
    public var validationError: String? {
        draft.reason == nil ? nil : draft.validationError
    }

    /// Why the submit button is inert, whether or not it is shown yet.
    public var blockingReason: String? { draft.validationError }

    /// `true` when the submit button may do anything.
    public var canSubmit: Bool { draft.isSubmittable && !isSubmitting }

    /// `true` when the chosen reason needs words of its own.
    public var requiresDetail: Bool { draft.requiresDetail }

    /// Characters left in the detail box.
    public var detailRemaining: Int { draft.detailRemaining }

    /// The outcome, once there is one.
    public var outcome: ReportOutcome? {
        guard case let .finished(outcome) = stage else { return nil }
        return outcome
    }

    /// `true` when the sheet is showing help rather than a receipt.
    public var isShowingSupport: Bool { outcome?.isSupport == true }

    /// `true` when this sheet is still a form.
    public var isEditing: Bool { stage == .form }

    // MARK: - Editing

    /// Picks a reason. Selecting the same one again clears it, so a mis-tap is
    /// undoable without hunting for a "none" row.
    public func select(_ reason: ReportReason) {
        if draft.reason == reason {
            draft.reason = nil
            return
        }
        draft.reason = reason
        analytics.track(.reportReasonSelected, properties: ["reason": reason.rawValue])
    }

    // MARK: - Submitting

    /// Sends the report and decides what to show.
    public func submit() async {
        guard canSubmit, let request = draft.request, let reason = draft.reason else { return }
        isSubmitting = true
        submissionError = nil
        defer { isSubmitting = false }

        do {
            let receipt = try await service.submitReport(request)
            let outcome = ReportOutcome.make(receipt: receipt, reason: reason)
            stage = .finished(outcome)
            if outcome.isSupport {
                analytics.track(.reportSupportShown, properties: [
                    "reason": reason.rawValue,
                    // Records whether the *server* supplied resources, so a
                    // deployment that stops attaching them is visible rather
                    // than silently falling back to this client's fixed words.
                    "server_supplied": String(receipt.support != nil)
                ])
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            let wrapped = APIError.wrapping(error)
            submissionError = wrapped.userMessage
            analytics.track(.reportFailed, properties: [
                "reason": reason.rawValue,
                "code": wrapped.code?.rawValue ?? "transport"
            ])
        }
    }

    // MARK: - Finishing

    /// Closes the sheet.
    public func close() {
        onClose?()
    }

    /// Starts a block from the outcome screen — through the confirmation, like
    /// everywhere else.
    public func blockFromOutcome() {
        onBlock?(target)
    }

    /// Mutes from the outcome screen.
    public func muteFromOutcome() {
        onMute?(target)
        onClose?()
    }
}
