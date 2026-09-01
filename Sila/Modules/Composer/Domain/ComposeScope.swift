import Foundation

// MARK: - Region

/// The three multi-country audiences a thread can be opened for.
///
/// Membership is decided **server-side** — the lists below only decide what the
/// scope picker offers, so a user is never shown an option the backend will
/// answer `reply_not_allowed` to. A code missing from a list therefore costs an
/// option, never correctness.
public enum GeoRegion: String, CaseIterable, Identifiable, Sendable, Hashable {
    /// Gulf Cooperation Council.
    case gcc = "GCC"
    /// Middle East & North Africa.
    case mena = "MENA"
    /// European Union.
    case eu = "EU"

    public var id: String { rawValue }

    /// The wire value sent as `scope_region`.
    public var wireValue: String { rawValue }

    /// Short label for the picker row.
    ///
    /// Localised: the abbreviation is copy, ``wireValue`` is the wire value.
    public var title: String {
        switch self {
        case .gcc: return L10n.t("composer.scope.region.gcc.title")
        case .mena: return L10n.t("composer.scope.region.mena.title")
        case .eu: return L10n.t("composer.scope.region.eu.title")
        }
    }

    /// What the abbreviation stands for.
    public var expandedName: String {
        switch self {
        case .gcc: return L10n.t("composer.scope.region.gcc.name")
        case .mena: return L10n.t("composer.scope.region.mena.name")
        case .eu: return L10n.t("composer.scope.region.eu.name")
        }
    }

    /// ISO-3166 alpha-2 codes this build considers part of the region.
    public var countryCodes: Set<String> {
        switch self {
        case .gcc:
            return ["BH", "KW", "OM", "QA", "SA", "AE"]
        case .mena:
            return GeoRegion.gcc.countryCodes.union([
                "DZ", "EG", "IQ", "IR", "IL", "JO", "LB", "LY",
                "MA", "MR", "PS", "SD", "SY", "TN", "YE"
            ])
        case .eu:
            return [
                "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR",
                "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL",
                "PL", "PT", "RO", "SK", "SI", "ES", "SE"
            ]
        }
    }

    /// Whether a verified country sits inside this region.
    /// - Parameter code: ISO-3166 alpha-2, in any case. `nil` is never a member.
    public func contains(_ code: String?) -> Bool {
        guard let code = CountryCode.normalised(code) else { return false }
        return countryCodes.contains(code)
    }

    /// Every region a country belongs to, in declaration order.
    /// - Parameter code: The author's verified country, or `nil`.
    public static func regions(containing code: String?) -> [GeoRegion] {
        allCases.filter { $0.contains(code) }
    }

    /// Decodes a `scope_region` value, tolerating case and whitespace.
    /// - Returns: `nil` for a value this build does not recognise, which is
    ///   rendered as a generic "regional thread" rather than a guess.
    public static func parse(_ raw: String?) -> GeoRegion? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return GeoRegion(rawValue: trimmed)
    }
}

// MARK: - Scope

/// The audience a new post is opened to — **the composer's centrepiece.**
///
/// Everyone can read every post; the scope decides who may *reply*. This is the
/// one choice on the composer that the rest of the product is built around, so
/// it is a value type with its own wire mapping rather than a loose pair of
/// strings assembled at the call site.
public enum ComposeScope: Hashable, Sendable {
    /// Any verified account may reply.
    case international
    /// Only accounts verified in this country may reply. The payload is the
    /// **author's own** country — the server rejects anything else.
    case country(String)
    /// Only accounts whose verified country sits in this region may reply.
    case region(GeoRegion)

    /// The `scope` field on `POST /posts`.
    public var wireValue: String {
        switch self {
        case .international: return "international"
        case .country: return "country"
        case .region: return "region"
        }
    }

    /// The `scope_country` field, when the scope carries one.
    public var scopeCountry: String? {
        if case let .country(code) = self { return CountryCode.normalised(code) ?? code }
        return nil
    }

