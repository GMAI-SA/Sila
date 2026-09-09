import SwiftUI

/// A raised surface container. **Component 3 of 13.**
///
/// When an `onTap` handler is supplied the card becomes a button and gains a
/// press animation (`scaleEffect` + a brighter border), which is Sila's
/// stand-in for hover on a touch device.
///
/// ```swift
/// SLCard(onTap: { router.open(space) }) {
///     Text("Live now").font(SLFont.bodyEmphasis)
/// }
/// ```
public struct SLCard<Content: View>: View {

    private let padding: CGFloat
    private let isHighlighted: Bool
    private let accessibilityLabelText: String?
    private let accessibilityHintText: String?
    private let onTap: (() -> Void)?
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    /// Creates a card.
    /// - Parameters:
    ///   - padding: Inner inset. Defaults to 16pt.
    ///   - isHighlighted: Draws the brand-coloured border (e.g. a selected tile).
    ///   - accessibilityLabel: Required when `onTap` is set, so the card reads as a control.
    ///   - accessibilityHint: What tapping the card does.
    ///   - onTap: When non-`nil` the card is interactive.
    ///   - content: The card's contents.
    public init(
        padding: CGFloat = SLSpacing.lg,
        isHighlighted: Bool = false,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.isHighlighted = isHighlighted
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityHintText = accessibilityHint
        self.onTap = onTap
        self.content = content()
    }

    public var body: some View {
        surface
            .contentShape(RoundedRectangle(cornerRadius: SLRadius.lg))
            .modifier(TapBehaviour(onTap: onTap, isPressed: $isPressed))
            .modifier(
                CardAccessibility(
                    label: accessibilityLabelText,
                    hint: accessibilityHintText,
                    isInteractive: onTap != nil
                )
            )
    }

    private var surface: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SLColor.surface1)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.lg)
                    .strokeBorder(
                        isHighlighted || isPressed ? SLColor.primary.opacity(0.7) : SLColor.stroke,
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.08), radius: 12, y: 6)
            .scaleEffect(isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isPressed)
    }
}

/// A card that can be tapped, drawn pressed, and **scrolled past**.
///
/// This was a `DragGesture(minimumDistance: 0)` alongside an `onTapGesture`,
/// which is the ordinary way to get a pressed state — and the reason a stack
/// of cards could not be scrolled. A zero-distance drag claims the touch the
/// moment a finger lands, so a scroll that began on a card never reached the
/// scroll view: the profile's settings rows had to be dragged from the gaps
/// between them. A `Button` with a style that reports its own press state
/// gets the highlight for free and leaves the pan where it belongs, because
/// SwiftUI already knows how to defer a button's press inside a scroll view.
private struct TapBehaviour: ViewModifier {
    let onTap: (() -> Void)?
    @Binding var isPressed: Bool

    func body(content: Content) -> some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(PressReportingButtonStyle(isPressed: $isPressed))
        } else {
            content
        }
    }
}

/// Hands the button's own press state back to the card, and styles nothing:
/// the card has already drawn itself.
private struct PressReportingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

private struct CardAccessibility: ViewModifier {
    let label: String?
    let hint: String?
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if isInteractive {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(label ?? ""))
                .accessibilityHint(Text(hint ?? L10n.t("ds.card.defaultHint")))
        } else {
            content
        }
    }
}

#Preview("SLCard") {
    VStack(spacing: SLSpacing.md) {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text("Static card").font(SLFont.bodyEmphasis).foregroundStyle(SLColor.textPrimary)
                Text("No tap handler, no press animation.")
                    .font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
            }
        }
        SLCard(
            isHighlighted: true,
            accessibilityLabel: "Passport",
            accessibilityHint: "Selects passport as your document type",
            onTap: {}
        ) {
            Text("Tappable, highlighted").font(SLFont.body).foregroundStyle(SLColor.textPrimary)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
