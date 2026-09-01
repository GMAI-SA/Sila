import XCTest
import Foundation
@testable import Sila

/// Guards the String Catalog itself.
///
/// Every other localisation test asks "does this screen say the right thing in
/// Arabic". This one asks the question that catches the whole class of bug at
/// once: **is there an Arabic string at all?** A missing translation in a String
/// Catalog does not fail the build and does not crash — it silently renders the
/// English, which looks like a screen somebody forgot rather than like an error,
/// and which nobody notices until a Saudi user finds it.
///
/// It reads the **compiled** `.lproj` output rather than the `.xcstrings`
/// source, so it is testing what actually ships.
final class LocalizationCatalogTests: XCTestCase {

    // MARK: - Compiled bundles

    private func lproj(_ code: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: code, ofType: "lproj"),
            "the build has no \(code).lproj — the catalog did not compile for \(code)"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    /// Flat `key: value` pairs from a compiled `Localizable.strings`.
    private func strings(_ code: String) throws -> [String: String] {
        let bundle = try lproj(code)
        let path = try XCTUnwrap(
            bundle.path(forResource: L10n.table, ofType: "strings"),
            "no compiled Localizable.strings in \(code).lproj"
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    /// Plural entries from a compiled `Localizable.stringsdict`, if there is one.
    private func plurals(_ code: String) throws -> [String: [String: Any]] {
        let bundle = try lproj(code)
        guard let path = bundle.path(forResource: L10n.table, ofType: "stringsdict") else {
            return [:]
        }
        let raw = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any])
        return raw.compactMapValues { $0 as? [String: Any] }
    }

    private func allKeys(_ code: String) throws -> Set<String> {
        try Set(strings(code).keys).union(plurals(code).keys)
    }

    // MARK: - Every key is translated

