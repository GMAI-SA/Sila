import Foundation
import SwiftUI

/// Which way a run of text reads.
///
/// Separate from ``L10n/layoutDirection`` on purpose. The *interface* has one
/// direction, chosen by the person using it. A *post* has its own, decided by
/// whoever wrote it — and the two disagree constantly on a network whose users
/// read Arabic and quote English. An Arabic post inside an English UI still has
/// to read right-to-left, with its punctuation on the correct end; an English
/// post inside an Arabic UI still has to read left-to-right. Forcing either one
/// to follow the app's language is the bug this type exists to prevent.
public enum TextDirection: String, Equatable, Sendable {

    case leftToRight
    case rightToLeft

    /// SwiftUI's spelling.
    public var layoutDirection: LayoutDirection {
        self == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// The alignment that puts the text against the edge it starts from.
    ///
    /// Always `.leading`, evaluated in *this* direction's environment — which
    /// is why every caller pairs it with ``layoutDirection`` rather than
    /// hard-coding `.trailing` for Arabic.
    public var multilineAlignment: TextAlignment { .leading }

    /// The frame alignment matching ``multilineAlignment``.
    public var frameAlignment: Alignment {
        self == .rightToLeft ? .trailing : .leading
    }

    // MARK: - Resolution

    /// The direction to lay a piece of user-authored content out in.
    ///
    /// Sources, in the order they are trusted:
    ///
    /// 1. **The server.** Posts carry a `language` field and `GET /languages`
    ///    carries an `rtl` flag per language. The server did the detection over
    ///    the whole post at write time; the client sees one excerpt.
    /// 2. **The text itself**, by the Unicode bidirectional algorithm's rule
    ///    P2/P3 — the first strong directional character wins. This is what
    ///    every text engine already does internally, and matching it means the
    ///    frame agrees with the glyphs inside it.
    /// 3. **The interface**, when the content is `123 👍` or empty and has no
    ///    direction of its own.
    ///
    /// - Parameters:
    ///   - languageCode: The server's `language` for this content, if any.
    ///   - text: The content, used when the server sent no language.
    ///   - directory: Language metadata from `GET /languages`.
    /// - Returns: The direction to render in.
    public static func resolve(
        languageCode: String?,
        text: String?,
        directory: LanguageDirectory = .shared
    ) -> TextDirection {
        if let languageCode, !languageCode.isEmpty,
           let known = directory.isRightToLeft(languageCode) {
            return known ? .rightToLeft : .leftToRight
        }
        if let text, let strong = firstStrongDirection(in: text) {
            return strong
        }
        return L10n.isRightToLeft ? .rightToLeft : .leftToRight
    }

    /// Convenience for a post.
    public static func of(_ post: Post, directory: LanguageDirectory = .shared) -> TextDirection {
        resolve(languageCode: post.language, text: post.text, directory: directory)
    }

    /// The Unicode bidi algorithm's P2/P3: scan for the first character with a
    /// strong direction, ignoring digits, punctuation, emoji and whitespace.
    ///
    /// Returns `nil` when there is no such character, which is a real case —
    /// `"2026 🎉"` has no direction of its own and must inherit one rather than
    /// be assigned one.
    public static func firstStrongDirection(in text: String) -> TextDirection? {
        for scalar in text.unicodeScalars {
            let value = scalar.value

            // Right-to-left first, because several of its blocks sit inside the
            // supplementary-plane range the left-to-right test casts a wide net
            // over. Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan and Mandaic;
            // the Arabic presentation forms; and the RTL historic scripts.
            if (0x0590...0x08FF).contains(value)
                || (0xFB1D...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value)
                || (0x10800...0x10FFF).contains(value)
                || (0x1E800...0x1EFFF).contains(value) {
                return .rightToLeft
            }

            // Latin, Greek, Cyrillic, the Indic and South-East Asian blocks,
            // CJK, Hangul, and the left-to-right supplementary planes.
            if (0x0041...0x005A).contains(value)
                || (0x0061...0x007A).contains(value)
                || (0x00C0...0x02B8).contains(value)
                || (0x0370...0x058F).contains(value)
                || (0x0900...0x1FFF).contains(value)
                || (0x2C00...0xD7FF).contains(value)
                || (0xF900...0xFB1C).contains(value)
                || (0x10000...0x107FF).contains(value)
                || (0x11000...0x1E7FF).contains(value)
                || (0x20000...0x2FA1F).contains(value) {
                return .leftToRight
            }
        }
        return nil
    }
}

// MARK: - Server-supplied language metadata

/// What `GET /languages` says about the languages Sila carries content in.
public struct LanguageOption: Identifiable, Equatable, Sendable, Decodable {

