import Foundation

// MARK: - Standing

/// Where an account stands on Sila (contract v24): its own proven identity,
/// a verified member's word, or neither.
///
/// Its own axis, never a value of ``VerificationStatus``: a vouched account's
/// `verification_status` is whatever the identity pipeline says — unstarted,
/// under review, even rejected for a refused document — and it still reaches
/// the feed. Routing reads this first.
public enum Standing: String, Codable, Equatable, Sendable, Hashable {
    /// Proved their own identity — the seal and the flag.
    case verified
    /// A verified member vouches they know this person. Never the seal.
    case vouched
    /// Neither. The wall. (`none` on the wire; not named so here, because
    /// `Standing?.none` would read as the optional's own `nil`.)
    case noStanding = "none"

    /// Unknown future values read as ``noStanding`` — the wall is the safe
    /// reading of a standing this build cannot name.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Standing(rawValue: raw) ?? .noStanding
    }
}

// MARK: - The tag

/// Who stands behind an account that has not verified its own identity —
/// `UserSummaryOut.vouched_by`, everywhere a person appears.
///
/// Drawn as the tag "vouched by @aziz · Saudi Arabia" and never together
/// with the seal or the flag. ``country`` is the nationality both sides gave
/// and matched: text beside the tag, never a flag, never `country_code`, and
/// it opens nothing.
public struct VouchedBy: Hashable, Sendable, Codable {

    public let id: UUID
    /// The voucher's handle, kept current by the server when they rename.
    public let handle: String
    public let displayName: String?
    /// When the vouch began.
    public let since: Date?
    /// ISO 3166-1 alpha-2, or `nil` for a vouch made before details were
    /// asked for (contract v24 §11).
    public let country: String?

    public init(id: UUID, handle: String, displayName: String? = nil, since: Date? = nil, country: String? = nil) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.since = since
        self.country = CountryCode.normalised(country)
    }

    private enum CodingKeys: String, CodingKey {
        case id, handle, displayName, since, country
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .id)) ?? ""
            id = UUID(uuidString: raw) ?? UUID()
        }
        handle = (try? container.decode(String.self, forKey: .handle)) ?? ""
        let name = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        displayName = (name?.isEmpty == false) ? name : nil
        since = (try? container.decodeIfPresent(Date.self, forKey: .since)) ?? nil
        // A code the client cannot name is dropped, like a flag it cannot
        // draw: the tag then reads "vouched by @aziz" and nothing is guessed.
        country = CountryCode.normalised((try? container.decodeIfPresent(String.self, forKey: .country)) ?? nil)
    }

    /// `"@aziz"`.
    public var atHandle: String { "@\(handle)" }

    /// The country as the tag writes it — its everyday name, in the
    /// interface's language: "Saudi Arabia" / "السعودية".
    public var countryName: String? { VouchCopy.countryName(country) }
}

// MARK: - The person's own vouch

/// `VouchStateOut` — the person's own pending-or-active vouch, on
/// `/auth/me` and `GET /me/vouch`. Never what the voucher wrote about them.
public struct VouchState: Equatable, Sendable, Codable, Hashable, Identifiable {

    /// Waiting for the voucher to confirm who claimed the link, or live.
    public enum Status: String, Codable, Sendable, Hashable {
        case pending
        case active
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    public let id: UUID
    public let status: Status
    /// The voucher, or `nil` once that account is gone.
    public let voucher: UserSummary?
    /// The voucher's handle as it was — survives the account.
    public let voucherHandle: String
    public let acceptedAt: Date?
    /// While pending: when the voucher's 48 hours run out.
    public let confirmBy: Date?
    public let confirmedAt: Date?
    /// While active: the end of the 30 days. No renewal.
    public let expiresAt: Date?