    /// The catalog carries both languages, and Arabic is not a subset of English.
    func testArabicDefinesEveryKeyEnglishDefines() throws {
        let english = try allKeys("en")
        let arabic = try allKeys("ar")

        XCTAssertFalse(english.isEmpty, "the catalog compiled to nothing")

        let missing = english.subtracting(arabic).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count) key(s) have no Arabic value and would silently render "
            + "English in front of a Saudi user: \(missing.prefix(30).joined(separator: ", "))"
        )

        let orphaned = arabic.subtracting(english).sorted()
        XCTAssertTrue(
            orphaned.isEmpty,
            "\(orphaned.count) Arabic key(s) have no English source — a renamed key "
            + "left its translation behind: \(orphaned.prefix(30).joined(separator: ", "))"
        )
    }

    /// No key resolves to its own name.
    ///
    /// `L10n.t` returns the key when the lookup misses, so this catches a typo
    /// in a key that would otherwise put `feed.empty.titl` on screen.
    func testNoKeyResolvesToItself() throws {
        for language in ["en", "ar"] {
            for (key, value) in try strings(language) {
                XCTAssertNotEqual(
                    key, value,
                    "'\(key)' in \(language) resolves to its own key — the value is missing"
                )
            }
        }
    }

    /// No Arabic value is empty or whitespace.
    func testNoArabicValueIsBlank() throws {
        for (key, value) in try strings("ar") {
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "'\(key)' has a blank Arabic value"
            )
        }
    }

    /// Arabic actually differs from English.
    ///
    /// A translator's most common failure is not an empty box, it is a copied
    /// one. The exceptions are the handful of strings that are *supposed* to be
    /// identical — pure placeholders, symbols, and the product's own name.
    func testArabicIsNotACopyOfEnglish() throws {
        let english = try strings("en")
        let arabic = try strings("ar")

        // A value with no Arabic letters and no Latin letters — "%@", "·",
        // "%1$@ · %2$@" — is a layout template, not a sentence.
        func isTemplate(_ value: String) -> Bool {
            !value.unicodeScalars.contains { scalar in
                (0x0041...0x005A).contains(scalar.value)
                    || (0x0061...0x007A).contains(scalar.value)
            }
        }

        // Strings that are *supposed* to be identical. Every one is a proper
        // noun Apple or the product does not translate, or a value that is not
        // language at all. Listed explicitly so that adding to it is a decision
        // somebody makes on purpose.
        let intentionallyIdentical: Set<String> = [
            // Apple ships these product names untranslated in Arabic iOS.
            "biometrics.kind.faceID",
            "biometrics.kind.touchID",
            "biometrics.kind.opticID",
            // An example email address. Not prose.
            "auth.field.email.placeholder"
        ]

        var copied: [String] = []
        for (key, source) in english
        where arabic[key] == source && !isTemplate(source) && !intentionallyIdentical.contains(key) {
            copied.append(key)
        }
        XCTAssertTrue(
            copied.isEmpty,
            "\(copied.count) key(s) have Arabic identical to English — they were "
            + "never translated: \(copied.sorted().prefix(30).joined(separator: ", "))"
        )
    }

    /// Every string with a placeholder keeps the same placeholders in Arabic.
    ///
    /// A dropped `%@` is a crash-adjacent bug: `String(format:)` will render a
    /// sentence missing the name it was about, and an *added* one reads
    /// uninitialised memory.
    func testPlaceholdersSurviveTranslation() throws {
        let english = try strings("en")
        let arabic = try strings("ar")

        for (key, source) in english {
            guard let translated = arabic[key] else { continue }
            // Compared as multisets: Arabic reorders clauses constantly, and a
            // positional `%1$@`/`%2$@` swap is exactly what it is supposed to
            // do. What must not change is *which* placeholders exist and how
            // many — a dropped one renders a sentence missing the name it was
            // about, and an added one reads an argument that was never passed.
            XCTAssertEqual(
                Self.placeholders(in: source).sorted(),
                Self.placeholders(in: translated).sorted(),
                "'\(key)' changed its placeholders in translation — English has "
                + "\(Self.placeholders(in: source)), Arabic has \(Self.placeholders(in: translated))"
            )
        }
    }

    /// `%@`, `%lld`, `%1$@`… in order of appearance.
    ///
    /// Parses the shape `%[argnum$][flags][width][.precision][length]conversion`
    /// and stops at the conversion character. Anything looser swallows the
    /// literal text that follows a specifier — `"%@d"` for a day count, `"%@ "`
    /// before a word — and then reports a mismatch every time a translation
    /// legitimately moves the placeholder.
    static func placeholders(in value: String) -> [String] {
        let flags = Set("-+ #0'")
        let lengths = Set("hlLqjzt")
        let conversions = Set("@dDiuUxXoOfFeEgGaAcCsSp")

        var found: [String] = []
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else {
                index += 1
                continue
            }
            var cursor = index + 1
            guard cursor < characters.count else { break }
            if characters[cursor] == "%" {          // an escaped literal percent
                index = cursor + 1
                continue
            }

            var token = "%"
            // [argnum$] — only when the digits are actually followed by '$'.
            var lookahead = cursor
            while lookahead < characters.count, characters[lookahead].isNumber { lookahead += 1 }
            if lookahead < characters.count, lookahead > cursor, characters[lookahead] == "$" {
                token += String(characters[cursor...lookahead])
                cursor = lookahead + 1
            }
            while cursor < characters.count, flags.contains(characters[cursor]) {
                token.append(characters[cursor]); cursor += 1
            }
            while cursor < characters.count, characters[cursor].isNumber {
                token.append(characters[cursor]); cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "." {
                token.append(characters[cursor]); cursor += 1
                while cursor < characters.count, characters[cursor].isNumber {
                    token.append(characters[cursor]); cursor += 1
                }
            }
            while cursor < characters.count, lengths.contains(characters[cursor]) {
                token.append(characters[cursor]); cursor += 1
            }
            if cursor < characters.count, conversions.contains(characters[cursor]) {
                token.append(characters[cursor])
                found.append(token)
                index = cursor + 1
            } else {
                // Not a specifier at all — a bare '%' in prose.
                index = cursor
            }
        }
        return found
    }

    // MARK: - Plurals

    /// Every plural entry defines all six Arabic categories.
    ///
    /// Arabic is the reason this test exists. English needs `one` and `other`;
    /// Arabic distinguishes zero, one, two, few, many and other, and a catalog
    /// that only filled in `one` and `other` produces "٢ ردود" for two replies —
    /// grammatically wrong in a way every reader notices immediately.
    func testArabicPluralsDefineEveryCategory() throws {
        let required: Set<String> = ["zero", "one", "two", "few", "many", "other"]
        let entries = try plurals("ar")
        XCTAssertFalse(entries.isEmpty, "no Arabic plural entries compiled — check the catalog")

        for (key, entry) in entries {
            for (variable, spec) in entry {
                guard variable != "NSStringLocalizedFormatKey",
                      let spec = spec as? [String: Any],
                      (spec["NSStringFormatSpecTypeKey"] as? String) == "NSStringPluralRuleType"
                else { continue }

                let defined = Set(spec.keys).intersection(required)
                XCTAssertEqual(
                    defined, required,
                    "'\(key)' is missing the Arabic plural categories "
                    + "\(required.subtracting(defined).sorted()) — those counts would fall "
                    + "through to 'other' and read wrong"
                )
            }
        }
    }

    /// Every plural key exists in English too, with at least `one` and `other`.
    func testEnglishPluralsAreComplete() throws {
        let arabicPlurals = try plurals("ar")
        let englishPlurals = try plurals("en")

        for key in arabicPlurals.keys {
            guard let entry = englishPlurals[key] else {
                XCTFail("'\(key)' is a plural in Arabic but not in English")
                continue
            }
            for (variable, spec) in entry {
                guard variable != "NSStringLocalizedFormatKey",
                      let spec = spec as? [String: Any],
                      (spec["NSStringFormatSpecTypeKey"] as? String) == "NSStringPluralRuleType"
                else { continue }
                XCTAssertNotNil(spec["one"], "'\(key)' has no English 'one' form")
                XCTAssertNotNil(spec["other"], "'\(key)' has no English 'other' form")
            }
        }
    }

    // MARK: - Source ↔ catalog agreement

    /// Every key the Swift source asks for exists in the catalog, and every key
    /// in the catalog is asked for by something.
    ///
    /// Scans the checked-out source, located from `#filePath`, so this only runs
    /// on a machine that has the repo. It is the check that catches a key
    /// renamed in one place and not the other — which a compiler cannot see,
    /// because both sides are strings.
    func testEveryKeyUsedInSourceExistsAndEveryCatalogKeyIsUsed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sila")

        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("source tree not reachable from this machine")
        }

        var used: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A file that never mentions `L10n` cannot reference a catalog key,
            // whatever its string literals happen to look like. This is what
            // keeps the keychain's account names — `"auth.token"`, `"auth.user"`
            // — out of the scan: they are storage identifiers that have been on
            // real devices since Phase 1, and they are dotted and lower-camel by
            // coincidence, not because anybody meant them as copy.
            guard source.contains("L10n.") else { continue }
            used.formUnion(Self.keysReferenced(in: source))
        }

        XCTAssertFalse(used.isEmpty, "found no L10n call sites — the scanner is broken")

        let catalog = try allKeys("en")

        let undefined = used.subtracting(catalog).sorted()
        XCTAssertTrue(
            undefined.isEmpty,
            "\(undefined.count) key(s) are referenced in code but absent from the catalog, "
            + "so they would render as their own key: \(undefined.prefix(30).joined(separator: ", "))"
        )

        let unused = catalog.subtracting(used).sorted()
        XCTAssertTrue(
            unused.isEmpty,
            "\(unused.count) key(s) are in the catalog but referenced by nothing — "
            + "dead copy that a translator will still be asked to maintain: "
            + "\(unused.prefix(30).joined(separator: ", "))"
        )
    }

    /// Every catalog key referenced anywhere in the module's source.
    ///
    /// Matches any string literal shaped like a key and prefixed with one of the
    /// catalog's namespaces, rather than only the literals sitting directly
    /// inside an `L10n.t(` call. Keys reach the lookup through ternaries
    /// (`L10n.t(isOn ? "a" : "b")`), through computed properties that return a
    /// key, and across line breaks — a scanner that only understood the direct
    /// form reported nine tenths of the catalog as dead.
    static func keysReferenced(in source: String) -> Set<String> {
        var keys: Set<String> = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Doc comments name keys while explaining them; they are not uses.
            if trimmed.hasPrefix("//") { continue }
            for match in Self.keyPattern.matches(
                in: String(line),
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                let key = String(line[range])
                if Self.namespaces.contains(where: key.hasPrefix) { keys.insert(key) }
            }
        }
        return keys
    }

    /// The catalog's top-level namespaces. A dotted literal outside all of them
    /// is an SF Symbol, a keychain key or a reverse-DNS identifier.
    static let namespaces = [
        "account.", "app.", "auth.", "biometrics.", "common.", "composer.",
        "ds.", "error.", "feed.", "format.", "notifications.", "post.",
        "preferences.", "profile.", "rooms.", "safety.", "search."
    ]

    static let keyPattern = try! NSRegularExpression(
        pattern: "\"((?:[a-z][A-Za-z0-9]*)(?:\\.[A-Za-z0-9]+){1,5})\""
    )
}
