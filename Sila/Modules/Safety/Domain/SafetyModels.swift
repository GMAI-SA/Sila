import Foundation

// MARK: - Who an action is about

/// The account a block, a mute or a report is aimed at.
///
/// Carries the display name as well as the handle because every sentence this
/// module puts in front of a user names the person: "Block Yuki Tanaka?" is a
/// question somebody can answer, and "Block @yuki_t?" is a string they have to
/// decode first. The handle is what goes on the wire; the name is what goes on
/// the screen.
public struct SafetyTarget: Equatable, Sendable, Hashable, Identifiable {

    /// The handle, normalised the way the server matches it — no `@`, lowercase.
    public let handle: String
    /// The name to put in a sentence. Falls back to the handle.
    public let name: String

    /// Identity is the handle: two references to the same person are the same
    /// dialog, whatever name each one was built from.
    public var id: String { handle }

    /// - Parameters:
    ///   - handle: Any casing, with or without an `@`.
    ///   - name: The display name, or `nil` to use the handle.
    public init(handle: String, name: String? = nil) {
        let normalised = Handle.normalised(handle)
        self.handle = normalised
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? "@\(normalised)" : trimmed
    }

    /// Builds a target from the ``UserSummary`` a post or a search result carries.
    public init(user: UserSummary) {
        self.init(handle: user.handle, name: user.displayName)
    }

    /// Builds a target from a loaded profile.
    public init(profile: Profile) {
        self.init(handle: profile.handle, name: profile.displayName)
    }

    /// The handle as it is rendered, with the `@`.
    public var atHandle: String { "@\(handle)" }

    /// `true` when the handle survived normalisation as something the server
    /// could match. An empty one is refused before a request is built.
    public var isAddressable: Bool { !Handle.pathComponent(handle).isEmpty }
}

/// One person on the blocked or muted list, with when it happened if the server
/// said.
///
/// The account is a ``UserSummary`` — the *same* value the feed renders next to
/// a post — rather than a parallel "blocked person" type, for the same reason
/// ``Profile`` reuses it: two types for one person is two places the checkmark
/// can disagree with itself.
public struct SafetyRelation: Equatable, Sendable, Identifiable {

    /// The account.
    public let user: UserSummary
    /// When the block or mute was stored, or `nil` when the server did not say.
    public let createdAt: Date?

    public init(user: UserSummary, createdAt: Date? = nil) {
        self.user = user
        self.createdAt = createdAt
    }

    /// Identity is the account's id, so a re-fetch is the same row.
    public var id: UUID { user.id }

    /// The target this row acts on.
    public var target: SafetyTarget { SafetyTarget(user: user) }
}

extension SafetyRelation: Decodable {

    private enum CodingKeys: String, CodingKey {
        case user, account, createdAt, blockedAt, mutedAt
    }

    /// Tolerant decoder for a row that may or may not be wrapped.
    ///
    /// `GET /me/blocks` and `GET /me/mutes` are specified only as "who I
    /// blocked" / "who I muted", so this accepts both shapes a backend
    /// reasonably produces: a bare user object, or a row that wraps one under
    /// `user` (or `account`) alongside a timestamp. Guessing wrong here would
    /// empty a safety list, which is the one list that must not silently lie.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.user) || container.contains(.account) {
            let wrapped = (try? container.decode(UserSummary.self, forKey: .user))
                ?? (try? container.decode(UserSummary.self, forKey: .account))
            guard let wrapped else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "A safety row wrapped no readable account."
                    )
                )
            }
            user = wrapped
            // Written as a loop rather than a chain of `try? … ?? try? …`:
            // that chain is trivial to read and, at four links, takes the type
            // checker longer than it is willing to spend.
            var timestamp: Date?
            for key in [CodingKeys.createdAt, .blockedAt, .mutedAt] {
                if let found = try? container.decodeIfPresent(Date.self, forKey: key) {
                    timestamp = found
                    break
                }
            }
            createdAt = timestamp
            return
        }
        user = try UserSummary(from: decoder)
        createdAt = nil
    }
}

/// A list of blocked or muted accounts, however the server chose to wrap it.
///
/// Accepts a bare array, or an object holding the array under any of the names a
/// backend plausibly picks. The alternative — assuming one shape — turns a
/// naming difference into a screen that says "you have blocked nobody" to
/// somebody who has.
public struct SafetyRelationList: Decodable, Equatable, Sendable {

