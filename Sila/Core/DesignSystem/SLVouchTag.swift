import SwiftUI

/// "vouched by @aziz · Saudi Arabia" — the mark of an account that has not
/// verified its own identity but carries a verified member's word
/// (contract v24 §3).
///
/// Built as the deliberate opposite of the seal: a chip, not a badge — it is
/// always a button — with a hairline border, muted text and no fill, where
/// ``SLVerifiedBadge`` is a filled, glowing mark. The glyph is two people
/// joined by a dotted line. Never upper-cased, never truncated to the word
/// alone, never beside a seal or a flag: callers draw it only when
/// `is_verified` is false.
///
/// ```swift
/// SLVouchTag(text: "vouched by @aziz · Saudi Arabia",
///            accessibilityLabel: "Vouched for by @aziz. …") { open() }
/// ```
public struct SLVouchTag: View {

    /// How much of the tag to draw.
    public enum Style: Sendable {
        /// The glyph and the words — post headers, profiles, the room sheet.
        case full
        /// The glyph alone, at 12 pt — the quote card (contract v24 §3.4)
        /// and a listener's 44 pt tile in the room grid, where the words
        /// cannot fit; the participant sheet a tap opens carries them whole.
        /// The label still says everything.
        case iconOnly
    }

    public static let glyph = "person.line.dotted.person.fill"

    private let text: String
    private let accessibilityText: String
    private let style: Style
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - text: The visible words.
    ///   - accessibilityLabel: What VoiceOver says instead.
    ///   - style: Density.
    ///   - action: The tap. `nil` draws the tag inert — a preview, or a
    ///     surface with nowhere to send the explainer.
    public init(text: String, accessibilityLabel: String, style: Style = .full, action: (() -> Void)? = nil) {
        self.text = text
        self.accessibilityText = accessibilityLabel
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button {
            action?()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityHint(Text(action == nil ? "" : L10n.t("ds.vouchTag.hint")))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("vouching.tag")
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .full:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: Self.glyph)
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .font(SLFont.micro)
                    // A long handle wraps onto a second line rather than
                    // cutting the country off: "vouched by @x · Country" is
                    // said whole, or it says something else.
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(SLColor.textSecondary)
            .padding(.horizontal, SLSpacing.sm)
            .padding(.vertical, 2)
            // A capsule on one line, a rounded box on two.
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SLColor.textSecondary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(SLColor.textSecondary.opacity(0.35), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .iconOnly:
            Image(systemName: Self.glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SLColor.textSecondary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
    }
}

#Preview("SLVouchTag") {
    VStack(alignment: .leading, spacing: SLSpacing.md) {
        SLVouchTag(text: "vouched by @aziz · Saudi Arabia", accessibilityLabel: "Vouched for by @aziz", action: {})
        SLVouchTag(text: "vouched by @aziz", accessibilityLabel: "Vouched for by @aziz")
        SLVouchTag(text: "", accessibilityLabel: "Vouched for by @aziz", style: .iconOnly, action: {})
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
    .preferredColorScheme(.dark)
}
