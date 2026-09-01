import Foundation

/// What a scope is being described *for*.
///
/// A whole-sentence selector rather than a noun to splice in. Arabic will not
/// accept an English word dropped into the middle of an Arabic sentence, and the
/// grammar around the word changes with it — "غرفة دولية" and "سلسلة دولية"
/// agree differently with what follows. So each subject picks a sentence that
/// was written as a sentence, in every language.
public enum ScopeSubject: Equatable, Sendable, CaseIterable {

    /// A post and its replies.
    case thread
    /// A voice room. The scope governs who may **speak**; everyone may listen.
    case room

    /// "International thread. Any verified account can reply."
    var internationalKey: String {
        self == .room
            ? "post.scope.international.room.accessibility"
            : "post.scope.international.thread.accessibility"
    }

    /// The chip when the server said "country" but sent no usable code.
    var countryFallbackLabelKey: String {
        self == .room ? "post.scope.country.room.label" : "post.scope.country.thread.label"
    }

    /// "Country thread. Only verified accounts in Saudi Arabia can reply."
    var countryKey: String {
        self == .room
            ? "post.scope.country.room.accessibility"
            : "post.scope.country.thread.accessibility"
    }

    /// The same sentence with no country to name.
    var countryUnknownKey: String {
        self == .room
            ? "post.scope.country.room.unknownAccessibility"
            : "post.scope.country.thread.unknownAccessibility"
    }

    /// The chip when the server said "region" but sent no usable one.
    var regionFallbackLabelKey: String {
        self == .room ? "post.scope.region.room.label" : "post.scope.region.thread.label"
    }

    /// "Regional thread. Only verified accounts in GCC can reply."
    var regionKey: String {
        self == .room
            ? "post.scope.region.room.accessibility"
            : "post.scope.region.thread.accessibility"
    }

    /// The same sentence with no region to name.
    var regionUnknownKey: String {
        self == .room
            ? "post.scope.region.room.unknownAccessibility"
            : "post.scope.region.thread.unknownAccessibility"
    }
}

/// How a post's scope renders on a card.
///
/// A value type, so "what does a 🇸🇦 country thread say on the card?" is a pure
/// function the tests can assert on without instantiating a view — the same
/// shape `WallPresentation` uses in Phase 1.
public struct ScopePresentation: Equatable, Sendable {

    /// SF Symbol for the scope chip.
    public let icon: String
    /// Short label, e.g. `"🇸🇦 Saudi Arabia only"`.
    public let label: String
    /// What VoiceOver reads instead of the emoji-laden label.
    public let accessibilityLabel: String

    /// Maps a post to its scope chip.
    /// - Parameter post: The post being rendered.
    public static func make(for post: Post) -> ScopePresentation {
        make(scope: post.scope, country: post.scopeCountry, region: post.scopeRegion)
    }

    /// Maps a raw scope triple to its chip.
    ///
    /// Split out from ``make(for:)`` so a voice room — which carries the same
    /// three wire fields and means the same thing by them — renders the same
    /// chip as a post rather than growing a second vocabulary for one idea.
    /// What differs is the whole sentence, not one word in it: see
    /// ``ScopeSubject``.
    /// - Parameters:
    ///   - scope: The `scope` field.
    ///   - country: `scope_country`, when the scope carries one.
    ///   - region: `scope_region`, when the scope carries one.
    ///   - subject: What is being scoped. A room's scope decides who may
    ///     **speak**, and everybody may still listen — which is a different
    ///     sentence, not a substituted verb.
    public static func make(
        scope: PostScope,
        country: String?,
        region: String?,
        subject: ScopeSubject = .thread
    ) -> ScopePresentation {
        switch scope {
        case .international:
            return ScopePresentation(
                icon: "globe",
                label: L10n.t("post.scope.international.label"),
                accessibilityLabel: L10n.t(subject.internationalKey)
            )

        case .country:
            let flag = CountryCode.flag(country)
            let name = CountryCode.name(country)
            switch (flag, name) {
            case let (flag?, name?):
                return ScopePresentation(
                    icon: "flag.fill",
                    label: L10n.t("post.scope.country.label", flag, name),
                    accessibilityLabel: L10n.t(subject.countryKey, name)
                )
            default:
                // The server said "country" but gave us no usable code. Say so
                // plainly rather than inventing a flag.
                return ScopePresentation(
                    icon: "flag.fill",
                    label: L10n.t(subject.countryFallbackLabelKey),
                    accessibilityLabel: L10n.t(subject.countryUnknownKey)
                )
            }

        case .region:
            let region = region?.uppercased()
            if let region, !region.isEmpty {
                return ScopePresentation(
                    icon: "map.fill",
                    label: L10n.t("post.scope.region.label", region),
                    accessibilityLabel: L10n.t(subject.regionKey, region)
                )
            }
            return ScopePresentation(
                icon: "map.fill",
                label: L10n.t(subject.regionFallbackLabelKey),
                accessibilityLabel: L10n.t(subject.regionUnknownKey)
            )
        }
    }