    /// BCP-47 code — `"ar"`, `"en"`.
    public let code: String
    /// The language's name in the *interface's* language.
    public let name: String
    /// The language's name in itself — `"العربية"`. Always rendered in its own
    /// direction, which is the whole reason it is a separate field.
    public let nativeName: String
    /// Whether content in this language reads right-to-left.
    public let rtl: Bool

    public var id: String { code }

    public init(code: String, name: String, nativeName: String, rtl: Bool) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
        self.rtl = rtl
    }

    private enum CodingKeys: String, CodingKey {
        case code, name, nativeName, rtl
    }

    /// Tolerant, like every other decoder in this app: a language the server
    /// added a field to must not blank the whole list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode = (try? container.decode(String.self, forKey: .code)) ?? ""
        code = rawCode.lowercased()
        let decodedName = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        name = decodedName?.isEmpty == false ? decodedName! : rawCode
        let native = (try? container.decodeIfPresent(String.self, forKey: .nativeName)) ?? nil
        nativeName = native?.isEmpty == false ? native! : name
        // A missing `rtl` is answered from the script, not from `false`.
        // Defaulting to `false` would silently left-align every Arabic post the
        // day the server dropped the field.
        rtl = ((try? container.decodeIfPresent(Bool.self, forKey: .rtl)) ?? nil)
            ?? L10n.Language.isRightToLeft(code: rawCode)
    }
}

/// The app's memory of `GET /languages`.
///
/// A cache with a fallback rather than a required fetch: the first feed render
/// happens before any network call has returned, and an Arabic post must not
/// spend that first frame left-aligned and then jump.
public final class LanguageDirectory: @unchecked Sendable {

    /// The instance the views read.
    public static let shared = LanguageDirectory()

    private let lock = NSLock()
    private var flags: [String: Bool] = [:]

    public init(options: [LanguageOption] = []) {
        replace(with: options)
    }

    /// Whether content in `code` reads right-to-left.
    ///
    /// - Returns: `nil` when the language is genuinely unknown — neither the
    ///   server nor the script table has an answer — which tells
    ///   ``TextDirection/resolve(languageCode:text:directory:)`` to look at the
    ///   text instead of trusting a made-up `false`.
    public func isRightToLeft(_ code: String) -> Bool? {
        let base = String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            .lowercased()
        guard !base.isEmpty else { return nil }
        lock.lock()
        let stored = flags[base]
        lock.unlock()
        if let stored { return stored }
        if L10n.Language.isRightToLeft(code: base) { return true }
        return nil
    }

    /// Replaces the cache with what the server just said.
    public func replace(with options: [LanguageOption]) {
        lock.lock()
        flags = Dictionary(options.map { ($0.code, $0.rtl) }, uniquingKeysWith: { _, latest in latest })
        lock.unlock()
    }

    /// Empties the cache. Sign-out and tests.
    public func clear() {
        lock.lock()
        flags = [:]
        lock.unlock()
    }
}

// MARK: - View plumbing

extension View {

    /// Lays this view out in `direction`, whatever the app's language is.
    ///
    /// Sets the layout direction rather than flipping an alignment, so that
    /// `.leading` keeps meaning "where the text starts" for everything inside —
    /// including the `Text`'s own line-breaking and the trailing-edge
    /// punctuation that a hard-coded `.trailing` gets wrong.
    public func slContentDirection(_ direction: TextDirection) -> some View {
        environment(\.layoutDirection, direction.layoutDirection)
            .multilineTextAlignment(direction.multilineAlignment)
    }

    /// ``slContentDirection(_:)`` for a post.
    public func slContentDirection(of post: Post) -> some View {
        slContentDirection(TextDirection.of(post))
    }
}
