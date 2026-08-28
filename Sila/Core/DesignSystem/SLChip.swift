import SwiftUI

/// A tappable tag / filter pill. **Component 11 of 13.**
///
/// Unlike ``SLBadge`` (which states a fact) a chip is a control: it toggles a
/// filter or removes a tag. Selection is expressed with the brand fill and is
/// mirrored to VoiceOver via `.isSelected`.
///
/// ```swift
/// SLChip("Posts", isSelected: tab == .posts) { tab = .posts }
/// ```
public struct SLChip: View {

    private let title: String
    private let icon: String?
    private let isSelected: Bool
    private let accessibilityHintText: String?
    private let onTap: (() -> Void)?
    private let onRemove: (() -> Void)?

    /// Creates a chip.
    /// - Parameters:
    ///   - title: Visible label.
    ///   - icon: Optional leading SF Symbol.
    ///   - isSelected: Applies the selected treatment.
    ///   - accessibilityHint: What tapping does.
    ///   - onRemove: When set, a trailing ⨉ button is shown.
    ///   - onTap: Primary tap action.
    public init(
        _ title: String,
        icon: String? = nil,
        isSelected: Bool = false,
        accessibilityHint: String? = nil,
        onRemove: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.accessibilityHintText = accessibilityHint
        self.onRemove = onRemove
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: SLSpacing.xs) {
            Button {
                onTap?()
            } label: {
                HStack(spacing: SLSpacing.xs) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    }
                    Text(title).font(SLFont.caption)
                }
                .foregroundStyle(isSelected ? Color(tnHex: 0x02121C) : SLColor.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(accessibilityHintText ?? "Filters by \(title)"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? Color(tnHex: 0x02121C) : SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(title)"))
                .accessibilityHint(Text("Removes the \(title) tag"))
            }
        }
        .padding(.horizontal, SLSpacing.md)
        .padding(.vertical, SLSpacing.sm)
        .background(isSelected ? AnyShapeStyle(SLColor.brandGradient) : AnyShapeStyle(SLColor.surface2))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.clear : SLColor.stroke,
                lineWidth: 1
            )
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

#Preview("SLChip") {
    VStack(spacing: SLSpacing.md) {
        HStack {
            SLChip("Posts", isSelected: true, onTap: {})
            SLChip("People", onTap: {})
            SLChip("Media", icon: "photo", onTap: {})
        }
        HStack {
            SLChip("#riyadh", onRemove: {}, onTap: {})
            SLChip("#verified", isSelected: true, onRemove: {}, onTap: {})
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
