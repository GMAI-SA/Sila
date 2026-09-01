import SwiftUI

/// Icon + title + subtitle + optional CTA. **Component 12 of 13.**
///
/// Used wherever a list has nothing in it, a request failed, or a flow reached
/// a dead end. The whole block is a single accessibility element so VoiceOver
/// reads the explanation as one sentence rather than three fragments.
///
/// ```swift
/// SLEmptyState(
///     icon: "tray",
///     title: "Nothing here yet",
///     subtitle: "Posts you bookmark will show up here.",
///     actionTitle: "Explore",
///     action: { router.openExplore() }
/// )
/// ```
public struct SLEmptyState: View {

    private let icon: String
    private let title: String
    private let subtitle: String?
    private let tint: Color
    private let actionTitle: String?
    private let action: (() -> Void)?

    /// Creates an empty state.
    /// - Parameters:
    ///   - icon: SF Symbol name.
    ///   - title: Short headline.
    ///   - subtitle: One or two sentences of explanation.
    ///   - tint: Icon colour. Defaults to the brand blue.
    ///   - actionTitle: Label for the optional CTA.
    ///   - action: CTA handler. The CTA only renders when both this and `actionTitle` are set.
    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        tint: Color = SLColor.primary,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: SLSpacing.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(tint)
            }

            VStack(spacing: SLSpacing.xs) {
                Text(title)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                if let subtitle {
                    Text(subtitle)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text([title, subtitle].compactMap { $0 }.joined(separator: ". ")))
            .accessibilityHint(Text(L10n.t("ds.emptyState.hint")))

            if let actionTitle, let action {
                SLButton(actionTitle, variant: .secondary, size: .compact, action: action)
                    .frame(maxWidth: 220)
                    .padding(.top, SLSpacing.xs)
            }
        }
        .padding(SLSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("SLEmptyState") {
    VStack {
        SLEmptyState(
            icon: "hourglass",
            title: "Under review",
            subtitle: "A human reviewer is checking your documents. This usually takes a few hours.",
            actionTitle: "Refresh",
            action: {}
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
