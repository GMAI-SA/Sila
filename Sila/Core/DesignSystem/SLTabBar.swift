import SwiftUI

/// One slot in a ``SLTabBar``.
public struct SLTabBarItem<Tab: Hashable>: Identifiable, Sendable where Tab: Sendable {

    /// What activating the slot does.
    public enum Kind: Sendable {
        /// Selects `tab` and swaps the visible screen.
        case tab(Tab)
        /// Runs a one-shot action without changing the selection — the compose
        /// button. Drawn as the raised centre control.
        case action
    }

    public let id: String
    /// SF Symbol shown when the slot is not selected.
    public let icon: String
    /// SF Symbol shown when it is.
    public let selectedIcon: String
    /// Visible caption and accessibility label.
    public let label: String
    /// Accessibility hint.
    public let hint: String
    /// Selection or action.
    public let kind: Kind
    /// An unread count drawn on the icon, or `nil` for no badge.
    ///
    /// Zero draws nothing rather than a `0` bubble: a badge exists to say
    /// something is waiting, and one that says nothing is waiting is noise.
    public let badge: Int?

    /// Creates a tab-bar item.
    public init(
        id: String,
        icon: String,
        selectedIcon: String? = nil,
        label: String,
        hint: String,
        kind: Kind,
        badge: Int? = nil
    ) {
        self.id = id
        self.icon = icon
        self.selectedIcon = selectedIcon ?? icon
        self.label = label
        self.hint = hint
        self.kind = kind
        self.badge = badge
    }

    /// The badge as it is drawn: `nil` below one, and capped so a very large
    /// count cannot widen the slot.
    var badgeText: String? {
        guard let badge, badge > 0 else { return nil }
        return badge > 99 ? "99+" : String(badge)
    }

    /// What VoiceOver adds after the label, e.g. `"3 unread"`.
    var badgeAccessibilityValue: String? {
        guard let badge, badge > 0 else { return nil }
        return badge == 1 ? "1 unread" : "\(badge) unread"
    }
}

/// The app's custom bottom navigation bar. **Design-system component.**
///
/// A hand-rolled bar rather than `TabView`, because the centre compose slot is
/// a raised action button that must *not* change the selection, and the active
/// indicator is a brand-gradient pill that animates between slots.
///
/// ```swift
/// SLTabBar(items: items, selection: $tab) { id in router.showComposerStub() }
/// ```
public struct SLTabBar<Tab: Hashable & Sendable>: View {

    private let items: [SLTabBarItem<Tab>]
    @Binding private var selection: Tab
    private let onAction: (String) -> Void

    @Namespace private var indicator

    /// Creates a tab bar.
    /// - Parameters:
    ///   - items: Slots, left to right.
    ///   - selection: The bound selected tab.
    ///   - onAction: Called with the item id when an ``SLTabBarItem/Kind/action`` slot is tapped.
    public init(
        items: [SLTabBarItem<Tab>],
        selection: Binding<Tab>,
        onAction: @escaping (String) -> Void
    ) {
        self.items = items
        self._selection = selection
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(items) { item in
                switch item.kind {
                case let .tab(tab):
                    tabSlot(item, tab: tab)
                case .action:
                    actionSlot(item)
                }
            }
        }
        .padding(.top, SLSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                SLColor.surface1
                Rectangle().fill(SLColor.stroke).frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
    }

    private func tabSlot(_ item: SLTabBarItem<Tab>, tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(SLColor.primary.opacity(0.15))
                            .frame(width: 44, height: 28)
                            .matchedGeometryEffect(id: "tn.tabbar.indicator", in: indicator)
                    }
                    Image(systemName: isSelected ? item.selectedIcon : item.icon)
                        .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? SLColor.primary : SLColor.textSecondary)

                    if let text = item.badgeText {
                        badge(text)
                    }
                }
                .frame(height: 28)

                Text(item.label)
                    .font(SLFont.micro)
                    .foregroundStyle(isSelected ? SLColor.primary : SLColor.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, SLSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.label))
        .accessibilityValue(Text(item.badgeAccessibilityValue ?? ""))
        .accessibilityHint(Text(item.hint))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The unread bubble. Hidden from VoiceOver because the same number is
    /// already the slot's accessibility value — announcing it twice is how a
    /// badge turns into a stutter.
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(SLColor.secondary))
            .overlay(Capsule().strokeBorder(SLColor.surface1, lineWidth: 1.5))
            .offset(x: 14, y: -10)
            .accessibilityHidden(true)
    }

    private func actionSlot(_ item: SLTabBarItem<Tab>) -> some View {
        Button {
            onAction(item.id)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(SLColor.brandGradient)
                        .frame(width: 42, height: 42)
                        .shadow(color: SLColor.primary.opacity(0.35), radius: 8, y: 2)
                    Image(systemName: item.icon)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.black)
                }
                .frame(height: 28)
                .offset(y: -6)

                Text(item.label)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
                    .lineLimit(1)
                    .offset(y: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, SLSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.label))
        .accessibilityHint(Text(item.hint))
    }
}

#Preview("SLTabBar") {
    struct Demo: View {
        @State private var tab = "home"
        var body: some View {
            VStack {
                Spacer()
                SLTabBar(
                    items: [
                        .init(id: "home", icon: "house", selectedIcon: "house.fill",
                              label: "Home", hint: "Shows your feeds", kind: .tab("home")),
                        .init(id: "explore", icon: "magnifyingglass",
                              label: "Explore", hint: "Search Sila", kind: .tab("explore")),
                        .init(id: "compose", icon: "plus",
                              label: "Post", hint: "Writes a new post", kind: .action),
                        .init(id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                              label: "Alerts", hint: "Shows your notifications", kind: .tab("notifications")),
                        .init(id: "profile", icon: "person", selectedIcon: "person.fill",
                              label: "Profile", hint: "Shows your profile", kind: .tab("profile"))
                    ],
                    selection: $tab,
                    onAction: { _ in }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SLColor.background)
        }
    }
    return Demo().preferredColorScheme(.dark)
}