    public init(
        id: UUID,
        status: Status,
        voucher: UserSummary? = nil,
        voucherHandle: String,
        acceptedAt: Date? = nil,
        confirmBy: Date? = nil,
        confirmedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.voucher = voucher
        self.voucherHandle = voucherHandle
        self.acceptedAt = acceptedAt
        self.confirmBy = confirmBy
        self.confirmedAt = confirmedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, voucher, voucherHandle, acceptedAt, confirmBy, confirmedAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try VouchWire.uuid(container, .id)
        status = (try? container.decode(Status.self, forKey: .status)) ?? .unknown
        voucher = (try? container.decodeIfPresent(UserSummary.self, forKey: .voucher)) ?? nil
        voucherHandle = ((try? container.decodeIfPresent(String.self, forKey: .voucherHandle)) ?? nil)
            ?? voucher?.handle ?? ""
        acceptedAt = (try? container.decodeIfPresent(Date.self, forKey: .acceptedAt)) ?? nil
        confirmBy = (try? container.decodeIfPresent(Date.self, forKey: .confirmBy)) ?? nil
        confirmedAt = (try? container.decodeIfPresent(Date.self, forKey: .confirmedAt)) ?? nil
        expiresAt = (try? container.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }

    public var isPending: Bool { status == .pending }
    public var isActive: Bool { status == .active }

    /// `"@aziz"` — from the live account when there is one.
    public var atVoucher: String { "@\(voucher?.handle ?? voucherHandle)" }
}

/// What a vouched account may do, as the server states it (`rights` on
/// `GET /me/vouch`). Read, never re-derived: a key the server adds later is
/// kept, and one it does not send reads as the documented default.
public struct VouchRights: Equatable, Sendable, Decodable {

    public let values: [String: Bool]

    public init(values: [String: Bool]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        values = (try? decoder.singleValueContainer().decode([String: Bool].self)) ?? [:]
    }

    /// The contract's table (v24 §5), for a client that has not heard yet.
    public static let vouchedDefault = VouchRights(values: [
        "post_international": true, "reply_international": true, "post_country_or_region": false,
        "react": true, "repost": true, "bookmark": true, "follow": true, "join_open_communities": true,
        "join_verified_only_communities": false, "listen_in_rooms": true, "speak_in_rooms": false,
        "raise_hand": false, "host_rooms": false, "direct_messages": false, "vouch_for_others": false,
        "challenge_identities": false, "moderate": false, "seal_flag_or_verified_name": false,
        "ranked_and_trending": false,
    ])

    /// The order the "what you can do" list is drawn in.
    public static let displayOrder = [
        "post_international", "reply_international", "react", "repost", "bookmark", "follow",
        "join_open_communities", "listen_in_rooms", "post_country_or_region", "speak_in_rooms", "raise_hand",
        "host_rooms", "direct_messages", "join_verified_only_communities", "vouch_for_others",
        "challenge_identities", "moderate", "seal_flag_or_verified_name", "ranked_and_trending",
    ]

    /// Whether a right is granted. Absent means the documented default.
    public func allows(_ key: String) -> Bool {
        values[key] ?? Self.vouchedDefault.values[key] ?? false
    }

    public var directMessages: Bool { allows("direct_messages") }
    public var hostRooms: Bool { allows("host_rooms") }
    public var speakInRooms: Bool { allows("speak_in_rooms") }
    public var vouchForOthers: Bool { allows("vouch_for_others") }

    /// Every right the server named or the contract lists, in display order,
    /// then anything newer alphabetically.
    public var keys: [String] {
        let known = Self.displayOrder
        let extra = values.keys.filter { !known.contains($0) }.sorted()
        return known + extra
    }
}

/// The vouched account's rate limits (`limits` on `GET /me/vouch`).
public struct VouchLimits: Equatable, Sendable, Decodable {
    public let postsPerHour: Int
    public let postsPerDay: Int
    public let mentionsPerPost: Int
    public let followsPerHour: Int

    public init(postsPerHour: Int = 5, postsPerDay: Int = 20, mentionsPerPost: Int = 3, followsPerHour: Int = 20) {
        self.postsPerHour = postsPerHour
        self.postsPerDay = postsPerDay
        self.mentionsPerPost = mentionsPerPost
        self.followsPerHour = followsPerHour
    }