    /// The `scope_region` field, when the scope carries one.
    public var scopeRegion: String? {
        if case let .region(region) = self { return region.wireValue }
        return nil
    }

    /// The scope a reply inherits from the post it answers.
    ///
    /// The server applies the root post's scope to every reply regardless of
    /// what the client sends; sending the parent's scope keeps the request
    /// honest instead of quietly claiming `international` for a country thread.
    /// - Parameter post: The post being replied to.
    public static func inherited(from post: Post) -> ComposeScope {
        switch post.scope {
        case .international:
            return .international
        case .country:
            guard let code = post.scopeCountry else { return .international }
            return .country(code)
        case .region:
            guard let region = GeoRegion.parse(post.scopeRegion) else { return .international }
            return .region(region)
        }
    }
}

// MARK: - Author

/// What the composer needs to know about the person writing.
///
/// A value type rather than a reference to the session, so every scope-picker
/// decision is a pure function of it and can be tested without signing anyone in.
public struct ComposerAuthor: Equatable, Sendable {

    /// The author's handle, when the account has one. Used only for display.
    public let handle: String?
    /// The **country-verified** flag: ISO-3166 alpha-2, or `nil`.
    ///
    /// Written only by the verification pipeline. `nil` here is the reason the
    /// "My Country" scope is offered but not selectable.
    public let countryCode: String?
    /// Whether identity verification has completed.
    public let isVerified: Bool

    public init(handle: String? = nil, countryCode: String? = nil, isVerified: Bool) {
        self.handle = handle
        self.countryCode = CountryCode.normalised(countryCode)
        self.isVerified = isVerified
    }

    /// Builds an author from the signed-in account.
    /// - Parameter user: `nil` when the session has not resolved yet, which is
    ///   treated as "unverified, no badge" — the most restrictive reading.
    public init(user: AuthUser?) {
        self.init(
            handle: user?.handle,
            countryCode: user?.countryCode,
            isVerified: user?.verificationStatus == .verified
        )
    }

    /// `true` when the account carries a verified country.
    public var hasCountryBadge: Bool { countryCode != nil }

    /// The author's country name, when it has one.
    ///
    /// Named in the *interface's* language rather than the device's, so an
    /// Arabic build says المملكة العربية السعودية even on an English phone.
    public var countryName: String? { CountryCode.name(countryCode, locale: L10n.locale) }

    /// The author's flag emoji, when it has one.
    public var countryFlag: String? { CountryCode.flag(countryCode) }
}

// MARK: - Scope options

/// One row in the scope picker, including *why* it may be unavailable.
///
/// An unavailable option is still rendered. Hiding "My Country" from an
/// unverified account would leave them wondering whether the feature exists;
/// showing it greyed out with the reason tells them exactly what verification
/// buys — which is the product's whole argument.
public struct ScopeOption: Identifiable, Equatable, Sendable {

    /// The scope this row selects.
    public let scope: ComposeScope
    /// Row title, e.g. `"🇸🇦 Saudi Arabia"`.
    public let title: String
    /// One line explaining who may reply.
    public let subtitle: String
    /// SF Symbol for the row.
    public let icon: String
    /// Whether the row can be selected.
    public let isAvailable: Bool
    /// Why not, when ``isAvailable`` is `false`.
    public let unavailableReason: String?
    /// What VoiceOver reads for the row.
    public let accessibilityLabel: String

    public var id: String {
        switch scope {
        case .international: return "international"
        case let .country(code): return "country-\(code)"
        case let .region(region): return "region-\(region.rawValue)"
        }
    }

    public init(
        scope: ComposeScope,
        title: String,
        subtitle: String,
        icon: String,
        isAvailable: Bool,
        unavailableReason: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.scope = scope
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.accessibilityLabel = accessibilityLabel
            ?? L10n.t("composer.scope.option.a11yLabel", title, unavailableReason ?? subtitle)
    }
}

