import Foundation

/// Turns the server's rejection reason into something a person can read.
///
/// The routes produce a handful of machine reasons — `nationality_mismatch`,
/// `document_expired`, `under_minimum_age` — which have translations. A
/// reviewer's free-text reason is shown exactly as written, in whatever
/// language they wrote it.
public enum VerificationRejection {

    /// The sentence to show for `reason`, or `nil` when there is nothing.
    public static func display(_ reason: String?) -> String? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return nil
        }
        switch reason {
        case "nationality_mismatch": return L10n.t("auth.rejected.reason.nationalityMismatch")
        case "document_expired": return L10n.t("auth.rejected.reason.documentExpired")
        case "under_minimum_age": return L10n.t("auth.rejected.reason.underMinimumAge")
        case "verification_revoked": return L10n.t("auth.rejected.reason.verificationRevoked")
        default: return reason
        }
    }

    /// A badge a moderator withdrew — contested, never simply re-run.
    public static func isRevocation(_ reason: String?) -> Bool {
        reason == "verification_revoked"
    }

    /// Whether `reason` is one of the machine reasons rather than a
    /// reviewer's words — decides whether the text follows the interface
    /// language or its own.
    public static func isMachineReason(_ reason: String?) -> Bool {
        ["nationality_mismatch", "document_expired", "under_minimum_age", "verification_revoked"].contains(reason ?? "")
    }
}
