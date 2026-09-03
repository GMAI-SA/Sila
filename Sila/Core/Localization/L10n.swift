import Foundation
import SwiftUI

/// Every user-visible sentence in Sila comes out of here.
///
/// The app ships two languages — English and Arabic — and Arabic is the one
/// the market actually reads. Both live in `Localizable.xcstrings`, keyed by
/// dotted identifiers (`feed.tab.forYou`) rather than by their English text, so
/// that two screens which happen to say "Post" in English can say the two
/// different things Arabic needs them to say.
///
/// ```swift
/// Text(L10n.t("feed.empty.title"))
/// SLButton(L10n.t("common.retry")) { … }
/// Text(L10n.plural("post.replies", post.replyCountDirect))
/// ```
///
/// ## Why not `Text("some literal")`
///
/// SwiftUI localises string *literals* passed to `Text`, but half this app's
/// copy is plain `String` — the copy enums, `SLButton` titles, accessibility
/// hints, view-model output — and none of that goes through
/// `LocalizedStringKey`. Routing everything through one function means there is
/// exactly one lookup path to test, and it is a path a test can point at the
/// Arabic bundle without relaunching the process.
public enum L10n {

    // MARK: - Language selection

    /// A language the app can render itself in.
    public struct Language: Equatable, Sendable {

        /// BCP-47 code — `"en"`, `"ar"`.
        public let code: String
        /// Where the compiled strings live.
        public let bundle: Bundle
        /// Locale used for plural-rule selection and number formatting.
        public let locale: Locale

        public init(code: String, bundle: Bundle, locale: Locale) {
            self.code = code
            self.bundle = bundle
            self.locale = locale
        }
    }

    /// Forces a language — for the duration of a test, or because the person
    /// chose one in the Profile tab's language row.
    ///
    /// `nil` — the default — means "whatever the system picked". In
    /// production the **only** writer is ``LanguagePreference``, which owns
    /// persistence and the re-render; nothing in `Modules/` may set this
    /// directly.
    public static var override: Language?

    /// The bundle strings are read from.
    public static var bundle: Bundle { override?.bundle ?? .main }

    /// The locale plural rules and formatters use.
    public static var locale: Locale { override?.locale ?? .current }

    /// The language the UI is actually rendering in.
    ///
    /// Read from the bundle's resolved localisation rather than from
    /// `Locale.current.language`: a device set to Arabic but running a build
    /// with no Arabic resources renders English, and the direction of the
    /// layout has to follow the strings that are on screen, not the ones the
    /// user asked for.
    public static var languageCode: String {
        if let override { return override.code }
        return Bundle.main.preferredLocalizations.first.map(baseCode) ?? "en"
    }

    /// `true` when the *interface* runs right-to-left.
    ///
    /// This governs chrome — nav bars, tab bars, chevrons. It deliberately does
    /// **not** govern how a single post is laid out; see ``TextDirection``.
    public static var isRightToLeft: Bool {
        Language.isRightToLeft(code: languageCode)
    }

    /// ``isRightToLeft`` as SwiftUI spells it.
    public static var layoutDirection: LayoutDirection {
        isRightToLeft ? .rightToLeft : .leftToRight
    }

    /// Installs `code` as the active language, or clears the override.
    ///
    /// - Parameter code: `"ar"`, `"en"`, or `nil` to hand control back to the
    ///   system.
    /// - Returns: `false` when the requested language has no compiled
    ///   resources, in which case nothing changed. A silent fallback here would
    ///   turn "Arabic is missing from the build" into "the test asserted
    ///   English and passed".
    @discardableResult
    public static func use(_ code: String?) -> Bool {
        guard let code else {
            override = nil
            return true
        }
        guard let language = language(for: code) else { return false }
        override = language
        return true
    }

    /// Builds a ``Language`` for `code`, or `nil` when the build has no
    /// resources for it.
    public static func language(for code: String) -> Language? {
        let base = baseCode(code)
        guard let path = Bundle.main.path(forResource: base, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return Language(code: base, bundle: bundle, locale: Locale(identifier: base))
    }

    /// Runs `body` with `code` installed, restoring the previous state after —
    /// including when `body` throws.
    public static func withLanguage<T>(_ code: String, _ body: () throws -> T) rethrows -> T {
        let previous = override
        defer { override = previous }
        _ = use(code)
        return try body()
    }

    // MARK: - Lookup

    /// The sentence for `key`.
    ///
    /// A missing key returns the key itself, which is what
    /// `LocalizationCatalogTests` looks for and what a reviewer notices
    /// immediately on screen. It is never silently blank.
    public static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: table, bundle: bundle, value: key, comment: "")
    }

    /// The sentence for `key`, with `%@` / `%lld` placeholders filled in.
    ///
    /// Formatting runs against ``formattingLocale``, so a `%lld` inside an
    /// Arabic string still renders `12` rather than `١٢`.
    public static func t(_ key: String, _ args: any CVarArg...) -> String {
        format(t(key), args)
    }

    /// The sentence for `key` in the plural form `count` selects.
    ///
    /// The catalog entry must carry plural variations. Arabic distinguishes
    /// six categories — zero, one, two, few, many, other — and an `if count ==
    /// 1` written in Swift gets four of them wrong, so counted copy must come
    /// through here rather than out of a ternary.
    ///
    /// - Parameters:
    ///   - key: A catalog key with `variations.plural` on its `%lld` argument.
    ///   - count: The number the sentence is about.
    ///   - args: Any further placeholders, in the order the format lists them.
    public static func plural(_ key: String, _ count: Int, _ args: any CVarArg...) -> String {
        format(t(key), [count] + args)
    }

    /// The table inside the catalog. One catalog, one table.
    public static let table = "Localizable"

    private static func format(_ format: String, _ args: [any CVarArg]) -> String {
        String(format: format, locale: formattingLocale, arguments: args)
    }

    // MARK: - Formatting locale

    /// ``locale``, pinned to Western digits.
    ///
    /// CLDR's default numbering system for Arabic is `arab`, which renders
    /// `١٢٣`. Saudi product UI — every bank app, every government portal, every
    /// competitor — uses `123`, and a follower count in Arabic-Indic digits
    /// reads as a typo rather than as localisation. The plural *rules* still
    /// come from the Arabic locale; only the glyphs are pinned.
    public static var formattingLocale: Locale { westernDigits(locale) }

    static func westernDigits(_ base: Locale) -> Locale {
        var components = Locale.Components(locale: base)
        components.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: components)
    }

    /// `"ar-SA"` and `"ar_SA"` are both Arabic.
    private static func baseCode(_ raw: String) -> String {
        String(raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            .lowercased()
    }
}

extension L10n.Language {

    /// Languages written right-to-left, as a last-resort fallback.
    ///
    /// The server is the authority — `GET /languages` carries an `rtl` flag per
    /// language, and ``LanguageDirectory`` prefers it. This list exists for the
    /// first render, before that call has returned, and for the offline case.
    /// It is deliberately short: these are the scripts, not a guess at every
    /// language that uses them.
    static let rightToLeftCodes: Set<String> = ["ar", "he", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ku", "arc"]

    static func isRightToLeft(code: String) -> Bool {
        rightToLeftCodes.contains(code.lowercased())
    }
}
