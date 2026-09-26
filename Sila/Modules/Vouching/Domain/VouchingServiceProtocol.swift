import Foundation

/// Everything vouching can ask the backend to do (contract v24).
///
/// Three callers, one seam: the **voucher** (a verified member) lists who
/// they stand behind, mints links and answers for them; the **person**
/// holding a link reads its landing, claims it and can take the tag off; and
/// anybody — a guest included — can read a link's landing.
///
/// **Privacy.** The details a voucher writes about somebody go out in
/// ``mintInvite(label:details:)`` and come back only on the voucher's own
/// list. The details a person gives in ``claim(token:details:)`` go out and
/// never come back at all. Implementations must not log them, and analytics
/// carry error codes only — never a name, a nationality or a date.
public protocol VouchingServiceProtocol: Sendable {

    // MARK: The voucher

    /// `GET /vouching` — whether the viewer may vouch and why not, their
    /// slots, every vouch they stand behind, the ended ones and open links.
    func overview() async throws -> VouchingOverview

    /// `POST /vouching/invites` — a single-use link, good for 72 hours,
    /// carrying who the voucher says the person is. All four attestations
    /// are sent as true: the screen does not call this until each box is
    /// ticked.
    /// - Throws: `403` with the ``VouchRefusal`` codes, `400
    ///   attestations_required`, `details_required`, `invalid_full_name`,
    ///   `invalid_country`, `invalid_date_of_birth`, `vouch_under_age`.
    func mintInvite(label: String?, details: VouchDetails) async throws -> MintedInvite

    /// `DELETE /vouching/invites/{id}` — burns an unclaimed link.
    func burnInvite(id: UUID) async throws

    /// `POST /vouching/vouches/{id}/confirm` — "Yes, that's who I meant."
    func confirm(vouchId: UUID) async throws -> Vouch

    /// `POST /vouching/vouches/{id}/decline` — "That's not who I meant."
    /// Never held against the voucher.
    func decline(vouchId: UUID) async throws -> Vouch

    /// `DELETE /vouching/vouches/{id}` — take the word back, at any time.
    func withdraw(vouchId: UUID) async throws -> Vouch

    /// `POST /vouching/vouches/{id}/answer` — the written answer to a
    /// moderator's finding: `reattest` or `withdraw`, 10–1000 characters.
    func answer(vouchId: UUID, action: VouchAnswer, statement: String) async throws -> Vouch

    // MARK: The link, for anybody

    /// `GET /public/vouch-invites/{token}` — no session needed.
    /// - Throws: `404 invite_unavailable`, one answer for every link that
    ///   cannot be used.
    func landing(token: String) async throws -> VouchInviteLanding

    // MARK: The person

    /// `POST /vouch/invites/{token}/claim` with the four promises (all true)
    /// and the person's own details.
    /// - Returns: The vouch, now waiting for the voucher to confirm.
    /// - Throws: ``APIError/detailsMismatch(fields:attemptsLeft:message:)``
    ///   naming which fields differ; `409 invite_closed` on the third; and
    ///   the claim's other refusals (`already_verified`, `already_vouched`,
    ///   `vouch_too_soon`, `vouch_lifetime_reached`, `vouch_not_eligible`,
    ///   `vouch_under_age`, `invite_unavailable`).
    func claim(token: String, details: VouchDetails) async throws -> VouchState?

    /// `GET /me/vouch` — standing, the vouch, and while vouched what it
    /// allows. Works from the wall.
    func myVouch() async throws -> MyVouch

    /// `DELETE /me/vouch` — take the tag off, or withdraw a pending claim.
    func removeMyVouch() async throws
}

/// The voucher's answer to a finding.
public enum VouchAnswer: String, Sendable, CaseIterable {
    /// "I know this person as I said."
    case reattest
    /// "I was wrong."
    case withdraw
}