    /// The rows, in server order.
    public let relations: [SafetyRelation]

    public init(relations: [SafetyRelation]) {
        self.relations = relations
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Names an array of accounts might travel under. `users` first because it
    /// is the shape the rest of this contract uses.
    static let arrayKeys = ["users", "blocks", "mutes", "blocked", "muted", "items", "results", "data"]

    public init(from decoder: Decoder) throws {
        if let bare = try? [SafetyRelation](from: decoder) {
            relations = bare
            return
        }
        let container = try decoder.container(keyedBy: AnyKey.self)
        for name in Self.arrayKeys {
            guard let key = AnyKey(stringValue: name), container.contains(key) else { continue }
            if let rows = try? container.decode([SafetyRelation].self, forKey: key) {
                relations = rows
                return
            }
        }
        relations = []
    }
}

// MARK: - Reports

/// What a report says is wrong.
///
/// The raw values are the server's, exactly. ``selfHarm`` is not just another
/// row in a list: it is the one reason where the person filing the report is
/// usually trying to *help* somebody rather than remove them, and the whole
/// outcome screen changes for it — see ``ReportOutcome``.
public enum ReportReason: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    case spam
    case harassment
    case hateSpeech = "hate_speech"
    case violence
    case sexualContent = "sexual_content"
    case selfHarm = "self_harm"
    case impersonation
    case illegal
    case other

    public var id: String { rawValue }

    /// The row's label in the picker.
    public var title: String {
        switch self {
        case .spam: return L10n.t("safety.reason.spam.title")
        case .harassment: return L10n.t("safety.reason.harassment.title")
        case .hateSpeech: return L10n.t("safety.reason.hateSpeech.title")
        case .violence: return L10n.t("safety.reason.violence.title")
        case .sexualContent: return L10n.t("safety.reason.sexualContent.title")
        case .selfHarm: return L10n.t("safety.reason.selfHarm.title")
        case .impersonation: return L10n.t("safety.reason.impersonation.title")
        case .illegal: return L10n.t("safety.reason.illegal.title")
        case .other: return L10n.t("safety.reason.other.title")
        }
    }

    /// One line under the label, so the picker is a decision rather than a
    /// vocabulary quiz. Two people reading "harassment" differently is how a
    /// moderation queue fills with reports nobody can action.
    public var detail: String {
        switch self {
        case .spam:
            return L10n.t("safety.reason.spam.detail")
        case .harassment:
            return L10n.t("safety.reason.harassment.detail")
        case .hateSpeech:
            return L10n.t("safety.reason.hateSpeech.detail")
        case .violence:
            return L10n.t("safety.reason.violence.detail")
        case .sexualContent:
            return L10n.t("safety.reason.sexualContent.detail")
        case .selfHarm:
            return L10n.t("safety.reason.selfHarm.detail")
        case .impersonation:
            return L10n.t("safety.reason.impersonation.detail")
        case .illegal:
            return L10n.t("safety.reason.illegal.detail")
        case .other:
            return L10n.t("safety.reason.other.detail")
        }
    }

    /// SF Symbol shown beside the label.
    public var icon: String {
        switch self {
        case .spam: return "tray.full"
        case .harassment: return "person.2.slash"
        case .hateSpeech: return "exclamationmark.bubble"
        case .violence: return "exclamationmark.triangle"
        case .sexualContent: return "eye.slash"
        case .selfHarm: return "heart.text.square"
        case .impersonation: return "person.crop.circle.badge.questionmark"
        case .illegal: return "shield.lefthalf.filled.slash"
        case .other: return "ellipsis.bubble"
        }
    }

    /// `true` when a report is unusable without words of its own.
    ///
    /// Only ``other``. Every other reason names a category a reviewer can act
    /// on; "something else" with nothing after it names nothing at all.
    public var requiresDetail: Bool { self == .other }

    /// `true` when this reason is about somebody's safety rather than about
    /// content that should come down.
    public var isCareFirst: Bool { self == .selfHarm }
}

/// Client-side limits for the report form.
public enum SafetyLimits {
    /// The most a `detail` may carry. Mirrored client-side so an essay is
    /// refused before it is sent, not after.
    public static let maximumDetailLength = 1_000
    /// The least ``ReportReason/other`` may carry. Below this it is not a
    /// description of anything.
    public static let minimumOtherDetailLength = 10
    /// The most an appeal message may carry.
    public static let maximumAppealLength = 2_000
    /// The least an appeal may carry — an empty appeal is not an appeal.
    public static let minimumAppealLength = 20
}

