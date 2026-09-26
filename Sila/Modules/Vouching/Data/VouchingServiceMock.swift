import Foundation

/// Scripted ``VouchingServiceProtocol`` for tests, previews and the mocked
/// launches (`-mockAuth`, `-mockVouchingScenario X`).
///
/// One link is always there to claim: ``openToken``, minted by @noura for
/// the person below. Its details are ``expectedDetails``; anything else is a
/// mismatch naming the fields that differ, and the third closes it — the
/// server's rules, played out without a server.
public actor VouchingServiceMock: VouchingServiceProtocol {

    /// The voucher's worlds.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Vouching is open: one claim waiting, one live, one ended, one link.
        case voucher
        /// The server's flag is off for this account — nothing is drawn.
        case notOpen
        /// One strike: the right to vouch has ended for good.
        case struck
        /// Open, but nobody yet.
        case empty
    }

    /// The link a claim can succeed on.
    public static let openToken = "mock-khalid-2026-link"
    /// What @noura wrote on it. A claim must give the same three.
    public static let expectedDetails = VouchDetails(fullName: "Khalid Al-Harbi", nationality: "SA", dateOfBirth: "1995-04-12")

    public static let voucher = UserSummary(
        id: UUID(uuidString: "44444444-0000-4000-8000-000000000001")!,
        handle: "noura", displayName: "Noura", isVerified: true, countryCode: "SA",
        verifiedSince: Date().addingTimeInterval(-86_400 * 200)
    )

    public private(set) var scenario: MockScenario
    private var overviewState: VouchingOverview
    private var mismatches = 0
    private var closed = false
    private var claimed: VouchState?
    /// The session's own vouch before any claim here — a mocked `vouched`
    /// or `vouchPending` launch — so `GET /me/vouch` agrees with `/auth/me`.
    private var own: (vouch: VouchState?, standing: Standing) = (nil, .noStanding)
    private let latency: Double

    /// Told when the person's own vouch changes — a claim, or the tag taken
    /// off — so the mocked `/auth/me` can say the same thing.
    private var onOwnVouchChange: (@Sendable (VouchState?, Standing) async -> Void)?

    /// Calls recorded for assertions: the route, never a detail.
    public private(set) var recordedCalls: [String] = []
    /// The details the last claim carried, so a test can check what was sent.
    public private(set) var lastClaimedDetails: VouchDetails?

    public init(scenario: MockScenario = .voucher, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
        self.overviewState = Self.overview(for: scenario)
    }

    public func setOnOwnVouchChange(_ handler: @escaping @Sendable (VouchState?, Standing) async -> Void) {
        onOwnVouchChange = handler
    }

    /// Starts the person's side where the mocked session already is.
    public func setOwnVouch(_ vouch: VouchState?, standing: Standing) {
        own = (vouch, standing)
    }

    // MARK: The voucher

    public func overview() async throws -> VouchingOverview {
        record("overview")
        try await delay()
        return overviewState
    }

    public func mintInvite(label: String?, details: VouchDetails) async throws -> MintedInvite {
        record("mintInvite")
        try await delay()
        guard overviewState.canVouch else {
            let refusal = overviewState.reason ?? VouchRefusal(code: "vouch_unavailable", message: "")
            throw APIError.api(code: APIErrorCode(serverCode: refusal.code), message: refusal.message, status: 403)
        }
        if details.fullName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw APIError.api(code: .detailsRequired, message: "Give their full name, nationality and date of birth", status: 400)
        }
        let invite = VouchInvite(
            id: UUID(), label: label, state: .open, createdAt: Date(),
            expiresAt: Date().addingTimeInterval(72 * 3_600), details: details
        )
        overviewState = replacing(overviewState, invites: [invite] + overviewState.invites, canVouch: false,
                                  reason: VouchRefusal(code: "vouch_rate_limited", message: "One vouch link a day — try again tomorrow"))
        return MintedInvite(invite: invite, url: URL(string: "https://sila.gmai.sa/vouch/mock-\(invite.id.uuidString.prefix(8).lowercased())")!)
    }

    public func burnInvite(id: UUID) async throws {
        record("burnInvite")
        try await delay()
        overviewState = replacing(overviewState, invites: overviewState.invites.filter { $0.id != id })
    }

    public func confirm(vouchId: UUID) async throws -> Vouch {
        record("confirm")
        try await delay()
        return try update(vouchId) { old in
            Vouch(id: old.id, status: .active, vouchee: old.vouchee, voucheeHandle: old.voucheeHandle,
                  acceptedAt: old.acceptedAt, confirmedAt: Date(), expiresAt: Date().addingTimeInterval(30 * 86_400),
                  label: old.label, details: old.details)
        }
    }

    public func decline(vouchId: UUID) async throws -> Vouch {
        record("decline")
        try await delay()
        return try update(vouchId) { old in
            Vouch(id: old.id, status: .ended, endReason: "declined", vouchee: old.vouchee, voucheeHandle: old.voucheeHandle,
                  acceptedAt: old.acceptedAt, endedAt: Date(), label: old.label, details: old.details)
        }
    }

    public func withdraw(vouchId: UUID) async throws -> Vouch {
        record("withdraw")
        try await delay()
        return try update(vouchId) { old in
            Vouch(id: old.id, status: .ended, endReason: old.status == .pending ? "declined" : "withdrawn",
                  vouchee: old.vouchee, voucheeHandle: old.voucheeHandle, acceptedAt: old.acceptedAt,
                  confirmedAt: old.confirmedAt, endedAt: Date(), label: old.label, details: old.details)
        }
    }

    public func answer(vouchId: UUID, action: VouchAnswer, statement: String) async throws -> Vouch {
        record("answer:\(action.rawValue)")
        try await delay()
        return try update(vouchId) { old in
            let summons = VouchSummons(reason: old.summons?.reason, summonedAt: old.summons?.summonedAt,
                                       deadline: old.summons?.deadline, answer: action.rawValue, answeredAt: Date())
            return Vouch(id: old.id, status: action == .withdraw ? .ended : old.status,
                         endReason: action == .withdraw ? "withdrawn" : old.endReason, vouchee: old.vouchee,
                         voucheeHandle: old.voucheeHandle, acceptedAt: old.acceptedAt, confirmedAt: old.confirmedAt,
                         expiresAt: old.expiresAt, endedAt: action == .withdraw ? Date() : old.endedAt,
                         summons: summons, label: old.label, details: old.details)
        }
    }

    // MARK: The link

    public func landing(token: String) async throws -> VouchInviteLanding {
        record("landing")
        try await delay()
        guard token == Self.openToken, !closed, claimed == nil else { throw Self.unavailable }
        return VouchInviteLanding(voucher: Self.voucher, expiresAt: Date().addingTimeInterval(60 * 3_600))
    }

    // MARK: The person

    public func claim(token: String, details: VouchDetails) async throws -> VouchState? {
        record("claim")
        lastClaimedDetails = details
        try await delay()
        guard token == Self.openToken, !closed, claimed == nil else { throw Self.unavailable }
        let expected = Self.expectedDetails
        var fields: [String] = []
        if Self.nameKey(details.fullName) != Self.nameKey(expected.fullName) { fields.append("full_name") }
        if details.nationality.uppercased() != expected.nationality { fields.append("nationality") }
        if details.dateOfBirth != expected.dateOfBirth { fields.append("date_of_birth") }
        guard fields.isEmpty else {
            mismatches += 1
            if mismatches >= 3 {
                closed = true
                throw APIError.api(code: .inviteClosed, message: "These details didn't match three times", status: 409)
            }
            throw APIError.detailsMismatch(fields: fields, attemptsLeft: 3 - mismatches,
                                           message: "Some of your details don't match")
        }
        let state = VouchState(
            id: UUID(), status: .pending, voucher: Self.voucher, voucherHandle: Self.voucher.handle,
            acceptedAt: Date(), confirmBy: Date().addingTimeInterval(48 * 3_600)
        )
        claimed = state
        await onOwnVouchChange?(state, .noStanding)
        return state
    }

    public func myVouch() async throws -> MyVouch {
        record("myVouch")
        try await delay()
        if let claimed { return MyVouch(standing: .noStanding, vouch: claimed) }
        let vouched = own.standing == .vouched
        return MyVouch(standing: own.standing, vouch: own.vouch,
                       rights: vouched ? .vouchedDefault : nil, limits: vouched ? VouchLimits() : nil)
    }

    public func removeMyVouch() async throws {
        record("removeMyVouch")
        try await delay()
        guard claimed != nil || own.vouch != nil else {
            throw APIError.api(code: .vouchNotFound, message: "You have no vouch", status: 404)
        }
        claimed = nil
        own = (nil, .noStanding)
        await onOwnVouchChange?(nil, .noStanding)
    }

    // MARK: - Internals

    private static let unavailable = APIError.api(code: .inviteUnavailable, message: "This vouch link can't be used", status: 404)

    /// Letters and digits only, lower-cased — enough of the server's folding
    /// for "Khalid  al-harbi" to match "Khalid Al-Harbi" in a demo.
    private static func nameKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private func update(_ id: UUID, _ change: (Vouch) -> Vouch) throws -> Vouch {
        let all = overviewState.vouches + overviewState.ended
        guard let old = all.first(where: { $0.id == id }) else {
            throw APIError.api(code: .vouchNotFound, message: "No such vouch", status: 404)
        }
        let new = change(old)
        let rest = all.filter { $0.id != id } + [new]
        let live = rest.filter { $0.status == .pending || $0.status == .active }
        let ended = rest.filter { $0.status != .pending && $0.status != .active }
        overviewState = replacing(overviewState, vouches: live, ended: ended)
        return new
    }

    private func replacing(
        _ old: VouchingOverview,
        vouches: [Vouch]? = nil,
        ended: [Vouch]? = nil,
        invites: [VouchInvite]? = nil,
        canVouch: Bool? = nil,
        reason: VouchRefusal? = nil
    ) -> VouchingOverview {
        VouchingOverview(
            canVouch: canVouch ?? old.canVouch, reason: canVouch == nil ? old.reason : reason,
            slots: old.slots, verifiedSince: old.verifiedSince, privilege: old.privilege,
            vouches: vouches ?? old.vouches, ended: ended ?? old.ended, invites: invites ?? old.invites, rules: old.rules
        )
    }

    private func record(_ call: String) { recordedCalls.append(call) }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    // MARK: - Worlds

    static let khalid = UserSummary(
        id: UUID(uuidString: "55555555-0000-4000-8000-000000000001")!,
        handle: "khalid", displayName: "Khalid", isVerified: false
    )
    static let omar = UserSummary(
        id: UUID(uuidString: "55555555-0000-4000-8000-000000000002")!,
        handle: "omar_h", displayName: "Omar", isVerified: false,
        vouchedBy: VouchedBy(id: UUID(), handle: "aziz", since: Date().addingTimeInterval(-86_400 * 7), country: "AE")
    )

    static func overview(for scenario: MockScenario) -> VouchingOverview {
        let now = Date()
        switch scenario {
        case .notOpen:
            return VouchingOverview(canVouch: false, reason: VouchRefusal(code: "vouching_not_open", message: "Vouching opens soon"))
        case .struck:
            return VouchingOverview(
                canVouch: false,
                reason: VouchRefusal(code: "vouch_privilege_revoked", message: "Your right to vouch has been withdrawn"),
                slots: VouchSlots(total: 3, used: 0, available: 0),
                verifiedSince: now.addingTimeInterval(-86_400 * 400),
                privilege: VouchPrivilege(active: false, reason: "strike", until: nil, strikes: 1),
                ended: [
                    Vouch(id: UUID(), status: .ended, endReason: "voucher_penalised", voucheeHandle: "someone",
                          acceptedAt: now.addingTimeInterval(-86_400 * 20), endedAt: now.addingTimeInterval(-86_400 * 2))
                ]
            )
        case .empty:
            return VouchingOverview(canVouch: true, slots: VouchSlots(total: 1, used: 0, available: 1),
                                    verifiedSince: now.addingTimeInterval(-86_400 * 90))
        case .voucher:
            return VouchingOverview(
                canVouch: false,
                reason: VouchRefusal(code: "vouch_slots_full", message: "You can stand behind 3 people at a time"),
                slots: VouchSlots(total: 3, used: 3, available: 0),
                verifiedSince: now.addingTimeInterval(-86_400 * 300),
                vouches: [
                    Vouch(id: UUID(uuidString: "66666666-0000-4000-8000-000000000001")!, status: .pending,
                          vouchee: khalid, voucheeHandle: "khalid", acceptedAt: now.addingTimeInterval(-3_600 * 5),
                          confirmBy: now.addingTimeInterval(3_600 * 43), label: "Khalid from work",
                          details: VouchDetails(fullName: "Khalid Al-Harbi", nationality: "SA", dateOfBirth: "1995-04-12")),
                    Vouch(id: UUID(uuidString: "66666666-0000-4000-8000-000000000002")!, status: .active,
                          vouchee: omar, voucheeHandle: "omar_h", acceptedAt: now.addingTimeInterval(-86_400 * 8),
                          confirmedAt: now.addingTimeInterval(-86_400 * 7), expiresAt: now.addingTimeInterval(86_400 * 23),
                          summons: VouchSummons(reason: "sold_link", summonedAt: now.addingTimeInterval(-3_600 * 2),
                                                deadline: now.addingTimeInterval(3_600 * 46)),
                          details: VouchDetails(fullName: "Omar Haddad", nationality: "AE", dateOfBirth: "1990-01-30")),
                ],
                ended: [
                    Vouch(id: UUID(uuidString: "66666666-0000-4000-8000-000000000003")!, status: .graduated,
                          endReason: "self_verified", voucheeHandle: "sara", acceptedAt: now.addingTimeInterval(-86_400 * 60),
                          confirmedAt: now.addingTimeInterval(-86_400 * 59), endedAt: now.addingTimeInterval(-86_400 * 40))
                ],
                invites: [
                    VouchInvite(id: UUID(uuidString: "77777777-0000-4000-8000-000000000001")!, label: "Cousin Faisal",
                                state: .open, createdAt: now.addingTimeInterval(-3_600 * 10),
                                expiresAt: now.addingTimeInterval(3_600 * 62),
                                details: VouchDetails(fullName: "Faisal Al-Otaibi", nationality: "SA", dateOfBirth: "2001-09-03"),
                                mismatches: 1)
                ]
            )
        }
    }
}
