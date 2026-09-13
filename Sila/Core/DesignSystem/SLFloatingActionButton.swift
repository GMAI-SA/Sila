import SwiftUI
import UIKit

/// One choice in the floating button's held-open menu.
public struct SLFloatingActionOption: Identifiable, Sendable {
    /// What sits in the option's circle: a symbol, or a short word — "GIF"
    /// has no symbol and should not pretend to.
    public enum Glyph: Sendable, Equatable {
        case symbol(String)
        case text(String)
    }

    public let id: String
    public let title: String
    public let glyph: Glyph
    public let action: @MainActor () -> Void

    public init(id: String, title: String, glyph: Glyph, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.glyph = glyph
        self.action = action
    }
}

/// The word "GIF" drawn as a glyph, for the places a symbol would lie.
public struct SLGifGlyph: View {
    private let size: CGFloat

    public init(size: CGFloat = 11) { self.size = size }

    public var body: some View {
        Text("GIF")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// The round button in the bottom corner: tap for the one thing this screen
/// starts, hold for everything the app can start.
///
/// Sits at the physical bottom-right whatever the language — a thumb is a
/// thumb — while the labels inside the menu keep the interface's own
/// direction. Holding opens the menu with a tick of haptics; tapping the dim
/// behind it, or any choice, closes it.
@MainActor
public struct SLFloatingActionButton: View {

    private let icon: String
    private let accessibilityLabel: String
    private let accessibilityHint: String
    private let options: [SLFloatingActionOption]
    private let onTap: @MainActor () -> Void
    private let onExpand: (@MainActor () -> Void)?

    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    /// - Parameters:
    ///   - icon: The symbol on the button.
    ///   - accessibilityLabel: What VoiceOver calls the button.
    ///   - accessibilityHint: Says that holding opens more.
    ///   - options: The held-open menu, top to bottom. Empty means no menu.
    ///   - onExpand: Called when the menu opens (for analytics).
    ///   - onTap: The primary action.
    public init(
        icon: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        options: [SLFloatingActionOption] = [],
        onExpand: (@MainActor () -> Void)? = nil,
        onTap: @escaping @MainActor () -> Void
    ) {
        self.icon = icon
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.options = options
        self.onExpand = onExpand
        self.onTap = onTap
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isExpanded {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { collapse() }
                    .transition(.opacity)
                    .accessibilityLabel(Text(L10n.t("feed.fab.dismiss.a11yLabel")))
                    .accessibilityAddTraits(.isButton)
            }

            VStack(alignment: .trailing, spacing: SLSpacing.md) {
                if isExpanded {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        optionRow(option)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.85, anchor: .bottomTrailing))
                            )
                            .animation(
                                reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78).delay(Double(options.count - index) * 0.03),
                                value: isExpanded
                            )
                    }
                }

                mainButton
            }
            .padding(.trailing, SLSpacing.lg)
            .padding(.bottom, SLSpacing.lg)
        }
        // The physical corner, in every language.
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var mainButton: some View {
        ZStack {
            Circle()
                .fill(SLColor.primary)
                .shadow(color: SLColor.primary.opacity(0.35), radius: 12, x: 0, y: 6)
            Image(systemName: isExpanded ? "xmark" : icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(isExpanded && !reduceMotion ? 90 : 0))
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
        .scaleEffect(isExpanded && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
        .onTapGesture {
            if isExpanded { collapse() } else { onTap() }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            guard !options.isEmpty, !isExpanded else { return }
            expand()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(accessibilityHint))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.t("feed.fab.more.a11yAction"))) { expand() }
        .accessibilityIdentifier("feed.fab")
    }

    private func optionRow(_ option: SLFloatingActionOption) -> some View {
        Button {
            collapse()
            option.action()
        } label: {
            HStack(spacing: SLSpacing.sm) {
                Text(option.title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .padding(.horizontal, SLSpacing.md)
                    .padding(.vertical, SLSpacing.sm)
                    .background(SLColor.surface1)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                    // The words keep the interface's direction; only the
                    // corner is fixed.
                    .environment(\.layoutDirection, direction)

                ZStack {
                    Circle().fill(SLColor.surface1)
                    switch option.glyph {
                    case let .symbol(name):
                        Image(systemName: name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SLColor.primary)
                    case let .text(word):
                        Text(word)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(SLColor.primary)
                    }
                }
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityIdentifier("feed.fab.\(option.id)")
    }

    private func expand() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onExpand?()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) { isExpanded = true }
    }

    private func collapse() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) { isExpanded = false }
    }
}