    private enum CodingKeys: String, CodingKey {
        case postsPerHour, postsPerDay, mentionsPerPost, followsPerHour
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VouchLimits()
        postsPerHour = (try? container.decode(Int.self, forKey: .postsPerHour)) ?? fallback.postsPerHour
        postsPerDay = (try? container.decode(Int.self, forKey: .postsPerDay)) ?? fallback.postsPerDay
        mentionsPerPost = (try? container.decode(Int.self, forKey: .mentionsPerPost)) ?? fallback.mentionsPerPost
        followsPerHour = (try? container.decode(Int.self, forKey: .followsPerHour)) ?? fallback.followsPerHour
    }
}

/// `GET /me/vouch` — works from the wall too.
public struct MyVouch: Equatable, Sendable, Decodable {
    public let standing: Standing
    public let vouch: VouchState?
    /// Only while vouched.
    public let rights: VouchRights?
    public let limits: VouchLimits?

    public init(standing: Standing, vouch: VouchState? = nil, rights: VouchRights? = nil, limits: VouchLimits? = nil) {
        self.standing = standing
        self.vouch = vouch
        self.rights = rights
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case standing, vouch, rights, limits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        standing = (try? container.decode(Standing.self, forKey: .standing)) ?? .noStanding
        vouch = (try? container.decodeIfPresent(VouchState.self, forKey: .vouch)) ?? nil
        rights = (try? container.decodeIfPresent(VouchRights.self, forKey: .rights)) ?? nil
        limits = (try? container.decodeIfPresent(VouchLimits.self, forKey: .limits)) ?? nil
    }
}

// MARK: - The details both sides give (contract v24 §11)

/// Who the person is: the voucher writes it on the link, the person gives it
/// again at the claim, and the two must match.
///
/// What the voucher wrote is the voucher's (and the moderators') only — it
/// comes back on the voucher's own list and nowhere else. The name is sent
/// exactly as typed: the server folds case, spaces, tashkeel and the letter
/// variants, so the client never normalises it.
public struct VouchDetails: Equatable, Sendable, Codable, Hashable {
    public var fullName: String
    /// ISO 3166-1 alpha-2.
    public var nationality: String
    /// `YYYY-MM-DD` — a day, never an instant (see ``ISODay``).
    public var dateOfBirth: String

    public init(fullName: String, nationality: String, dateOfBirth: String) {
        self.fullName = fullName
        self.nationality = nationality
        self.dateOfBirth = dateOfBirth
    }

    private enum CodingKeys: String, CodingKey {
        case fullName, nationality, dateOfBirth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullName = ((try? container.decodeIfPresent(String.self, forKey: .fullName)) ?? nil) ?? ""
        nationality = CountryCode.normalised((try? container.decodeIfPresent(String.self, forKey: .nationality)) ?? nil) ?? ""
        dateOfBirth = ISODay.normalised((try? container.decodeIfPresent(String.self, forKey: .dateOfBirth)) ?? nil) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fullName, forKey: .fullName)
        try container.encode(nationality.uppercased(), forKey: .nationality)
        try container.encode(dateOfBirth, forKey: .dateOfBirth)
    }
}

/// One of the three details, as a mismatch names it — which field, never
/// what the other side wrote in it. The server lists them in this order.
public enum VouchDetailField: String, Sendable, Hashable, CaseIterable, Identifiable {
    case fullName = "full_name"
    case nationality
    case dateOfBirth = "date_of_birth"

    public var id: String { rawValue }

    /// The field's name inside a sentence: "name", "date of birth".
    public var inSentence: String {
        switch self {
        case .fullName: return L10n.t("vouch.field.fullName")
        case .nationality: return L10n.t("vouch.field.nationality")
        case .dateOfBirth: return L10n.t("vouch.field.dateOfBirth")
        }
    }

