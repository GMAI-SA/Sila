import Foundation

/// Numbers, dates and durations, formatted for whoever is reading them.
///
/// Every number that reaches a screen comes through here rather than through
/// `"\(value)"`. String interpolation of an `Int` produces an unlocalised,
/// ungrouped, direction-naive token — `1234567` — which is wrong in both
/// languages this app ships and actively hostile inside a right-to-left line,
/// where an unmarked run of digits can drag neighbouring punctuation to the
/// wrong end of the sentence.
///
/// **Digits stay Western.** See ``L10n/formattingLocale``.
public enum SLFormat {

    // MARK: - Whole numbers

    /// A grouped integer — `1234567` → `"1,234,567"`.
    public static func number(_ value: Int, locale: Locale? = nil) -> String {
        let formatter = numberFormatter(for: locale ?? L10n.formattingLocale)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The social-feed abbreviation — `1200` → `"1.2K"`, `3_400_000` → `"3.4M"`.
    ///
    /// The suffixes are catalog keys, not literals: Arabic abbreviates
    /// thousands as ألف and millions as مليون, and an Arabic feed showing
    /// "1.2K" is a feed that was translated everywhere except the part with the
    /// numbers in it.
    public static func compactCount(_ value: Int, locale: Locale? = nil) -> String {
        let locale = locale ?? L10n.formattingLocale
        switch abs(value) {
        case ..<1_000:
            return number(value, locale: locale)
        case ..<1_000_000:
            return abbreviated(Double(value) / 1_000, key: "format.count.thousands", locale: locale)
        default:
            return abbreviated(Double(value) / 1_000_000, key: "format.count.millions", locale: locale)
        }
    }

    private static func abbreviated(_ scaled: Double, key: String, locale: Locale) -> String {
        let formatter = decimalFormatter(for: locale, fractionDigits: scaled < 10 ? 1 : 0)
        let rendered = formatter.string(from: NSNumber(value: scaled)) ?? String(Int(scaled))
        return L10n.t(key, rendered)
    }

    // MARK: - Dates

    /// A date with no time — `"12 Aug 2025"` / `"١٢ أغسطس ٢٠٢٥"` with Western
    /// digits, so `"12 أغسطس 2025"`.
    public static func date(_ date: Date, locale: Locale? = nil) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(locale ?? L10n.formattingLocale)
        )
    }

    /// A date and a time of day.
    public static func dateTime(_ date: Date, locale: Locale? = nil) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(locale ?? L10n.formattingLocale)
        )
    }

    /// Month and year only — the "Joined March 2025" line.
    public static func monthAndYear(_ date: Date, locale: Locale? = nil) -> String {
        date.formatted(
            Date.FormatStyle()
                .month(.wide)
                .year()
                .locale(locale ?? L10n.formattingLocale)
        )
    }

    /// Long-form relative time, as VoiceOver reads it — `"2 hours ago"` /
    /// `"قبل ساعتين"`.
    ///
    /// `RelativeDateTimeFormatter` carries CLDR's Arabic forms, including the
    /// dual (`ساعتين`) that no hand-written ternary in this codebase would have
    /// produced.
    public static func relative(_ date: Date, to reference: Date = Date(), locale: Locale? = nil) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale ?? L10n.formattingLocale
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// A countdown in seconds, for the OTP resend timer — `"0:45"`.
    ///
    /// Deliberately not `RelativeDateTimeFormatter`: this is a clock, and a
    /// clock reads left-to-right in Arabic too.
    public static func seconds(_ seconds: Int, locale: Locale? = nil) -> String {
        let locale = locale ?? L10n.formattingLocale
        let clamped = max(0, seconds)
        if clamped < 60 { return number(clamped, locale: locale) }
        let minutes = clamped / 60
        let remainder = clamped % 60
        let formatter = numberFormatter(for: locale)
        formatter.minimumIntegerDigits = 2
        let paddedSeconds = formatter.string(from: NSNumber(value: remainder)) ?? String(remainder)
        return "\(number(minutes, locale: locale)):\(paddedSeconds)"
    }

    /// A byte size — `"4.2 MB"`.
    public static func fileSize(_ bytes: Int, locale: Locale? = nil) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - Formatters

    /// Grouped-integer formatters are expensive to build and are hit once per
    /// counter per frame; one per locale is kept.
    private static let cache = NSCache<NSString, NumberFormatter>()

    private static func numberFormatter(for locale: Locale) -> NumberFormatter {
        let key = "int-\(locale.identifier)" as NSString
        if let cached = cache.object(forKey: key) { return copy(cached) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        cache.setObject(formatter, forKey: key)
        return copy(formatter)
    }

    private static func decimalFormatter(for locale: Locale, fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        // 1.05K would round to 1.1K and claim fifty followers nobody has; the
        // abbreviation always rounds toward the number that is actually true.
        formatter.roundingMode = .down
        return formatter
    }

    /// `NumberFormatter` is a reference type and callers mutate
    /// `minimumIntegerDigits`, so the cache hands out copies.
    private static func copy(_ formatter: NumberFormatter) -> NumberFormatter {
        let duplicate = NumberFormatter()
        duplicate.numberStyle = formatter.numberStyle
        duplicate.locale = formatter.locale
        duplicate.maximumFractionDigits = formatter.maximumFractionDigits
        return duplicate
    }
}
