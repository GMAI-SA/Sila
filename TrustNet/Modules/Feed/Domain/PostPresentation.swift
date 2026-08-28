import Foundation

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
        switch post.scope {
        case .international:
            return ScopePresentation(
                icon: "globe",
                label: "International",
                accessibilityLabel: "International thread. Any verified account can reply."
            )

        case .country:
            let code = post.scopeCountry
            let flag = CountryCode.flag(code)
            let name = CountryCode.name(code)
            switch (flag, name) {
            case let (flag?, name?):
                return ScopePresentation(
                    icon: "flag.fill",
                    label: "\(flag) \(name) only",
                    accessibilityLabel: "Country thread. Only verified accounts in \(name) can reply."
                )
            default:
                // The server said "country" but gave us no usable code. Say so
                // plainly rather than inventing a flag.
                return ScopePresentation(
                    icon: "flag.fill",
                    label: "Country thread",
                    accessibilityLabel: "Country thread. Only verified accounts in that country can reply."
                )
            }

        case .region:
            let region = post.scopeRegion?.uppercased()
            if let region, !region.isEmpty {
                return ScopePresentation(
                    icon: "map.fill",
                    label: "\(region) region",
                    accessibilityLabel: "Regional thread. Only verified accounts in \(region) can reply."
                )
            }
            return ScopePresentation(
                icon: "map.fill",
                label: "Regional thread",
                accessibilityLabel: "Regional thread. Only verified accounts in that region can reply."
            )
        }
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
                return "Only \(flag) \(name)-verified accounts can reply to this thread."
            }
            return "Only accounts verified in this thread's country can reply."

        case .regionMismatch:
            if let region = scopeRegion?.uppercased(), !region.isEmpty {
                return "Only accounts verified in the \(region) region can reply to this thread."
            }
            return "Only accounts verified in this thread's region can reply."

        case .unverified:
            return "Verify your identity to reply. Everyone can read TrustNet; only verified humans can post."

        case .unknown, .none:
            return "You can't reply to this thread."
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
    public static func short(_ date: Date, relativeTo reference: Date = Date()) -> String {
        let seconds = reference.timeIntervalSince(date)

        // A clock skew that puts the post in the future reads as "now", not "-3s".
        guard seconds >= 1 else { return "now" }

        switch seconds {
        case ..<60:
            return "\(Int(seconds))s"
        case ..<3_600:
            return "\(Int(seconds / 60))m"
        case ..<86_400:
            return "\(Int(seconds / 3_600))h"
        case ..<604_800:
            return "\(Int(seconds / 86_400))d"
        case ..<31_536_000:
            return "\(Int(seconds / 604_800))w"
        default:
            return absoluteFormatter.string(from: date)
        }
    }

    /// The long form VoiceOver reads, e.g. `"2 hours ago"`.
    public static func accessible(_ date: Date, relativeTo reference: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: reference)
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
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
