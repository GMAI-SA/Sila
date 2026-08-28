import SwiftUI

/// A small status pill. **Component 4 of 13.**
///
/// Badges state a fact about an entity (verified, premium, blocked). They are
/// never interactive — use ``SLChip`` for anything tappable.
///
/// ```swift
/// SLBadge("Verified", style: .verified, icon: "checkmark.seal.fill")
/// ```
public struct SLBadge: View {

    /// Semantic colouring of a ``SLBadge``.
    public enum Style: Sendable {
        /// Electric blue — identity confirmed.
        case verified
        /// Gold — paying member.
        case premium
        /// Rose — a problem the user must resolve.
        case danger
        /// Amber — a caution that is not yet a failure.
        case warning
        /// Muted grey — informational, no judgement.
        case neutral

        var tint: Color {
            switch self {
            case .verified: return SLColor.primary
            case .premium: return Color(tnHex: 0xFFC24B)
            case .danger: return SLColor.danger
            case .warning: return SLColor.warning
            case .neutral: return SLColor.textSecondary
            }
        }
    }

    private let text: String
    private let style: Style
    private let icon: String?

    /// Creates a badge.
    /// - Parameters:
    ///   - text: Label, rendered upper-case.
    ///   - style: Semantic colouring.
    ///   - icon: Optional SF Symbol drawn before the label.
    public init(_ text: String, style: Style = .neutral, icon: String? = nil) {
        self.text = text
        self.style = style
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            Text(text.uppercased()).font(SLFont.micro).tracking(0.6)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, SLSpacing.sm)
        .padding(.vertical, 4)
        .background(style.tint.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(style.tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(text) badge"))
        .accessibilityHint(Text("Status indicator"))
    }
}

#Preview("SLBadge") {
    VStack(spacing: SLSpacing.md) {
        SLBadge("Verified", style: .verified, icon: "checkmark.seal.fill")
        SLBadge("Premium", style: .premium, icon: "star.fill")
        SLBadge("Rejected", style: .danger, icon: "xmark.octagon.fill")
        SLBadge("Action required", style: .warning, icon: "exclamationmark.triangle.fill")
        SLBadge("Unstarted", style: .neutral)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
