import Foundation

/// The report form's contents, and the rules that decide whether it can be sent.
///
/// A value type rather than three properties on a view model, so the validation
/// is one testable rule instead of a condition spread across a sheet. The rules
/// are deliberately the client's own as well as the server's: `invalid_reason`
/// is unreachable from a picker built out of ``ReportReason``, so the work left
/// for this type is stopping the two reports a reviewer cannot act on — one with
/// no reason at all, and one that says "something else" and nothing more.
public struct ReportDraft: Equatable, Sendable {

    /// What is being reported. Fixed for the life of the form.
    public let subject: ReportSubject
    /// The chosen reason, or `nil` until one is picked.
    public var reason: ReportReason?
    /// Free text, as typed.
    public var detail: String

    public init(subject: ReportSubject, reason: ReportReason? = nil, detail: String = "") {
        self.subject = subject
        self.reason = reason
        self.detail = detail
    }

    /// The detail as it would be sent: trimmed, and `nil` when there is nothing
    /// left. A `detail` of three spaces is not a description of anything.
    public var normalisedDetail: String? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `true` when the chosen reason cannot be reviewed without words.
    public var requiresDetail: Bool { reason?.requiresDetail == true }

    /// Characters left, which may be negative.
    public var detailRemaining: Int {
        SafetyLimits.maximumDetailLength
            - detail.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Why the report cannot be sent yet, or `nil` when it can.
    ///
    /// Written as a sentence that says what to do next, not as a scold: somebody
    /// filling this in is usually already upset.
    public var validationError: String? {
        guard let reason else {
            return "Choose what is wrong with this first."
        }
        let trimmed = normalisedDetail ?? ""
        if trimmed.count > SafetyLimits.maximumDetailLength {
            return "Reports are at most \(SafetyLimits.maximumDetailLength) characters. "
                + "Say the most important part."
        }
        if reason.requiresDetail, trimmed.count < SafetyLimits.minimumOtherDetailLength {
            return "\"\(reason.title)\" needs a line explaining what is wrong — "
                + "on its own there is nothing for a reviewer to act on."
        }
        return nil
    }

    /// `true` when the submit button may do anything.
    public var isSubmittable: Bool { validationError == nil }

    /// The body to send. `nil` when ``isSubmittable`` is `false`, so an invalid
    /// draft cannot be turned into a request by accident.
    public var request: ReportRequest? {
        guard let reason, isSubmittable else { return nil }
        return ReportRequest(subject: subject, reason: reason, detail: normalisedDetail)
    }
}

/// What the report sheet shows once the server has answered.
///
/// The distinction is the whole point of the type. A `support` object means the
/// server decided this person needs help rather than a reference number, and
/// answering that with "Thanks, we'll review this" would be the wrong reply to
/// somebody who has just told Sila they are frightened for a friend.
public enum ReportOutcome: Equatable, Sendable {

    /// An ordinary receipt: filed, and it will be read.
    case received(ReportReceipt)
    /// Resources first. Carries the server's own, when it sent any.
    case support(SupportResources?, ReportReceipt)

    /// Chooses the outcome for a receipt.
    ///
    /// **Two triggers, and either is enough.** The server's `support` object is
    /// the authority, and the reason is a backstop: if a deployment ever forgets
    /// to attach resources to a `self_harm` report, this client still must not
    /// answer somebody's report of a friend in danger with a filing reference.
    /// Being over-careful here costs a screen nobody needed; being under-careful
    /// costs something else entirely.
    /// - Parameters:
    ///   - receipt: What `POST /reports` answered.
    ///   - reason: The reason that was sent.
    public static func make(receipt: ReportReceipt, reason: ReportReason) -> ReportOutcome {
        if let support = receipt.support {
            return .support(support, receipt)
        }
        if reason.isCareFirst {
            return .support(nil, receipt)
        }
        return .received(receipt)
    }

    /// `true` when this outcome leads with help rather than with a receipt.
    public var isSupport: Bool {
        if case .support = self { return true }
        return false
    }

    /// The receipt, whichever outcome this is.
    public var receipt: ReportReceipt {
        switch self {
        case let .received(receipt): return receipt
        case let .support(_, receipt): return receipt
        }
    }

    /// The server's resources, when there are any worth drawing.
    public var resources: SupportResources? {
        guard case let .support(resources, _) = self else { return nil }
        guard let resources, !resources.isEmpty else { return nil }
        return resources
    }

    /// `true` when a plain success toast would be an acceptable way to end the
    /// flow. Never for a care-first outcome — that one is a screen, and closing
    /// it is the user's decision rather than a three-second timer's.
    public var mayCloseWithToast: Bool { !isSupport }
}
