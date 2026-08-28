import SwiftUI

/// A tappable tag / filter pill. **Component 11 of 13.**
///
/// Unlike ``TNBadge`` (which states a fact) a chip is a control: it toggles a
/// filter or removes a tag. Selection is expressed with the brand fill and is
/// mirrored to VoiceOver via `.isSelected`.
///
/// ```swift
/// TNChip("Posts", isSelected: tab == .posts) { tab = .posts }
/// ```
public struct TNChip: View {

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
        HStack(spacing: TNSpacing.xs) {
            Button {
                onTap?()
            } label: {
                HStack(spacing: TNSpacing.xs) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    }
                    Text(title).font(TNFont.caption)
                }
                .foregroundStyle(isSelected ? Color(tnHex: 0x02121C) : TNColor.textSecondary)
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
                        .foregroundStyle(isSelected ? Color(tnHex: 0x02121C) : TNColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(title)"))
                .accessibilityHint(Text("Removes the \(title) tag"))
            }
        }
        .padding(.horizontal, TNSpacing.md)
        .padding(.vertical, TNSpacing.sm)
        .background(isSelected ? AnyShapeStyle(TNColor.brandGradient) : AnyShapeStyle(TNColor.surface2))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.clear : TNColor.stroke,
                lineWidth: 1
            )
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

#Preview("TNChip") {
    VStack(spacing: TNSpacing.md) {
        HStack {
            TNChip("Posts", isSelected: true, onTap: {})
            TNChip("People", onTap: {})
            TNChip("Media", icon: "photo", onTap: {})
        }
        HStack {
            TNChip("#riyadh", onRemove: {}, onTap: {})
            TNChip("#verified", isSelected: true, onRemove: {}, onTap: {})
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TNColor.background)
}