/// Builds the scope picker's rows for an author.
///
/// The rules, all of them enforced server-side as well:
///
/// - **International** is always available to a verified account.
/// - **My Country** needs a country badge, and may only ever name the author's
///   *own* country — the contract rejects any other `scope_country`.
/// - **A region** needs a badge whose country is inside that region, otherwise
///   the author could open a thread they themselves could not reply in.
public enum ScopePicker {

    /// Every row, available ones first in the order International → Country → Regions.
    /// - Parameter author: Who is writing.
    public static func options(for author: ComposerAuthor) -> [ScopeOption] {
        [internationalOption(for: author), countryOption(for: author)] + regionOptions(for: author)
    }

    /// The scope a fresh composer opens on. Always ``ComposeScope/international``:
    /// the widest audience is the least surprising default, and it is the only
    /// one guaranteed to be available.
    public static func defaultScope(for author: ComposerAuthor) -> ComposeScope { .international }

    /// Whether a scope can actually be posted with by this author.
    public static func isAvailable(_ scope: ComposeScope, for author: ComposerAuthor) -> Bool {
        options(for: author).first { $0.scope == scope }?.isAvailable ?? false
    }

    // MARK: Rows

    private static func internationalOption(for author: ComposerAuthor) -> ScopeOption {
        ScopeOption(
            scope: .international,
            title: L10n.t("composer.scope.international.title"),
            subtitle: L10n.t("composer.scope.international.subtitle"),
            icon: "globe",
            isAvailable: true,
            accessibilityLabel: L10n.t("composer.scope.international.a11yLabel")
        )
    }

    private static func countryOption(for author: ComposerAuthor) -> ScopeOption {
        guard let code = author.countryCode,
              let flag = CountryCode.flag(code),
              // The country's name in the interface's language, never the
              // device's — an Arabic build must not label the row in English.
              let name = CountryCode.name(code, locale: L10n.locale) else {
            // The badge is missing. Say what it is and where it comes from —
            // it is earned by verification, never by an IP address or a locale.
            return ScopeOption(
                scope: .country(""),
                title: L10n.t("composer.scope.myCountry.title"),
                subtitle: L10n.t("composer.scope.myCountry.subtitle"),
                icon: "flag",
                isAvailable: false,
                unavailableReason: L10n.t("composer.scope.myCountry.unavailableReason"),
                accessibilityLabel: L10n.t("composer.scope.myCountry.a11yLabel")
            )
        }
        return ScopeOption(
            scope: .country(code),
            title: L10n.t("composer.scope.country.title", flag, name),
            subtitle: L10n.t("composer.scope.country.subtitle", name),
            icon: "flag.fill",
            isAvailable: true,
            accessibilityLabel: L10n.t("composer.scope.country.a11yLabel", name, name)
        )
    }

    private static func regionOptions(for author: ComposerAuthor) -> [ScopeOption] {
        GeoRegion.allCases.map { region in
            let isMember = region.contains(author.countryCode)
            let reason: String?
            if isMember {
                reason = nil
            } else if let name = author.countryName {
                // Opening a thread you could not reply in is a trap, so the
                // option is offered and explained rather than silently dropped.
                reason = L10n.t(
                    "composer.scope.region.outsideReason",
                    name, region.title, region.title
                )
            } else {
                reason = L10n.t("composer.scope.region.noCountryReason")
            }
            return ScopeOption(
                scope: .region(region),
                title: region.title,
                subtitle: L10n.t("composer.scope.region.subtitle", region.expandedName),
                icon: "map.fill",
                isAvailable: isMember,
                unavailableReason: reason,
                accessibilityLabel: isMember
                    ? L10n.t("composer.scope.region.a11yLabel", region.expandedName)
                    : L10n.t("composer.scope.region.a11yLabelUnavailable", region.expandedName, reason ?? "")
            )
        }
    }
}