    /// The pre-``ScopeSubject`` spelling, kept so ``VoiceRoom`` and its tests
    /// compile unchanged.
    ///
    /// Deliberately has **no** default arguments: that is what keeps
    /// `make(scope:country:region:)` unambiguously the modern overload.
    /// - Parameters:
    ///   - noun: `"room"` selects ``ScopeSubject/room``; anything else is a
    ///     thread. The word itself is no longer interpolated anywhere — it only
    ///     picks which pre-written sentence to read.
    ///   - verb: Ignored. The verb is part of the sentence the subject selects.
    public static func make(
        scope: PostScope,
        country: String?,
        region: String?,
        noun: String,
        verb: String
    ) -> ScopePresentation {
        make(
            scope: scope,
            country: country,
            region: region,
            subject: noun.lowercased() == "room" ? .room : .thread
        )
    }
}

/// Whether the viewer may reply, and the sentence to show when they may not.
public struct ReplyPermission: Equatable, Sendable {

    /// `true` when the reply affordance should be live.
    public let canReply: Bool
    /// Human-language explanation, `nil` when ``canReply`` is `true`.
    public let blockedMessage: String?

    /// Maps a post's `viewer` block onto the reply affordance.
    ///
    /// The rule the product cares about: never render a dead reply button.
    /// Either the button works, or the reason it does not is on screen.
    /// - Parameter post: The post being replied to.
    public static func make(for post: Post) -> ReplyPermission {
        guard !post.viewer.canReply else {
            return ReplyPermission(canReply: true, blockedMessage: nil)
        }
        return ReplyPermission(
            canReply: false,
            blockedMessage: message(
                for: post.viewer.replyBlockReason,
                scopeCountry: post.scopeCountry,
                scopeRegion: post.scopeRegion
            )
        )
    }

    /// The sentence for one block reason.
    /// - Parameters:
    ///   - reason: What the server said. `nil` is treated as an unnamed block.
    ///   - scopeCountry: The thread's country, used to name the flag.
    ///   - scopeRegion: The thread's region.
    public static func message(
        for reason: ReplyBlockReason?,
        scopeCountry: String?,
        scopeRegion: String?
    ) -> String {
        switch reason {
        case .countryMismatch:
            if let flag = CountryCode.flag(scopeCountry), let name = CountryCode.name(scopeCountry) {
                return L10n.t("post.reply.blocked.country", flag, name)
            }
            return L10n.t("post.reply.blocked.countryUnknown")

        case .regionMismatch:
            if let region = scopeRegion?.uppercased(), !region.isEmpty {
                return L10n.t("post.reply.blocked.region", region)
            }
            return L10n.t("post.reply.blocked.regionUnknown")

        case .unverified:
            return L10n.t("post.reply.blocked.unverified")

        case .unknown, .none:
            return L10n.t("post.reply.blocked.unknown")
        }
    }
}

/// Compact relative timestamps in the social-feed idiom — `"2h"`, not
/// `"2 hours ago"`.
///
/// `RelativeDateTimeFormatter`'s shortest style still produces "2 hr ago", so
/// this is hand-rolled. It is a pure function of two dates, which makes it
/// testable without freezing the clock.
public enum RelativeTime {