/// What a report is about: one post, or one account.
///
/// The contract takes exactly one of `post_id` or `user_handle`, so this is an
/// enum rather than two optional fields — a body carrying both, or neither, is
/// not representable.
public enum ReportSubject: Equatable, Sendable, Hashable {

    /// A single post, and enough about it to say what is being reported.
    case post(id: UUID, author: SafetyTarget, excerpt: String)
    /// A whole account.
    case account(SafetyTarget)

    /// The account behind the report, either way.
    public var target: SafetyTarget {
        switch self {
        case let .post(_, author, _): return author
        case let .account(target): return target
        }
    }

    /// The post being reported, when it is a post.
    public var postId: UUID? {
        switch self {
        case let .post(id, _, _): return id
        case .account: return nil
        }
    }

    /// What the sheet says it is reporting.
    public var headline: String {
        switch self {
        case let .post(_, author, _): return L10n.t("safety.report.headline.post", author.name)
        case let .account(target): return L10n.t("safety.report.headline.account", target.name)
        }
    }

    /// The quoted post text, when there is one.
    public var excerpt: String? {
        switch self {
        case let .post(_, _, excerpt): return excerpt.isEmpty ? nil : excerpt
        case .account: return nil
        }
    }

    /// Builds the subject for a post.
    public init(post: Post) {
        self = .post(
            id: post.id,
            author: SafetyTarget(user: post.author),
            excerpt: post.text
        )
    }
}

/// The `POST /reports` body.
///
/// Exactly one of ``postId`` and ``userHandle`` is ever set; the synthesised
/// encoder omits the `nil`, and ``JSONCoding/encoder`` converts the names to
/// `post_id` / `user_handle`.
public struct ReportRequest: Encodable, Equatable, Sendable {

    /// The reported post, or `nil` when an account is being reported.
    public let postId: UUID?
    /// The reported account's handle, or `nil` when a post is being reported.
    public let userHandle: String?
    /// Why.
    public let reason: ReportReason
    /// Free text, or `nil` when there is none. Never an empty string: a blank
    /// `detail` on the wire is noise a reviewer has to read past.
    public let detail: String?

    public init(postId: UUID? = nil, userHandle: String? = nil, reason: ReportReason, detail: String? = nil) {
        self.postId = postId
        self.userHandle = userHandle
        self.reason = reason
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.detail = trimmed.isEmpty ? nil : trimmed
    }

    /// Builds the body for a subject.
    public init(subject: ReportSubject, reason: ReportReason, detail: String?) {
        switch subject {
        case let .post(id, _, _):
            self.init(postId: id, userHandle: nil, reason: reason, detail: detail)
        case let .account(target):
            self.init(postId: nil, userHandle: target.handle, reason: reason, detail: detail)
        }
    }
}

/// One thing somebody can call, open or read, as the server described it.
///
/// The wire shape is `{"label": …, "value": …}` — a caption and one string that
/// may be a phone number, a URL or a plain sentence. The server does not say
/// which, so ``classify(_:)`` decides, and it decides *conservatively*: anything
/// it cannot confidently read as a number or a link stays plain text. Guessing
/// wrong in the other direction would put a `tel:` link on a sentence, and on
/// this screen a control that dials the wrong thing is worse than no control.
public struct SupportResource: Decodable, Equatable, Sendable, Identifiable {

    /// What it is called — the wire's `label`.
    public let name: String
    /// A line of plain text about it, when `value` was not a number or a link.
    public let detail: String?
    /// A number to call, as text.
    ///
    /// Never re-formatted, never re-grouped: a helpline number is not somewhere
    /// a client should be creative.
    public let phone: String?
    /// A page to open.
    public let url: URL?

    public var id: String { [name, phone ?? "", url?.absoluteString ?? "", detail ?? ""].joined(separator: "|") }

    public init(name: String, detail: String? = nil, phone: String? = nil, url: URL? = nil) {
        self.name = name
        self.detail = detail
        self.phone = phone
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case label, value
        // Tolerated alternatives. The contract settled on `label`/`value`; these
        // cost nothing and mean a backend that names a field the obvious way
        // still renders rather than vanishing off a screen somebody opened
        // because they were frightened.
        case name, title, detail, description, text, phone, telephone, number, url, link
    }

