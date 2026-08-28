import SwiftUI

/// Icon + title + subtitle + optional CTA. **Component 12 of 13.**
///
/// Used wherever a list has nothing in it, a request failed, or a flow reached
/// a dead end. The whole block is a single accessibility element so VoiceOver
/// reads the explanation as one sentence rather than three fragments.
///
/// ```swift
/// TNEmptyState(
///     icon: "tray",
///     title: "Nothing here yet",
///     subtitle: "Posts you bookmark will show up here.",
///     actionTitle: "Explore",
///     action: { router.openExplore() }
/// )
/// ```
public struct TNEmptyState: View {

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
        tint: Color = TNColor.primary,
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
        VStack(spacing: TNSpacing.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(tint)
            }

            VStack(spacing: TNSpacing.xs) {
                Text(title)
                    .font(TNFont.displayM)
                    .foregroundStyle(TNColor.textPrimary)
                    .multilineTextAlignment(.center)

                if let subtitle {
                    Text(subtitle)
                        .font(TNFont.bodyLight)
                        .foregroundStyle(TNColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text([title, subtitle].compactMap { $0 }.joined(separator: ". ")))
            .accessibilityHint(Text("Status message"))

            if let actionTitle, let action {
                TNButton(actionTitle, variant: .secondary, size: .compact, action: action)
                    .frame(maxWidth: 220)
                    .padding(.top, TNSpacing.xs)
            }
        }
        .padding(TNSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("TNEmptyState") {
    VStack {
        TNEmptyState(
            icon: "hourglass",
            title: "Under review",
            subtitle: "A human reviewer is checking your documents. This usually takes a few hours.",
            actionTitle: "Refresh",
            action: {}
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TNColor.background)
}
