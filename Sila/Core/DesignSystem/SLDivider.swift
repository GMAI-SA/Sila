import SwiftUI

/// A gradient horizontal rule. **Component 10 of 13.**
///
/// Fades to transparent at both ends so it reads as a soft separation rather
/// than a hard box edge. Supply `text` to get a centred "or" style divider.
///
/// ```swift
/// SLDivider(text: "or")
/// ```
public struct SLDivider: View {

    private let text: String?
    private let tint: Color

    /// Creates a divider.
    /// - Parameters:
    ///   - text: Optional centred caption.
    ///   - tint: Colour of the rule. Defaults to the brand blue.
    public init(text: String? = nil, tint: Color = SLColor.primary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let text {
                HStack(spacing: SLSpacing.md) {
                    rule
                    Text(text.uppercased())
                        .font(SLFont.micro)
                        .tracking(1)
                        .foregroundStyle(SLColor.textMuted)
                    rule
                }
            } else {
                rule
            }
        }
        .accessibilityHidden(true)
    }

    private var rule: some View {
        LinearGradient(
            colors: [.clear, tint.opacity(0.55), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }
}

#Preview("SLDivider") {
    VStack(spacing: SLSpacing.xl) {
        SLDivider()
        SLDivider(text: "or")
        SLDivider(text: "danger zone", tint: SLColor.danger)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