    /// Decodes `{label, value}`, a richer object, or a bare string.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let line = try? single.decode(String.self) {
            self.init(name: line)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedName = Self.first(in: container, keys: [.label, .name, .title]) ?? ""
        guard !resolvedName.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A support resource carried no label."
                )
            )
        }

        // Explicit fields win when a backend sends them; `value` is sorted out
        // by shape when it does not.
        var resolvedDetail = Self.first(in: container, keys: [.detail, .description, .text])
        var resolvedPhone = Self.first(in: container, keys: [.phone, .telephone, .number])
        var resolvedURL = Self.first(in: container, keys: [.url, .link]).flatMap { URL(string: $0) }

        if let value = Self.first(in: container, keys: [.value]) {
            switch Self.classify(value) {
            case .link(let link):
                resolvedURL = resolvedURL ?? link
            case .telephone(let number):
                resolvedPhone = resolvedPhone ?? number
            case .plain(let line):
                resolvedDetail = resolvedDetail ?? line
            }
        }

        self.init(
            name: resolvedName,
            detail: resolvedDetail,
            phone: resolvedPhone,
            url: resolvedURL
        )
    }

    /// What a bare `value` string turns out to be.
    enum Kind: Equatable {
        case link(URL)
        case telephone(String)
        case plain(String)
    }

    /// Reads a `value` string as a link, a number, or neither.
    ///
    /// The phone test is deliberately strict — mostly digits, few enough of them
    /// to be a number and not a sentence — because the cost of a false positive
    /// is a dial button that does nothing useful in an emergency.
    static func classify(_ raw: String) -> Kind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
           let link = URL(string: trimmed) {
            return .link(link)
        }
        if trimmed.lowercased().hasPrefix("tel:") {
            return .telephone(String(trimmed.dropFirst(4)))
        }
        let digits = trimmed.filter(\.isNumber)
        let allowed = CharacterSet(charactersIn: "+()- .")
        let others = trimmed.filter { character in
            !character.isNumber && !character.unicodeScalars.allSatisfy(allowed.contains)
        }
        if others.isEmpty, (3...20).contains(digits.count) {
            return .telephone(trimmed)
        }
        return .plain(trimmed)
    }

    private static func first(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            let decoded = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            guard let value = decoded else { continue }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }
}

/// The `support` object `POST /reports` may attach to its answer.
///
/// Its presence — not its contents, and not the reason that was picked — is what
/// turns the outcome screen from a receipt into a page of help. The server
/// decides when somebody needs that; the client's job is to render it whole
/// rather than summarise it.
public struct SupportResources: Decodable, Equatable, Sendable {

    /// A heading, when the server supplied one.
    public let title: String?
    /// The body text, rendered verbatim.
    public let message: String?
    /// Things to call, message or read.
    public let resources: [SupportResource]

    public init(title: String? = nil, message: String? = nil, resources: [SupportResource] = []) {
        self.title = title
        self.message = message
        self.resources = resources
    }

    /// `true` when there is genuinely nothing to draw.
    ///
    /// Not the same as "no support object": an empty object still means the
    /// server decided this needed care, and ``ReportOutcome`` still shows the
    /// care screen. This only decides whether a resource list is rendered.
    public var isEmpty: Bool {
        (title?.isEmpty ?? true) && (message?.isEmpty ?? true) && resources.isEmpty
    }

    /// The wire sends `headline`, `body` and `resources`. The rest are tolerated
    /// alternatives, for the same reason ``SupportResource`` tolerates some: this
    /// is the one screen that must not come up blank because a field was renamed.
    private enum CodingKeys: String, CodingKey {
        case headline, body, resources
        case title, heading, message, text, lines, items, helplines
    }

    public init(from decoder: Decoder) throws {
        if let bare = try? [SupportResource](from: decoder) {
            self.init(resources: bare)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var rows: [SupportResource] = []
        for key in [CodingKeys.resources, .lines, .items, .helplines] {
            let decoded = (try? container.decodeIfPresent([SupportResource].self, forKey: key)) ?? nil
            if let decoded {
                rows = decoded
                break
            }
        }
        self.init(
            title: Self.first(in: container, keys: [.headline, .title, .heading]),
            message: Self.first(in: container, keys: [.body, .message, .text]),
            resources: rows
        )
    }

    private static func first(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            let decoded = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            guard let value = decoded else { continue }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }
}

/// What `POST /reports` answers: `{id, status, support}`.
public struct ReportReceipt: Decodable, Equatable, Sendable, Identifiable {