    /// Reads the server's list, dropping anything this build cannot name and
    /// keeping the server's order.
    public static func parse(_ raw: [String]) -> [VouchDetailField] {
        let wanted = Set(raw)
        return allCases.filter { wanted.contains($0.rawValue) }
    }
}

// MARK: - Attestations

/// The voucher's four promises, each a box they tick. Recorded with the
/// terms version: a strike rests on exactly these words.
struct VoucherAttestations: Encodable, Equatable {
    var knowsPersonally: Bool
    var adult: Bool
    var realName: Bool
    var singleAccount: Bool
}

/// The person's four.
struct VoucheeAttestations: Encodable, Equatable {
    var adult: Bool
    var realName: Bool
    var singleAccount: Bool
    var terms: Bool
}

// MARK: - The voucher's side

/// `VouchOut` — one vouch as its voucher sees it: the person, where it
/// stands, what they wrote about them, and any question a moderator asked.
public struct Vouch: Identifiable, Equatable, Sendable, Decodable, Hashable {

    public enum Status: String, Decodable, Sendable, Hashable {
        /// Claimed; the voucher has 48 hours to confirm it is who they meant.
        case pending
        /// Live: the person carries the tag.
        case active
        /// The person verified their own identity.
        case graduated
        case ended
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    public let id: UUID
    public let status: Status
    /// Why it ended, as the server words it (`expired`, `withdrawn`, …).
    public let endReason: String?
    /// The person — `nil` once that account has gone, or when a block stands
    /// between the two (either way the handle snapshot stays).
    public let vouchee: UserSummary?
    public let voucheeHandle: String
    public let acceptedAt: Date?
    public let confirmBy: Date?
    public let confirmedAt: Date?
    public let expiresAt: Date?
    public let endedAt: Date?
    public let summons: VouchSummons?
    /// The voucher's private note.
    public let label: String?
    /// What the voucher wrote about the person, or `nil` for a vouch made
    /// before details were asked for.
    public let details: VouchDetails?

    public init(
        id: UUID,
        status: Status,
        endReason: String? = nil,
        vouchee: UserSummary? = nil,
        voucheeHandle: String,
        acceptedAt: Date? = nil,
        confirmBy: Date? = nil,
        confirmedAt: Date? = nil,
        expiresAt: Date? = nil,
        endedAt: Date? = nil,
        summons: VouchSummons? = nil,
        label: String? = nil,
        details: VouchDetails? = nil
    ) {
        self.id = id
        self.status = status
        self.endReason = endReason
        self.vouchee = vouchee
        self.voucheeHandle = voucheeHandle
        self.acceptedAt = acceptedAt
        self.confirmBy = confirmBy
        self.confirmedAt = confirmedAt
        self.expiresAt = expiresAt
        self.endedAt = endedAt
        self.summons = summons
        self.label = label
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, endReason, vouchee, voucheeHandle, acceptedAt, confirmBy, confirmedAt
        case expiresAt, endedAt, summons, label, details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try VouchWire.uuid(container, .id)
        status = (try? container.decode(Status.self, forKey: .status)) ?? .unknown
        endReason = VouchWire.text(container, .endReason)
        vouchee = (try? container.decodeIfPresent(UserSummary.self, forKey: .vouchee)) ?? nil
        voucheeHandle = VouchWire.text(container, .voucheeHandle) ?? vouchee?.handle ?? ""
        acceptedAt = (try? container.decodeIfPresent(Date.self, forKey: .acceptedAt)) ?? nil
        confirmBy = (try? container.decodeIfPresent(Date.self, forKey: .confirmBy)) ?? nil
        confirmedAt = (try? container.decodeIfPresent(Date.self, forKey: .confirmedAt)) ?? nil
        expiresAt = (try? container.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
        endedAt = (try? container.decodeIfPresent(Date.self, forKey: .endedAt)) ?? nil
        summons = (try? container.decodeIfPresent(VouchSummons.self, forKey: .summons)) ?? nil
        label = VouchWire.text(container, .label)
        let written = (try? container.decodeIfPresent(VouchDetails.self, forKey: .details)) ?? nil
        details = (written?.fullName.isEmpty == false) ? written : nil
    }

    /// `"@khalid"` — the live handle when the account is still there.
    public var atVouchee: String { "@\(vouchee?.handle ?? voucheeHandle)" }

    /// A moderator is waiting for the voucher's written answer.
    public var awaitsAnswer: Bool { summons?.isOpen() == true }
}

/// A moderator's finding, and the voucher's 48 hours to answer it.
public struct VouchSummons: Equatable, Sendable, Decodable, Hashable {
    /// The finding: `impostor`, `under_age`, `false_attestation`, `sold_link`.
    public let reason: String?
    public let summonedAt: Date?
    public let deadline: Date?
    /// `reattest` or `withdraw` once answered.
    public let answer: String?
    public let answeredAt: Date?

