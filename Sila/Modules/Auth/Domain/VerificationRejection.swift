import Foundation

/// Turns the server's rejection reason into something a person can read.
///
/// The routes produce a handful of machine reasons — `nationality_mismatch`,
/// `document_expired`, `under_minimum_age` — which have translations. A
/// reviewer's free-text reason is shown exactly as written, in whatever
/// language they wrote it.
public enum VerificationRejection {

    /// The document pre-screen's four closed reasons (contract v25), in the
    /// order the server lets them win. The model on the host can only say no,
    /// and only when the pictures were unusable: each is fixed by sending
    /// better ones, so the way on is the camera again, not another route.
    public static let screeningReasons = ["not_a_document", "not_genuine", "unreadable_document", "no_face"]

    /// Every reason this build translates.
    private static let machineReasons = Set([
        "nationality_mismatch", "document_expired", "date_of_birth_mismatch", "under_minimum_age",
        "verification_revoked"
    ] + screeningReasons)

    /// The sentence to show for `reason`, or `nil` when there is nothing.
    public static func display(_ reason: String?) -> String? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return nil
        }
        switch reason {
        case "nationality_mismatch": return L10n.t("auth.rejected.reason.nationalityMismatch")
        case "document_expired": return L10n.t("auth.rejected.reason.documentExpired")
        case "date_of_birth_mismatch": return L10n.t("auth.rejected.reason.dateOfBirthMismatch")
        case "under_minimum_age": return L10n.t("auth.rejected.reason.underMinimumAge")
        case "verification_revoked": return L10n.t("auth.rejected.reason.verificationRevoked")
        case "not_a_document": return L10n.t("auth.rejected.reason.notADocument")
        case "unreadable_document": return L10n.t("auth.rejected.reason.unreadableDocument")
        case "not_genuine": return L10n.t("auth.rejected.reason.notGenuine")
        case "no_face": return L10n.t("auth.rejected.reason.noFace")
        default: return reason
        }
    }

    /// A badge a moderator withdrew — contested, never simply re-run.
    public static func isRevocation(_ reason: String?) -> Bool {
        reason == "verification_revoked"
    }

    /// Turned away by the pre-screen: the pictures could not be used, and new
    /// ones are the answer.
    public static func isScreening(_ reason: String?) -> Bool {
        screeningReasons.contains(reason ?? "")
    }

    /// What VoiceOver says the reason card is: the automatic check's reason
    /// for a pre-screen rejection (no reviewer saw it), the reviewer's own
    /// explanation for their free text, and neither for one of the app's
    /// coded reasons, which may be either's.
    public static func reasonHint(_ reason: String?) -> String {
        if isScreening(reason) { return L10n.t("auth.rejected.reason.hint.screening") }
        if isMachineReason(reason) { return L10n.t("auth.rejected.reason.hint.decision") }
        return L10n.t("auth.rejected.reason.hint")
    }

    /// Whether `reason` is one of the machine reasons rather than a
    /// reviewer's words — decides whether the text follows the interface
    /// language or its own.
    public static func isMachineReason(_ reason: String?) -> Bool {
        machineReasons.contains(reason ?? "")
    }
}