    /// The report's id, as the server spells it. A string rather than a `UUID`
    /// because the contract only promises an id, and a reference number nobody
    /// can quote is not a receipt.
    public let id: String
    /// `"open"` on creation.
    public let status: String
    /// Present when the server decided this report needs a page of help rather
    /// than a receipt. `nil` otherwise.
    public let support: SupportResources?

    public init(id: String, status: String = "open", support: SupportResources? = nil) {
        self.id = id
        self.status = status
        self.support = support
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, support
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? container.decode(String.self, forKey: .id) {
            id = raw
        } else if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid.uuidString.lowercased()
        } else if let number = try? container.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = ""
        }
        status = (try? container.decode(String.self, forKey: .status)) ?? "open"
        support = (try? container.decodeIfPresent(SupportResources.self, forKey: .support)) ?? nil
    }
}

/// One row of `GET /me/reports` — a receipt for something already filed.
public struct Report: Decodable, Equatable, Sendable, Identifiable {

    public let id: String
    /// `open`, `reviewed`, `actioned`, `dismissed` — rendered as the server
    /// spells it, capitalised. The client does not own this vocabulary and must
    /// not translate a status it has not been told the meaning of.
    public let status: String
    /// The reason picked, when the server echoes it.
    public let reason: ReportReason?
    /// When it was filed.
    public let createdAt: Date?
    /// The reported post, when it was a post.
    public let postId: UUID?
    /// The reported account's handle, when it was an account.
    public let userHandle: String?

    public init(
        id: String,
        status: String = "open",
        reason: ReportReason? = nil,
        createdAt: Date? = nil,
        postId: UUID? = nil,
        userHandle: String? = nil
    ) {
        self.id = id
        self.status = status
        self.reason = reason
        self.createdAt = createdAt
        self.postId = postId
        self.userHandle = userHandle
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, reason, createdAt, postId, userHandle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? container.decode(String.self, forKey: .id) {
            id = raw
        } else if let number = try? container.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = UUID().uuidString.lowercased()
        }
        status = (try? container.decode(String.self, forKey: .status)) ?? "open"
        // An unrecognised reason reads as `nil` rather than failing the row: a
        // reason this build has never heard of is still a report the user filed
        // and is owed a receipt for.
        reason = ((try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil)
            .flatMap { ReportReason(rawValue: $0) }
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        if let raw = (try? container.decodeIfPresent(String.self, forKey: .postId)) ?? nil {
            postId = UUID(uuidString: raw)
        } else {
            postId = (try? container.decodeIfPresent(UUID.self, forKey: .postId)) ?? nil
        }
        let handle = (try? container.decodeIfPresent(String.self, forKey: .userHandle)) ?? nil
        userHandle = (handle?.isEmpty == false) ? Handle.normalised(handle ?? "") : nil
    }

    /// What the receipt says it was about.
    public var subjectDescription: String {
        if postId != nil { return L10n.t("safety.report.subject.post") }
        if let userHandle { return "@\(userHandle)" }
        return L10n.t("safety.report.subject.report")
    }

    /// The status with a capital letter, for a badge.
    public var statusLabel: String {
        guard let first = status.first else { return L10n.t("safety.report.status.open") }
        // The server's own word, capitalised. Not translated: a status this
        // client does not recognise is still the server's statement about the
        // report, and inventing an Arabic equivalent for a value we cannot
        // enumerate would put a word in the reviewer's mouth.
        return String(first).uppercased() + status.dropFirst()
    }
}

/// A list of reports, wrapped or bare — same reasoning as ``SafetyRelationList``.
public struct ReportList: Decodable, Equatable, Sendable {

    public let reports: [Report]

    public init(reports: [Report]) {
        self.reports = reports
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        if let bare = try? [Report](from: decoder) {
            reports = bare
            return
        }
        let container = try decoder.container(keyedBy: AnyKey.self)
        for name in ["reports", "items", "results", "data"] {
            guard let key = AnyKey(stringValue: name), container.contains(key) else { continue }
            if let rows = try? container.decode([Report].self, forKey: key) {
                reports = rows
                return
            }
        }
        reports = []
    }
}