    public init(reason: String?, summonedAt: Date? = nil, deadline: Date? = nil, answer: String? = nil, answeredAt: Date? = nil) {
        self.reason = reason
        self.summonedAt = summonedAt
        self.deadline = deadline
        self.answer = answer
        self.answeredAt = answeredAt
    }

    private enum CodingKeys: String, CodingKey {
        case reason, summonedAt, deadline, answer, answeredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = VouchWire.text(container, .reason)
        summonedAt = (try? container.decodeIfPresent(Date.self, forKey: .summonedAt)) ?? nil
        deadline = (try? container.decodeIfPresent(Date.self, forKey: .deadline)) ?? nil
        answer = VouchWire.text(container, .answer)
        answeredAt = (try? container.decodeIfPresent(Date.self, forKey: .answeredAt)) ?? nil
    }

    /// Unanswered and still in time. The server has the last word on time;
    /// this only decides whether the answer form is drawn.
    public func isOpen(at now: Date = Date()) -> Bool {
        guard answer == nil else { return false }
        guard let deadline else { return true }
        return deadline > now
    }
}

/// `InviteOut` — one link as its voucher sees it.
public struct VouchInvite: Identifiable, Equatable, Sendable, Decodable, Hashable {

    public enum State: String, Decodable, Sendable, Hashable {
        case open, claimed, expired, revoked
        /// Three claims whose details did not match.
        case closed
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = State(rawValue: raw) ?? .unknown
        }
    }

    public let id: UUID
    public let label: String?
    public let state: State
    public let createdAt: Date?
    public let expiresAt: Date?
    public let claimedAt: Date?
    public let details: VouchDetails?
    /// How many claims have not matched so far; the third closes the link.
    public let mismatches: Int

    public init(
        id: UUID,
        label: String? = nil,
        state: State,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        claimedAt: Date? = nil,
        details: VouchDetails? = nil,
        mismatches: Int = 0
    ) {
        self.id = id
        self.label = label
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.claimedAt = claimedAt
        self.details = details
        self.mismatches = mismatches
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, state, createdAt, expiresAt, claimedAt, details, mismatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try VouchWire.uuid(container, .id)
        label = VouchWire.text(container, .label)
        state = (try? container.decode(State.self, forKey: .state)) ?? .unknown
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        expiresAt = (try? container.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
        claimedAt = (try? container.decodeIfPresent(Date.self, forKey: .claimedAt)) ?? nil
        let written = (try? container.decodeIfPresent(VouchDetails.self, forKey: .details)) ?? nil
        details = (written?.fullName.isEmpty == false) ? written : nil
        mismatches = max(0, (try? container.decode(Int.self, forKey: .mismatches)) ?? 0)
    }
}

/// Why the voucher cannot mint a link right now — `reason` on `GET /vouching`.
public struct VouchRefusal: Equatable, Sendable, Decodable, Hashable {
    public let code: String
    /// The server's sentence, shown as it is.
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case code, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decode(String.self, forKey: .code)) ?? ""
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
    }

    /// The flag is off for this account: the entry points are not drawn.
    public var isNotOpen: Bool { code == "vouching_not_open" }
}

/// The voucher's right to vouch. One strike ends it for good.
public struct VouchPrivilege: Equatable, Sendable, Decodable, Hashable {
    public let active: Bool
    /// `strike` (permanent), an older `strike_1` pause, or another word the
    /// server records.
    public let reason: String?
    /// `nil` beside a reason = permanent.
    public let until: Date?
    public let strikes: Int

    public init(active: Bool = true, reason: String? = nil, until: Date? = nil, strikes: Int = 0) {
        self.active = active
        self.reason = reason
        self.until = until
        self.strikes = strikes
    }

