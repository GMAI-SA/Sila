import SwiftUI

/// ISO-3166 alpha-2 country codes → flag emoji and localised names.
///
/// On TrustNet a country code is not decoration: it comes from the Nafath
/// nationality record or the issuing country of a verified ID document, never
/// from an IP address. Every helper here therefore returns `nil` rather than a
/// guess — a code we cannot recognise renders as nothing at all.
public enum CountryCode {

    /// Uppercases and validates a raw code.
    /// - Parameter code: e.g. `"sa"`, `"SA"`, `nil`.
    /// - Returns: The canonical two-letter code, or `nil` if it is absent,
    ///   malformed, or not a real ISO region.
    public static func normalised(_ code: String?) -> String? {
        guard let code else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 2,
              trimmed.unicodeScalars.allSatisfy({ ("A"..."Z").contains(String($0)) }),
              isoAlpha2Codes.contains(trimmed)
        else { return nil }
        return trimmed
    }

    /// Real ISO-3166-1 alpha-2 codes, as a set because this is consulted once
    /// per author per render.
    ///
    /// `Locale.Region.isISORegion` is deliberately **not** used: it answers
    /// `true` for CLDR extras such as `ZZ` ("Unknown Region"), `EU` and `UK`,
    /// which would let a placeholder render as a real flag.
    private static let isoAlpha2Codes: Set<String> = Set(
        Locale.Region.isoRegions.map(\.identifier)
    )

    /// The flag emoji for a country code.
    /// - Returns: e.g. `"🇸🇦"`, or `nil` when ``normalised(_:)`` rejects the code.
    public static func flag(_ code: String?) -> String? {
        guard let code = normalised(code) else { return nil }
        // Regional indicator symbols live at U+1F1E6 ("A") through U+1F1FF ("Z").
        let base: UInt32 = 0x1F1E6
        let asciiA: UInt32 = 65
        var flag = ""
        for scalar in code.unicodeScalars {
            guard let indicator = Unicode.Scalar(base + scalar.value - asciiA) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// The country's name in the user's language.
    /// - Returns: e.g. `"Saudi Arabia"`, or `nil` for an unrecognised code.
    public static func name(_ code: String?, locale: Locale = .current) -> String? {
        guard let code = normalised(code) else { return nil }
        return locale.localizedString(forRegionCode: code)
    }

    /// What VoiceOver should say for a verified country flag.
    /// - Returns: e.g. `"Identity verified in Saudi Arabia"`, or `nil`.
    public static func accessibilityLabel(_ code: String?, locale: Locale = .current) -> String? {
        guard let code = normalised(code) else { return nil }
        return "Identity verified in \(name(code, locale: locale) ?? code)"
    }
}

/// The country-verified flag badge. **The product's core differentiator.**
///
/// Renders **nothing** when the code is absent or unrecognised. An unverified
/// account genuinely has no country, and inventing one — from an IP address,
/// a phone prefix, a locale — is exactly the thing TrustNet exists not to do.
///
/// ```swift
/// TNCountryBadge(countryCode: post.author.countryCode)
/// ```
public struct TNCountryBadge: View {

    /// How much of the badge to show.
    public enum Size {
        /// Flag only — for dense rows like a post header.
        case compact
        /// Flag plus the code, e.g. `🇸🇦 SA` — for profile headers.
        case regular

        var font: Font {
            switch self {
            // Deliberately a shade larger than the surrounding caption text:
            // the flag is the product's differentiator, not a footnote.
            case .compact: return .system(size: 15)
            case .regular: return .system(size: 17)
            }
        }
    }

    private let countryCode: String?
    private let size: Size

    /// Creates a badge.
    /// - Parameters:
    ///   - countryCode: ISO-3166 alpha-2 from the *verified identity*, or `nil`.
    ///   - size: Visual density. Defaults to ``Size/compact``.
    public init(countryCode: String?, size: Size = .compact) {
        self.countryCode = countryCode
        self.size = size
    }

    public var body: some View {
        if let code = CountryCode.normalised(countryCode), let flag = CountryCode.flag(code) {
            HStack(spacing: 3) {
                Text(flag)
                    .font(size.font)
                if size == .regular {
                    Text(code)
                        .font(TNFont.micro)
                        .tracking(0.5)
                        .foregroundStyle(TNColor.secondary)
                }
            }
            .padding(.horizontal, size == .regular ? TNSpacing.sm : 0)
            .padding(.vertical, size == .regular ? 2 : 0)
            .background {
                if size == .regular {
                    Capsule().fill(TNColor.secondary.opacity(0.12))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(CountryCode.accessibilityLabel(code) ?? code))
        }
    }
}

#Preview("TNCountryBadge") {
    VStack(alignment: .leading, spacing: TNSpacing.lg) {
        HStack(spacing: TNSpacing.md) {
            TNCountryBadge(countryCode: "SA")
            TNCountryBadge(countryCode: "jp")
            TNCountryBadge(countryCode: "BR")
        }
        TNCountryBadge(countryCode: "SA", size: .regular)
        HStack {
            Text("Unverified author:").font(TNFont.caption).foregroundStyle(TNColor.textSecondary)
            TNCountryBadge(countryCode: nil)
            Text("(renders nothing)").font(TNFont.micro).foregroundStyle(TNColor.textMuted)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TNColor.background)
    .preferredColorScheme(.dark)
}