/// What the server answers when a block or a mute is written.
///
/// Both verbs are idempotent and the contract does not pin the response body
/// down, so this reads whichever flag is there and the caller falls back to the
/// state it asked for. That fallback is honest rather than optimistic: the call
/// returned 2xx, and an idempotent write that succeeded leaves exactly the state
/// that was requested.
struct SafetyToggleResponse: Decodable {
    let blocked: Bool?
    let muted: Bool?

    /// The state after the call, given what was asked for.
    func state(requested: Bool) -> Bool {
        blocked ?? muted ?? requested
    }
}

// MARK: - The block gate

/// The confirmation in front of a block.
///
/// A value type rather than a pair of view flags, for the same reason
/// ``DeletionConfirmation`` is one: this is the barrier in front of an action
/// that severs two follows in both directions and cannot be undone by
/// unblocking, and it should not be possible to weaken it by editing a
/// `.disabled(…)` modifier.
///
/// Unlike deletion, nothing has to be *typed*. A block is recoverable in the
/// sense that it can be lifted, and demanding a password to stop seeing
/// somebody would put a toll booth in front of a safety tool. What it does
/// require is that the consequences were on screen first.
public struct BlockConfirmation: Equatable, Sendable, Identifiable {

    /// Who would be blocked.
    public let target: SafetyTarget
    /// Where the block was started from, so the right screen can react.
    public let origin: Origin

    /// Where a block was requested.
    public enum Origin: String, Equatable, Sendable {
        /// The `…` menu on a post card.
        case post
        /// The `…` menu on a profile header.
        case profile
        /// A row on the blocked list, or the report sheet's follow-up.
        case list
    }

    public var id: String { target.handle }

    public init(target: SafetyTarget, origin: Origin = .post) {
        self.target = target
        self.origin = origin
    }

    /// The question at the top of the dialog.
    public var title: String { L10n.t("safety.block.confirm.title", target.name) }

    /// The consequences, in the order they matter. Held here rather than in the
    /// view so a test can prove all four are said.
    public var consequences: [String] { SafetyCopy.blockConsequences(for: target) }

    /// The label on the button that does it.
    public var confirmTitle: String { L10n.t("safety.action.block") }
}

// MARK: - Suspension

/// How an appeal is going.
///
/// Unknown values decode as ``unknown`` and render as the server's own word
/// rather than failing the screen — this is the one screen a suspended account
/// can reach, and it does not get to be unreachable because a status string
/// changed.
public enum AppealStatus: String, Sendable, Equatable, Hashable {
    case pending
    case reviewing
    case upheld
    case rejected
    case unknown

    public init(serverValue: String) {
        switch serverValue.lowercased() {
        case "pending", "open", "submitted": self = .pending
        case "reviewing", "in_review", "under_review": self = .reviewing
        case "upheld", "accepted", "approved", "granted": self = .upheld
        case "rejected", "denied", "declined": self = .rejected
        default: self = .unknown
        }
    }

    /// What the screen says about it.
    public var label: String {
        switch self {
        case .pending: return L10n.t("safety.appeal.status.pending")
        case .reviewing: return L10n.t("safety.appeal.status.reviewing")
        case .upheld: return L10n.t("safety.appeal.status.upheld")
        case .rejected: return L10n.t("safety.appeal.status.rejected")
        case .unknown: return L10n.t("safety.appeal.status.unknown")
        }
    }
}

/// An appeal that has already been sent.
public struct SuspensionAppeal: Decodable, Equatable, Sendable {

    /// When it was sent, or `nil` when the server did not say.
    public let submittedAt: Date?
    /// Where it has got to.
    public let status: AppealStatus