    private enum CodingKeys: String, CodingKey { case active, reason, until, strikes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = (try? container.decode(Bool.self, forKey: .active)) ?? true
        reason = VouchWire.text(container, .reason)
        until = (try? container.decodeIfPresent(Date.self, forKey: .until)) ?? nil
        strikes = max(0, (try? container.decode(Int.self, forKey: .strikes)) ?? 0)
    }
}

/// The numbers the voucher's screen states (`rules` on `GET /vouching`).
public struct VouchRules: Equatable, Sendable, Decodable, Hashable {
    public let vouchDays: Int
    public let inviteHours: Int
    public let confirmHours: Int
    public let voucherMinVerifiedDays: Int
    public let slotsFirst: Int
    public let slotsFull: Int

    public init(vouchDays: Int = 30, inviteHours: Int = 72, confirmHours: Int = 48,
                voucherMinVerifiedDays: Int = 30, slotsFirst: Int = 1, slotsFull: Int = 3) {
        self.vouchDays = vouchDays
        self.inviteHours = inviteHours
        self.confirmHours = confirmHours
        self.voucherMinVerifiedDays = voucherMinVerifiedDays
        self.slotsFirst = slotsFirst
        self.slotsFull = slotsFull
    }

    private enum CodingKeys: String, CodingKey {
        case vouchDays, inviteHours, confirmHours, voucherMinVerifiedDays, slotsFirst, slotsFull
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VouchRules()
        vouchDays = (try? container.decode(Int.self, forKey: .vouchDays)) ?? fallback.vouchDays
        inviteHours = (try? container.decode(Int.self, forKey: .inviteHours)) ?? fallback.inviteHours
        confirmHours = (try? container.decode(Int.self, forKey: .confirmHours)) ?? fallback.confirmHours
        voucherMinVerifiedDays = (try? container.decode(Int.self, forKey: .voucherMinVerifiedDays))
            ?? fallback.voucherMinVerifiedDays
        slotsFirst = (try? container.decode(Int.self, forKey: .slotsFirst)) ?? fallback.slotsFirst
        slotsFull = (try? container.decode(Int.self, forKey: .slotsFull)) ?? fallback.slotsFull
    }
}

/// How many people the voucher may stand behind now; an open link holds a
/// slot as a claimed vouch does.
public struct VouchSlots: Equatable, Sendable, Decodable, Hashable {
    public let total: Int
    public let used: Int
    public let available: Int

    public init(total: Int = 0, used: Int = 0, available: Int = 0) {
        self.total = total
        self.used = used
        self.available = available
    }

    private enum CodingKeys: String, CodingKey { case total, used, available }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = max(0, (try? container.decode(Int.self, forKey: .total)) ?? 0)
        used = max(0, (try? container.decode(Int.self, forKey: .used)) ?? 0)
        available = max(0, (try? container.decode(Int.self, forKey: .available)) ?? 0)
    }
}

/// `GET /vouching` — everything the voucher's screen is drawn from.
public struct VouchingOverview: Equatable, Sendable, Decodable {
    public let canVouch: Bool
    public let reason: VouchRefusal?
    public let slots: VouchSlots
    public let verifiedSince: Date?
    public let privilege: VouchPrivilege
    /// Pending (confirm these) and active.
    public let vouches: [Vouch]
    /// The newest 50 that ended.
    public let ended: [Vouch]
    /// Open links only.
    public let invites: [VouchInvite]
    public let rules: VouchRules

