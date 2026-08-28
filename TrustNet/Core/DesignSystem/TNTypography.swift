import SwiftUI

/// TrustNet's type ramp.
///
/// Three families, each with a fixed job:
/// * **Display** — SF Pro Display at weight 700/800. Screen titles and wordmarks.
/// * **Body** — SF Pro Text at weight 300/400/500. Everything a user reads.
/// * **Mono** — SF Mono. IDs, hashes, OTP digits and timestamps, so glyphs
///   line up in columns and `0`/`O` never get confused.
///
/// All fonts are built with `Font.system(..., design:)` so Dynamic Type still
/// scales them; nothing here is a fixed-point font.
public enum TNFont {

    // MARK: - Display (SF Pro Display, 700/800)

    /// 34pt heavy — splash wordmark and hero headlines.
    public static let displayXL = Font.system(size: 34, weight: .heavy, design: .default)
    /// 28pt bold — screen titles.
    public static let displayL = Font.system(size: 28, weight: .bold, design: .default)
    /// 22pt bold — section headings.
    public static let displayM = Font.system(size: 22, weight: .bold, design: .default)

    // MARK: - Body (SF Pro Text, 300/400/500)

    /// 17pt medium — button labels and emphasised rows.
    public static let bodyEmphasis = Font.system(size: 17, weight: .medium, design: .default)
    /// 17pt regular — default reading size.
    public static let body = Font.system(size: 17, weight: .regular, design: .default)
    /// 15pt light — long supporting paragraphs.
    public static let bodyLight = Font.system(size: 15, weight: .light, design: .default)
    /// 13pt regular — field labels, captions, fine print.
    public static let caption = Font.system(size: 13, weight: .regular, design: .default)
    /// 11pt medium — badges and chips.
    public static let micro = Font.system(size: 11, weight: .medium, design: .default)

    // MARK: - Mono (SF Mono)

    /// 15pt monospaced — IDs, hashes, countdowns.
    public static let mono = Font.system(size: 15, weight: .regular, design: .monospaced)
    /// 26pt semibold monospaced — OTP digit boxes.
    public static let monoLarge = Font.system(size: 26, weight: .semibold, design: .monospaced)
}

/// Layout constants shared by every TrustNet component.
///
/// Spacing is an 4pt-based ramp; radii are deliberately small and clinical
/// (this is a terminal, not a toy).
public enum TNSpacing {
    /// 4pt
    public static let xs: CGFloat = 4
    /// 8pt
    public static let sm: CGFloat = 8
    /// 12pt
    public static let md: CGFloat = 12
    /// 16pt — the default gutter and screen inset.
    public static let lg: CGFloat = 16
    /// 24pt
    public static let xl: CGFloat = 24
    /// 32pt
    public static let xxl: CGFloat = 32
}

/// Corner radii shared by every TrustNet component.
public enum TNRadius {
    /// 6pt — chips and badges.
    public static let sm: CGFloat = 6
    /// 10pt — buttons and fields.
    public static let md: CGFloat = 10
    /// 14pt — cards.
    public static let lg: CGFloat = 14
    /// 20pt — sheets and large containers.
    public static let xl: CGFloat = 20
}

#Preview("Typography") {
    VStack(alignment: .leading, spacing: TNSpacing.md) {
        Text("TrustNet").font(TNFont.displayXL)
        Text("Display L").font(TNFont.displayL)
        Text("Display M").font(TNFont.displayM)
        Text("Body emphasis").font(TNFont.bodyEmphasis)
        Text("Body").font(TNFont.body)
        Text("Body light").font(TNFont.bodyLight)
        Text("Caption").font(TNFont.caption)
        Text("MICRO").font(TNFont.micro)
        Text("0123-4567-89AB").font(TNFont.mono)
        Text("482913").font(TNFont.monoLarge)
    }
    .foregroundStyle(TNColor.textPrimary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
    .background(TNColor.background)
}