    /// Formats `date` relative to `reference`.
    /// - Parameters:
    ///   - date: When the post was created.
    ///   - reference: "Now". Defaults to the current time.
    /// - Returns: `"now"`, `"45s"`, `"12m"`, `"2h"`, `"3d"`, `"5w"`, or an
    ///   absolute date such as `"12 Aug 2025"` beyond a year.
    ///
    /// The unit letters are copy, not punctuation: Arabic abbreviates these as
    /// `ث د س ي أ`, and a timestamp reading `"2h"` under an Arabic post is the
    /// one place a reader notices the app was translated everywhere except here.
    public static func short(_ date: Date, relativeTo reference: Date = Date()) -> String {
        let seconds = reference.timeIntervalSince(date)

        // A clock skew that puts the post in the future reads as "now", not "-3s".
        guard seconds >= 1 else { return L10n.t("post.time.now") }

        switch seconds {
        case ..<60:
            return L10n.t("post.time.seconds", SLFormat.number(Int(seconds)))
        case ..<3_600:
            return L10n.t("post.time.minutes", SLFormat.number(Int(seconds / 60)))
        case ..<86_400:
            return L10n.t("post.time.hours", SLFormat.number(Int(seconds / 3_600)))
        case ..<604_800:
            return L10n.t("post.time.days", SLFormat.number(Int(seconds / 86_400)))
        case ..<31_536_000:
            return L10n.t("post.time.weeks", SLFormat.number(Int(seconds / 604_800)))
        default:
            return SLFormat.date(date)
        }
    }

    /// The long form VoiceOver reads, e.g. `"2 hours ago"` / `"قبل ساعتين"`.
    public static func accessible(_ date: Date, relativeTo reference: Date = Date()) -> String {
        SLFormat.relative(date, to: reference)
    }
}

/// The three inline entities the feed highlights inside post text.
public enum PostTextToken: Equatable, Sendable {
    /// Ordinary run of characters.
    case plain(String)
    /// `@handle` — the payload excludes the `@`.
    case mention(String)
    /// `#hashtag` — the payload excludes the `#`.
    case hashtag(String)

    /// The characters this token occupies in the original text.
    public var raw: String {
        switch self {
        case let .plain(value): return value
        case let .mention(value): return "@\(value)"
        case let .hashtag(value): return "#\(value)"
        }
    }
}

/// Splits post text into plain runs, `@mentions` and `#hashtags`.
///
/// Kept out of the view so the parse is unit-testable and so Phase 4's composer
/// can reuse the same definition of "what counts as a mention".
public enum PostTextParser {

    /// Handle characters, matching the backend's `[a-z0-9_]{3,20}` rule (we
    /// accept upper case here and let the tap handler lowercase).
    private static let handleCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
    )

    /// Hashtags additionally allow non-Latin letters, so Arabic tags work.
    private static func isHashtagCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func isHandleCharacter(_ scalar: Unicode.Scalar) -> Bool {
        handleCharacters.contains(scalar)
    }

    /// Tokenises `text`.
    /// - Parameter text: Raw post body.
    /// - Returns: Tokens in source order; concatenating ``PostTextToken/raw``
    ///   reproduces `text` exactly.
    public static func tokenize(_ text: String) -> [PostTextToken] {
        var tokens: [PostTextToken] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            if !plain.isEmpty {
                tokens.append(.plain(plain))
                plain = ""
            }
        }

        while index < text.endIndex {
            let character = text[index]
            guard character == "@" || character == "#" else {
                plain.append(character)
                index = text.index(after: index)
                continue
            }

            // A sigil only starts an entity at a word boundary, so an email
            // address or a mid-word "#" stays plain text.
            let isBoundary: Bool
            if index == text.startIndex {
                isBoundary = true
            } else {
                let previous = text[text.index(before: index)]
                isBoundary = previous.isWhitespace || previous.isNewline || previous.isPunctuation
            }

            var cursor = text.index(after: index)
            var body = ""
            while cursor < text.endIndex {
                let candidate = text[cursor]
                let accepted = candidate.unicodeScalars.allSatisfy { scalar in
                    character == "@" ? isHandleCharacter(scalar) : isHashtagCharacter(scalar)
                }
                guard accepted else { break }
                body.append(candidate)
                cursor = text.index(after: cursor)
            }

            if isBoundary, !body.isEmpty {
                flushPlain()
                tokens.append(character == "@" ? .mention(body) : .hashtag(body))
                index = cursor
            } else {
                plain.append(character)
                index = text.index(after: index)
            }
        }

        flushPlain()
        return tokens
    }
}