    public init(
        canVouch: Bool,
        reason: VouchRefusal? = nil,
        slots: VouchSlots = VouchSlots(),
        verifiedSince: Date? = nil,
        privilege: VouchPrivilege = VouchPrivilege(),
        vouches: [Vouch] = [],
        ended: [Vouch] = [],
        invites: [VouchInvite] = [],
        rules: VouchRules = VouchRules()
    ) {
        self.canVouch = canVouch
        self.reason = reason
        self.slots = slots
        self.verifiedSince = verifiedSince
        self.privilege = privilege
        self.vouches = vouches
        self.ended = ended
        self.invites = invites
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case canVouch, reason, slots, verifiedSince, privilege, vouches, ended, invites, rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canVouch = (try? container.decode(Bool.self, forKey: .canVouch)) ?? false
        reason = (try? container.decodeIfPresent(VouchRefusal.self, forKey: .reason)) ?? nil
        slots = (try? container.decode(VouchSlots.self, forKey: .slots)) ?? VouchSlots()
        verifiedSince = (try? container.decodeIfPresent(Date.self, forKey: .verifiedSince)) ?? nil
        privilege = (try? container.decode(VouchPrivilege.self, forKey: .privilege)) ?? VouchPrivilege()
        // Row by row: one unreadable vouch costs that row, not the list.
        vouches = VouchWire.rows(container, .vouches)
        ended = VouchWire.rows(container, .ended)
        invites = VouchWire.rows(container, .invites)
        rules = (try? container.decode(VouchRules.self, forKey: .rules)) ?? VouchRules()
    }

    /// Claims waiting for "that's who I meant", oldest window first.
    public var pending: [Vouch] {
        vouches.filter { $0.status == .pending }.sorted { ($0.confirmBy ?? .distantFuture) < ($1.confirmBy ?? .distantFuture) }
    }

    /// Live vouches.
    public var active: [Vouch] { vouches.filter { $0.status == .active } }

    /// The entry points are drawn only while vouching is open to this account.
    public var isOpen: Bool { reason?.isNotOpen != true }
}

/// `POST /vouching/invites` → `201`. The token is here and nowhere else,
/// ever: the share sheet opens with ``url`` at once.
public struct MintedInvite: Equatable, Sendable, Decodable {
    public let invite: VouchInvite
    public let url: URL

    public init(invite: VouchInvite, url: URL) {
        self.invite = invite
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case invite, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invite = try container.decode(VouchInvite.self, forKey: .invite)
        let raw = try container.decode(String.self, forKey: .url)
        guard let url = URL(string: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Not a URL: \(raw)")
        }
        self.url = url
    }
}

// MARK: - The link, for the person holding it

/// `GET /public/vouch-invites/{token}` — who is vouching, and until when the
/// link works. Never the voucher's note, never what they wrote.
public struct VouchInviteLanding: Equatable, Sendable, Decodable {
    public let voucher: UserSummary
    public let expiresAt: Date?

    public init(voucher: UserSummary, expiresAt: Date? = nil) {
        self.voucher = voucher
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case voucher, expiresAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voucher = try container.decode(UserSummary.self, forKey: .voucher)
        expiresAt = (try? container.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }
}

/// `POST /vouch/invites/{token}/claim` → `201 {"vouch": VouchStateOut}`.
struct VouchClaimResponse: Decodable {
    let vouch: VouchState?

    private enum CodingKeys: String, CodingKey { case vouch }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vouch = (try? container.decodeIfPresent(VouchState.self, forKey: .vouch)) ?? nil
    }
}

/// A vouch link the app is holding for somebody who has not claimed it yet
/// — through sign-up, the email code and a relaunch. The token is the link's
/// only content: it names nobody.
public struct PendingVouchInvite: Identifiable, Equatable, Sendable, Codable, Hashable {
    public let token: String
    public let receivedAt: Date

    public init(token: String, receivedAt: Date = Date()) {
        self.token = token
        self.receivedAt = receivedAt
    }

    public var id: String { token }

    /// Links work for 72 hours; one held longer is not worth offering.
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(receivedAt) > 72 * 3600
    }
}

// MARK: - Wire helpers

/// Tolerant decoding shared by the shapes above.
enum VouchWire {

    static func uuid<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> UUID {
        if let uuid = try? container.decode(UUID.self, forKey: key) { return uuid }
        let raw = (try? container.decode(String.self, forKey: key)) ?? ""
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "No id")
        }
        return uuid
    }

    static func text<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func rows<K: CodingKey, Row: Decodable>(_ container: KeyedDecodingContainer<K>, _ key: K) -> [Row] {
        ((try? container.decode([Failable<Row>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    struct Failable<Row: Decodable>: Decodable {
        let value: Row?
        init(from decoder: Decoder) throws { value = try? Row(from: decoder) }
    }
}
