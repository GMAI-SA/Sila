import Foundation

/// Every sentence vouching puts on screen, kept out of the views so each
/// one can be asserted.
///
/// Two rules hold throughout (contract v24 §1). "Verified" / "موثّق" is never
/// used for anything a vouch does — those words belong to the seal. And what
/// a voucher wrote about somebody is never repeated to that somebody: a
/// mismatch names *which* field, never the voucher's value.
public enum VouchCopy {

    // MARK: - The tag

    /// A country's everyday name in the interface language, as text — the
    /// tag's "Saudi Arabia" / "السعودية". Never a flag.
    public static func countryName(_ code: String?) -> String? {
        CountryCode.shortName(code, limit: .max) ?? CountryCode.name(code)
    }

    /// "vouched by @aziz · Saudi Arabia" / "بتزكية @aziz · السعودية".
    /// Never upper-cased, never cut down to the word alone.
    public static func tag(_ vouchedBy: VouchedBy) -> String {
        if let country = vouchedBy.countryName {
            return L10n.t("vouch.tag.withCountry", vouchedBy.handle, country)
        }
        return L10n.t("vouch.tag", vouchedBy.handle)
    }

    /// What VoiceOver says for the tag.
    public static func tagAccessibility(_ vouchedBy: VouchedBy) -> String {
        if let country = vouchedBy.countryName {
            return L10n.t("vouch.tag.a11y.withCountry", vouchedBy.handle, country)
        }
        return L10n.t("vouch.tag.a11y", vouchedBy.handle)
    }

    /// The profile's line where a verified name would be: "Not
    /// identity‑verified · vouched for by @aziz since 3 Sep".
    public static func profileRow(_ vouchedBy: VouchedBy) -> String {
        guard let since = vouchedBy.since else { return L10n.t("vouch.profile.row.noDate", vouchedBy.handle) }
        return L10n.t("vouch.profile.row", vouchedBy.handle, SLFormat.dayAndMonth(since))
    }

    /// The explainer anybody else reads on a tap.
    public static func explainer(voucher: String, person: String) -> String {
        L10n.t("vouch.explainer.body", voucher, person)
    }

    /// "Make it your own", on the person's own tag.
    public static func makeItYourOwn(voucher: String) -> String {
        L10n.t("vouch.own.body", voucher)
    }

    // MARK: - Mismatch

    /// "These don't match what @aziz entered: name, date of birth" — the
    /// fields, in the server's order, and nothing the voucher wrote.
    public static func mismatch(voucher: String, fields: [VouchDetailField]) -> String {
        let names = fields.map(\.inSentence).joined(separator: L10n.t("vouch.field.separator"))
        return L10n.t("vouch.claim.mismatch", voucher, names)
    }

    /// "2 tries left".
    public static func attemptsLeft(_ count: Int) -> String {
        L10n.plural("vouch.claim.attemptsLeft", max(0, count))
    }

    // MARK: - Time

