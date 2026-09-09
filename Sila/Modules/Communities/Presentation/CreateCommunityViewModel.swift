import Foundation
import Observation

/// Opening a community: the name, the address, the door, and who may post.
@MainActor
@Observable
public final class CreateCommunityViewModel {

    public var name = "" {
        didSet {
            nameError = nil
            // The address follows the name until somebody types their own.
            if !hasEditedSlug { slug = Self.suggestedSlug(from: name) }
        }
    }
    public var slug = "" {
        didSet {
            slugError = nil
            // Only a slug the person typed counts as theirs. Without this the
            // name's own updates looked like edits and froze the suggestion
            // after the first character.
            if slug != Self.suggestedSlug(from: name) { hasEditedSlug = true }
        }
    }
    public var about = ""
    public var visibility: CommunityVisibility = .public
    public var joinPolicy: CommunityJoinPolicy = .open
    public var scope: ComposeScope
    public var topic: String?
    public var verifiedOnly = false
    public var rulesText = ""
    public private(set) var hasEditedSlug = false
    public private(set) var topics: [TopicOption] = []
    public private(set) var isCreating = false
    public private(set) var nameError: String?
    public private(set) var slugError: String?
    public private(set) var createError: String?

    private let author: ComposerAuthor
    private let service: CommunitiesServiceProtocol
    private let preferences: PreferencesServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let onCreated: (@MainActor (Community) -> Void)?

    public init(
        author: ComposerAuthor,
        service: CommunitiesServiceProtocol,
        preferences: PreferencesServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        onCreated: (@MainActor (Community) -> Void)? = nil
    ) {
        self.author = author
        self.service = service
        self.preferences = preferences
        self.analytics = analytics
        self.suspension = suspension
        self.onCreated = onCreated
        self.scope = ScopePicker.defaultScope(for: author)
    }

    /// Rules, one per line, tidied.
    public var rules: [String] {
        rulesText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var normalisedSlug: String { Self.suggestedSlug(from: slug) }
    public var scopeOptions: [ScopeOption] { ScopePicker.options(for: author) }

    /// Running a space is speaking: only a verified account may open one.
    public var canOpen: Bool { author.isVerified }

    public var canCreate: Bool {
        canOpen && !isCreating && blockingReason == nil
    }

    /// Why the button is off, in the person's own terms. A disabled control
    /// that says nothing is a dead end.
    public var blockingReason: String? {
        if !canOpen { return L10n.t("communities.create.unverified") }
        if trimmedName.count < 2 { return L10n.t("communities.create.blocked.name") }
        if !Self.isValidSlug(normalisedSlug) { return L10n.t("communities.create.blocked.address") }
        if trimmedName.count > Self.maximumNameLength { return L10n.t("communities.create.blocked.nameLong") }
        if about.trimmingCharacters(in: .whitespacesAndNewlines).count > Self.maximumAboutLength {
            return L10n.t("communities.create.blocked.aboutLong")
        }
        if rules.count > Self.maximumRules { return L10n.t("communities.create.blocked.rules") }
        if !ScopePicker.isAvailable(scope, for: author) {
            return scopeOptions.first { $0.scope == scope }?.unavailableReason
                ?? L10n.t("rooms.create.blocked.audience")
        }
        return nil
    }

    public func loadTopics() async {
        guard topics.isEmpty else { return }
        topics = ((try? await preferences.fetchTopics()) ?? []).filter(\.isValid)
    }

    public func create() async -> Community? {
        guard canCreate else {
            createError = blockingReason
            return nil
        }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let community = try await service.createCommunity(
                CreateCommunityRequest(
                    slug: normalisedSlug,
                    name: trimmedName,
                    description: about,
                    visibility: visibility,
                    joinPolicy: joinPolicy,
                    scope: scope,
                    topic: topic,
                    verifiedOnly: verifiedOnly,
                    rules: rules
                )
            )
            onCreated?(community)
            return community
        } catch {
            guard suspension?.notice(error) != true else { return nil }
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .slugTaken || wrapped.code == .slugReserved || wrapped.code == .invalidSlug {
                slugError = wrapped.userMessage
            } else {
                createError = wrapped.userMessage
            }
            return nil
        }
    }

    /// A name turned into an address: lower case, spaces to underscores,
    /// everything else dropped. Arabic names carry no Latin letters, so the
    /// suggestion can come back empty — the field is then the person's to fill.
    /// The server's own limits, so a long name is refused here with a
    /// sentence rather than there with a 422 the client cannot read.
    static let maximumNameLength = 60
    static let maximumAboutLength = 300
    static let maximumRules = 10

    static func suggestedSlug(from name: String) -> String {
        var out = ""
        for character in name.lowercased() {
            if character.isLetter && character.isASCII || character.isNumber && character.isASCII {
                out.append(character)
            } else if character == " " || character == "_" || character == "-" {
                if !out.isEmpty && out.last != "_" { out.append("_") }
            }
            if out.count >= 30 { break }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    static func isValidSlug(_ slug: String) -> Bool {
        guard slug.count >= 3, slug.count <= 30 else { return false }
        return slug.allSatisfy { ($0.isLetter && $0.isASCII && $0.isLowercase) || ($0.isNumber && $0.isASCII) || $0 == "_" }
    }
}