    public init(submittedAt: Date? = nil, status: AppealStatus = .pending) {
        self.submittedAt = submittedAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case submittedAt, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        submittedAt = (try? container.decodeIfPresent(Date.self, forKey: .submittedAt)) ?? nil
        status = AppealStatus(
            serverValue: ((try? container.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? "pending"
        )
    }
}

/// What `GET /me/suspension` holds.
///
/// Reachable **while suspended** — it is one of only two endpoints that are —
/// which is what lets the suspension screen be a screen rather than a guess
/// assembled from an error message.
public struct Suspension: Decodable, Equatable, Sendable {

    /// Whether the account is suspended at all.
    public let suspended: Bool
    /// The server's own statement of why, rendered verbatim.
    ///
    /// Never paraphrased and never replaced with a friendlier sentence: this is
    /// the only account somebody gets of what they are alleged to have done, and
    /// a client-side reword is a client-side accusation.
    public let reason: String?
    /// When it lifts. **`nil` means indefinite** — not "unknown", and not
    /// "today". The screen says so in as many words.
    public let until: Date?
    /// The appeal already on file, or `nil` when none has been sent.
    public let appeal: SuspensionAppeal?

    public init(
        suspended: Bool,
        reason: String? = nil,
        until: Date? = nil,
        appeal: SuspensionAppeal? = nil
    ) {
        self.suspended = suspended
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reason = trimmed.isEmpty ? nil : trimmed
        self.until = until
        self.appeal = appeal
    }

    private enum CodingKeys: String, CodingKey {
        case suspended, reason, until, appeal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Defaults to `true`: this endpoint is only ever read because something
        // already said the account was suspended, and a malformed body must not
        // quietly hand somebody back an app the server will refuse anyway.
        suspended = (try? container.decode(Bool.self, forKey: .suspended)) ?? true
        let rawReason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        reason = (rawReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? rawReason
            : nil
        until = (try? container.decodeIfPresent(Date.self, forKey: .until)) ?? nil
        appeal = (try? container.decodeIfPresent(SuspensionAppeal.self, forKey: .appeal)) ?? nil
    }

    /// `true` when the suspension has no end date.
    public var isIndefinite: Bool { until == nil }

    /// `true` when an appeal has already been used up. One per suspension.
    public var hasAppealed: Bool { appeal != nil }

    /// A copy carrying an appeal that was just accepted.
    public func adopting(_ appeal: SuspensionAppeal) -> Suspension {
        Suspension(suspended: suspended, reason: reason, until: until, appeal: appeal)
    }

    /// A suspension with an appeal already on file, for previews and fixtures.
    public static func appealed(_ suspension: Suspension) -> Suspension {
        suspension.adopting(SuspensionAppeal(submittedAt: Date(), status: .pending))
    }
}

/// The `POST /me/appeal` body.
public struct AppealRequest: Encodable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Where the user should be

/// The surface the app should be showing, as far as safety is concerned.
///
/// A suspension is a **state**, not a failure: the credentials are good, the
/// server is working, and there is one screen — and one form — that can change
/// anything. Rendering `403 account_suspended` as an error alert with a Retry
/// button would loop somebody through the same 403 forever while the only
/// action that helps stayed off screen. Exactly the reasoning behind
/// ``AccountRoute/recovery``, applied to the other 403 the platform can answer.
public enum SafetyRoute: Equatable, Sendable {
    /// Nothing is wrong; the app renders normally.
    case normal
    /// The account is suspended. Only the suspension screen is reachable.
    case suspended
}

/// Decides between the app and the suspension screen.
public enum SafetyRouting {

    /// The route implied by a failed call — **any** call.
    /// - Parameter error: Anything a service can throw.
    /// - Returns: ``SafetyRoute/suspended`` for `account_suspended`; `nil` when
    ///   the error is an ordinary failure the screen should report itself.
    public static func route(forError error: Error) -> SafetyRoute? {
        guard APIError.wrapping(error).code == .accountSuspended else { return nil }
        return .suspended
    }

    /// The route implied by a loaded suspension record.
    public static func route(for suspension: Suspension) -> SafetyRoute {
        suspension.suspended ? .suspended : .normal
    }
}

// MARK: - Copy

/// Every sentence the safety surface says, in one place so it can be asserted.
///
/// Three rules run through all of it.
///
/// **Block, mute and report are three different weights.** Block confirms first
/// and names what it destroys. Mute is one tap and says so. Report asks what is
/// wrong before it does anything.
///
/// **Nothing here says or implies the other person was told.** They are not, by
/// any of the three, and a UI that hedged on that would make a safety tool
/// something people are afraid to use.
///
/// **Nothing here promises an outcome.** "Reviewed" is a promise Sila can keep;
/// "removed" is not.
public enum SafetyCopy {

    // MARK: Block

    /// The four things a block does, said before it is done.
    ///
    /// All four, in this order, every time: the visibility change, the follows
    /// it severs *in both directions*, the fact that unblocking does not put
    /// them back, and the silence. A confirmation that omits the third is asking
    /// for consent to something it has not described.
    public static func blockConsequences(for target: SafetyTarget) -> [String] {
        [
            L10n.t("safety.block.consequence.visibility", target.name),
            L10n.t("safety.block.consequence.follows"),
            L10n.t("safety.block.consequence.notRestored"),
            L10n.t("safety.block.consequence.silent", target.name)
        ]
    }

    /// The line under the confirmation's buttons.
    public static var blockReversible: String { L10n.t("safety.block.reversible") }

    /// The toast after a block.
    public static func blocked(_ target: SafetyTarget) -> String {
        L10n.t("safety.block.toast", target.name)
    }

    /// The toast after an unblock. Says what did **not** come back, because the
    /// alternative is somebody assuming their follow was restored and quietly
    /// losing an account they cared about.
    public static func unblocked(_ target: SafetyTarget) -> String {
        L10n.t("safety.unblock.toast", target.name)
    }

    // MARK: Mute

    /// The one line that has to be next to every mute control.
    public static var muteIsSilent: String { L10n.t("safety.mute.isSilent") }

    /// What muting actually does, for the list screen and the menu's hint.
    public static var muteEffect: String { L10n.t("safety.mute.effect") }

    /// The toast after a mute.
    public static func muted(_ target: SafetyTarget) -> String {
        L10n.t("safety.mute.toast", target.name)
    }

    /// The toast after an unmute.
    public static func unmuted(_ target: SafetyTarget) -> String {
        L10n.t("safety.unmute.toast", target.name)
    }

    // MARK: Report

    /// The line at the top of the reason picker.
    public static var reportIntro: String { L10n.t("safety.report.intro") }

    /// Said next to the submit button, every time.
    public static var reportIsSilent: String { L10n.t("safety.report.isSilent") }

    /// What Sila will and will not promise about the outcome.
    public static var reportOutcome: String { L10n.t("safety.report.outcome") }

    /// The heading on the ordinary confirmation.
    public static var reportReceivedTitle: String { L10n.t("safety.report.received.title") }

    /// The body of the ordinary confirmation.
    public static func reportReceivedBody(id: String) -> String {
        let reference = id.isEmpty ? "" : L10n.t("safety.report.received.reference", id)
        return L10n.t("safety.report.received.body", reference)
    }

    /// The heading on the care-first outcome.
    public static var supportTitle: String { L10n.t("safety.support.title") }

    /// The body of the care-first outcome when the server supplied no words of
    /// its own.
    ///
    /// Deliberately contains **no phone numbers**. This client does not know
    /// which country the person in trouble is in, and a helpline invented on the
    /// device is a wrong number handed to somebody in an emergency.
    public static var supportFallbackMessage: String { L10n.t("safety.support.fallbackMessage") }

    /// The reassurance under the care-first outcome.
    public static var supportPrivacy: String { L10n.t("safety.support.privacy") }

    /// What to do next, offered rather than pushed. Someone reporting self-harm
    /// is usually trying to help a person, not remove them, so the block and
    /// mute controls are secondary here and phrased as a choice.
    public static var supportNextSteps: String { L10n.t("safety.support.nextSteps") }

    // MARK: Suspension

    /// The heading on the suspension screen.
    public static var suspendedTitle: String { L10n.t("safety.suspended.title") }

    /// Said when the server gave no reason. It does not invent one.
    public static var suspendedNoReason: String { L10n.t("safety.suspended.noReason") }

    /// What an indefinite suspension means, said plainly rather than left blank.
    public static var suspendedIndefinite: String { L10n.t("safety.suspended.indefinite") }

    /// What is and is not reachable while suspended.
    public static var suspendedScope: String { L10n.t("safety.suspended.scope") }

    /// The label above the appeal box.
    public static var appealPrompt: String { L10n.t("safety.appeal.prompt") }

    /// Confirmation once an appeal is in.
    public static var appealSubmitted: String { L10n.t("safety.appeal.submitted") }

    // MARK: Lists

    /// The explanation at the top of the blocked list.
    public static var blockedListCaption: String { L10n.t("safety.list.blocked.caption") }

    /// The explanation at the top of the muted list.
    public static var mutedListCaption: String { L10n.t("safety.list.muted.caption") }

    /// The explanation at the top of the reports list.
    public static var reportsListCaption: String { L10n.t("safety.list.reports.caption") }
}
