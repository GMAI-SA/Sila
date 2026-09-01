import SwiftUI

/// A determinate progress track with an animated gradient fill. **Component 7 of 13.**
///
/// Used for the registration password-strength meter and for multi-step
/// wizards. The fill animates whenever `value` changes, and an optional tint
/// override lets callers colour-code semantic states (weak password = red).
///
/// ```swift
/// SLProgressBar(value: strength.fraction, tint: strength.color, label: strength.title)
/// ```
public struct SLProgressBar: View {

    private let value: Double
    private let tint: Color?
    private let height: CGFloat
    private let label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates a progress bar.
    /// - Parameters:
    ///   - value: Progress in `0...1`. Values outside the range are clamped.
    ///   - tint: Solid colour override. `nil` uses the brand gradient.
    ///   - height: Track thickness. Defaults to 6pt.
    ///   - label: Caption drawn to the right of the track and read by VoiceOver.
    public init(value: Double, tint: Color? = nil, height: CGFloat = 6, label: String? = nil) {
        self.value = min(max(value, 0), 1)
        self.tint = tint
        self.height = height
        self.label = label
    }

    public var body: some View {
        HStack(spacing: SLSpacing.sm) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SLColor.surface2)
                    Capsule()
                        .fill(fillStyle)
                        .frame(width: max(0, geo.size.width * value))
                }
            }
            .frame(height: height)

            if let label {
                Text(label)
                    .font(SLFont.micro)
                    .foregroundStyle(tint ?? SLColor.textSecondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label ?? L10n.t("ds.progressBar.defaultLabel")))
        .accessibilityHint(Text(L10n.t("ds.progressBar.hint")))
        .accessibilityValue(Text(L10n.t("ds.progressBar.percentValue", SLFormat.number(Int(value * 100)))))
    }

    /// Erased so the track can be either a solid tint or the brand gradient.
    private var fillStyle: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(SLColor.brandGradient)
    }
}

#Preview("SLProgressBar") {
    VStack(spacing: SLSpacing.lg) {
        SLProgressBar(value: 0.25, tint: SLColor.danger, label: "Weak")
        SLProgressBar(value: 0.5, tint: SLColor.warning, label: "Fair")
        SLProgressBar(value: 0.75, tint: SLColor.primary, label: "Good")
        SLProgressBar(value: 1.0, tint: SLColor.secondary, label: "Strong")
        SLProgressBar(value: 0.66, height: 10)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