    /// Whole days until `date`, rounded up — "23 days left", and "less than
    /// a day" rather than "0 days" on the last one.
    public static func daysLeft(until date: Date, now: Date = Date()) -> Int {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.up))
    }

    public static func daysLeftText(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 86_400 { return L10n.t("vouch.daysLeft.lastDay") }
        return L10n.plural("vouch.daysLeft", daysLeft(until: date, now: now))
    }

    /// Whole hours until `date`, rounded up, for the 48-hour windows.
    public static func hoursLeftText(until date: Date, now: Date = Date()) -> String {
        let hours = Int((max(0, date.timeIntervalSince(now)) / 3_600).rounded(.up))
        return L10n.plural("vouch.hoursLeft", hours)
    }

    // MARK: - Endings and findings

    /// Why a vouch ended, in words, for the voucher's list and the rows.
    public static func endReason(_ reason: String?) -> String {
        switch reason ?? "" {
        case "self_verified": return L10n.t("vouch.end.selfVerified")
        case "expired": return L10n.t("vouch.end.expired")
        case "unconfirmed": return L10n.t("vouch.end.unconfirmed")
        case "withdrawn": return L10n.t("vouch.end.withdrawn")
        case "removed": return L10n.t("vouch.end.removed")
        case "declined": return L10n.t("vouch.end.declined")
        case "voucher_left": return L10n.t("vouch.end.voucherLeft")
        case "vouchee_left": return L10n.t("vouch.end.voucheeLeft")
        case "voucher_penalised": return L10n.t("vouch.end.voucherPenalised")
        case "impostor": return L10n.t("vouch.end.impostor")
        case "under_age": return L10n.t("vouch.end.underAge")
        case "false_attestation": return L10n.t("vouch.end.falseAttestation")
        case "sold_link": return L10n.t("vouch.end.soldLink")
        case "verification_refused": return L10n.t("vouch.end.verificationRefused")
        case "voucher_unverified": return L10n.t("vouch.end.voucherUnverified")
        case "voucher_suspended": return L10n.t("vouch.end.voucherSuspended")
        default: return L10n.t("vouch.end.other")
        }
    }

    /// What the wall says about a vouch that ended (contract v24 §15): that
    /// the vouch from @aziz ended, one plain sentence why, and what is left.
    public struct LastEndedCopy: Equatable, Sendable {
        public let title: String
        public let reason: String
        public let next: String
    }

    /// Endings about the voucher, not the person: they can no longer vouch
    /// for anyone.
    private static let voucherEndings: Set<String> = [
        "voucher_left", "voucher_penalised", "voucher_unverified", "voucher_suspended",
    ]
    /// What a moderator may find — said as that and no more.
    private static let findings: Set<String> = ["impostor", "under_age", "false_attestation", "sold_link"]

    /// The card's three lines, in the reader's language only, with the same
    /// words as the web. A sentence that names the voucher needs their
    /// handle; without one it is only an ending. `vouch_again` null means
    /// another voucher may vouch today; any refusal (the fortnight's wait,
    /// the lifetime two, a finding) leaves verification as the way on.
    public static func lastEnded(_ ended: LastEndedVouch) -> LastEndedCopy {
        let handle = ended.handle ?? ""
        let named = !handle.isEmpty
        let reason: String
        switch ended.endReason ?? "" {
        case "declined": reason = named ? L10n.t("vouch.ended.reason.declined", handle) : L10n.t("vouch.ended.reason.other")
        case "unconfirmed": reason = named ? L10n.t("vouch.ended.reason.unconfirmed", handle) : L10n.t("vouch.ended.reason.other")
        case "expired": reason = L10n.t("vouch.ended.reason.expired")
        case "withdrawn": reason = named ? L10n.t("vouch.ended.reason.withdrawn", handle) : L10n.t("vouch.ended.reason.other")
        case "removed": reason = L10n.t("vouch.ended.reason.removed")
        case let code where voucherEndings.contains(code):
            reason = named ? L10n.t("vouch.ended.reason.voucher", handle) : L10n.t("vouch.ended.reason.other")
        case let code where findings.contains(code): reason = L10n.t("vouch.ended.reason.moderator")
        default: reason = L10n.t("vouch.ended.reason.other")
        }
        return LastEndedCopy(
            title: named ? L10n.t("vouch.ended.title", handle) : L10n.t("vouch.ended.title.plain"),
            reason: reason,
            next: ended.vouchAgain == nil ? L10n.t("vouch.ended.next.again") : L10n.t("vouch.ended.next.verify")
        )
    }

    /// What a moderator found, for the summons.
    public static func finding(_ reason: String?) -> String {
        switch reason ?? "" {
        case "impostor": return L10n.t("vouch.finding.impostor")
        case "under_age": return L10n.t("vouch.finding.underAge")
        case "false_attestation": return L10n.t("vouch.finding.falseAttestation")
        case "sold_link": return L10n.t("vouch.finding.soldLink")
        default: return L10n.t("vouch.end.other")
        }
    }

    // MARK: - Refusals

    /// Why the voucher cannot mint a link, in the reader's language. The
    /// server's own sentence is English only, so each code this build knows
    /// is said here — with the dates and numbers the overview carries — and
    /// only an unknown one falls back to the server's words.
    public static func refusal(_ refusal: VouchRefusal, in overview: VouchingOverview? = nil) -> String {
        switch refusal.code {
        case "vouching_not_open": return L10n.t("vouch.refusal.notOpen")
        case "self_verification_required": return L10n.t("vouch.refusal.selfVerify")
        case "vouch_unavailable": return L10n.t("vouch.refusal.unavailable")
        case "unverified": return L10n.t("vouch.refusal.unverified")
        case "vouch_privilege_revoked":
            if let until = overview?.privilege.until {
                return L10n.t("vouch.refusal.paused", SLFormat.date(until))
            }
            return L10n.t("vouch.refusal.revoked")
        case "vouch_too_new":
            let days = overview?.rules.voucherMinVerifiedDays ?? VouchRules().voucherMinVerifiedDays
            if let since = overview?.verifiedSince,
               let ready = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: since) {
                return L10n.t("vouch.refusal.tooNew", SLFormat.number(days), SLFormat.date(ready))
            }
            return L10n.t("vouch.refusal.tooNew.plain", SLFormat.number(days))
        case "vouch_slots_full":
            let rules = overview?.rules ?? VouchRules()
            if let total = overview?.slots.total, total <= rules.slotsFirst {
                return L10n.t("vouch.refusal.firstSlot")
            }
            return L10n.plural("vouch.refusal.slotsFull", overview?.slots.total ?? rules.slotsFull)
        case "vouch_rate_limited": return L10n.t("vouch.refusal.rateLimited")
        default: return refusal.message.isEmpty ? L10n.t("vouch.refusal.unavailable") : refusal.message
        }
    }
}
