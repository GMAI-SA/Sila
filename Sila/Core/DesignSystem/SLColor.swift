import SwiftUI

/// The Sila brand palette.
///
/// Sila is **dark-mode first** — the dark values are the canonical brand
/// colours and the light values are derived adaptations. Every colour resolves
/// through ``SLColor/adaptive(dark:light:)`` so a component only has to read
/// `SLColor.background` and the correct value falls out of the environment's
/// `UITraitCollection`.
///
/// ```swift
/// Text("Hello").foregroundStyle(SLColor.textPrimary)
/// ```
public enum SLColor {

    // MARK: - Raw brand values (dark theme = canonical)

    /// Electric Blue — "Trust". `#00A8FF`
    public static let primaryHex = 0x00A8FF
    /// Mint — "Verified". `#00FFC8`
    public static let secondaryHex = 0x00FFC8

    // MARK: - Semantic tokens

    /// Electric Blue `#00A8FF` — primary actions, focus rings, links.
    public static let primary = adaptive(dark: 0x00A8FF, light: 0x0079D6)

    /// Mint `#00FFC8` — verification, success, "this human is real".
    public static let secondary = adaptive(dark: 0x00FFC8, light: 0x00A882)

    /// Rose `#FF4D6D` — destructive actions and hard failures.
    public static let danger = adaptive(dark: 0xFF4D6D, light: 0xD1213F)

    /// Amber `#FFD166` — warnings and "action required" states.
    public static let warning = adaptive(dark: 0xFFD166, light: 0xB07D00)

    /// App canvas `#020509`.
    public static let background = adaptive(dark: 0x020509, light: 0xF5F8FB)

    /// Raised surface, one level above the canvas `#070D14`.
    public static let surface1 = adaptive(dark: 0x070D14, light: 0xFFFFFF)

    /// Raised surface, two levels above the canvas `#0D1A26`.
    public static let surface2 = adaptive(dark: 0x0D1A26, light: 0xE8EEF4)

    /// Highest-contrast body and heading text `#E8F4FF`.
    public static let textPrimary = adaptive(dark: 0xE8F4FF, light: 0x07131E)

    /// Supporting copy, captions, field labels `#7A9AB5`.
    public static let textSecondary = adaptive(dark: 0x7A9AB5, light: 0x4A6478)

    /// De-emphasised text, placeholders, disabled states `#3D5A72`.
    public static let textMuted = adaptive(dark: 0x3D5A72, light: 0x93A8B8)

    /// Hairline strokes around surfaces and fields.
    public static let stroke = adaptive(dark: 0x16283A, light: 0xD3DFE9)

    // MARK: - Gradients

    /// The signature Trust → Verified sweep used on progress bars and dividers.
    public static let brandGradient = LinearGradient(
        colors: [primary, secondary],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Vertical background wash used behind full-screen auth surfaces.
    public static let canvasGradient = LinearGradient(
        colors: [background, surface1, background],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Construction

    /// Builds a `Color` that resolves differently in light and dark mode.
    /// - Parameters:
    ///   - dark: 24-bit RGB value used when `UIUserInterfaceStyle` is `.dark`.
    ///   - light: 24-bit RGB value used in every other case.
    public static func adaptive(dark: Int, light: Int) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: dark)
                : UIColor(rgb: light)
        })
    }
}

extension UIColor {
    /// Creates a colour from a 24-bit `0xRRGGBB` literal.
    fileprivate convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// Creates a colour from a 24-bit `0xRRGGBB` literal.
    public init(tnHex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((tnHex >> 16) & 0xFF) / 255,
            green: Double((tnHex >> 8) & 0xFF) / 255,
            blue: Double(tnHex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            swatch("primary", SLColor.primary)
            swatch("secondary", SLColor.secondary)
            swatch("danger", SLColor.danger)
            swatch("warning", SLColor.warning)
            swatch("background", SLColor.background)
            swatch("surface1", SLColor.surface1)
            swatch("surface2", SLColor.surface2)
            swatch("textPrimary", SLColor.textPrimary)
            swatch("textSecondary", SLColor.textSecondary)
            swatch("textMuted", SLColor.textMuted)
        }
        .padding()
    }
    .background(SLColor.background)
}

@ViewBuilder
private func swatch(_ name: String, _ color: Color) -> some View {
    HStack {
        RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 48, height: 32)
        Text(name).foregroundStyle(SLColor.textPrimary)
    }
}
