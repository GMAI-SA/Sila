import SwiftUI

/// Search and discovery.
///
/// Contract v2 exposes no search, trending or hashtag endpoint, so this screen
/// says so. Rendering invented trending topics would be a lie on a platform
/// whose entire proposition is that what you see is real — and per-country
/// trends in particular have to be computed from *verified* populations, which
/// only the server can do.
@MainActor
public struct ExploreScreen: View {

    private let onStub: @MainActor (String) -> Void

    /// - Parameter onStub: Announces a feature that belongs to a later release.
    public init(onStub: @escaping @MainActor (String) -> Void) {
        self.onStub = onStub
    }

    public var body: some View {
        VStack(spacing: TNSpacing.lg) {
            searchBarPlaceholder

            Spacer()

            TNEmptyState(
                icon: "magnifyingglass",
                title: "Explore is coming",
                subtitle: "Search, verified-population trends per country, and global trending arrive with the next backend release. Nothing is shown here until it is real.",
                tint: TNColor.primary,
                actionTitle: "Tell me when it lands",
                action: { onStub("Explore") }
            )
            .padding(.horizontal, TNSpacing.lg)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }

    /// A disabled control, not a text field that swallows input and does nothing.
    private var searchBarPlaceholder: some View {
        HStack(spacing: TNSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TNColor.textMuted)
            Text("Search TrustNet")
                .font(TNFont.body)
                .foregroundStyle(TNColor.textMuted)
            Spacer()
            TNBadge("Soon", style: .neutral)
        }
        .padding(.horizontal, TNSpacing.lg)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: TNRadius.lg)
                .fill(TNColor.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: TNRadius.lg)
                        .strokeBorder(TNColor.stroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, TNSpacing.lg)
        .padding(.top, TNSpacing.lg)
        .contentShape(Rectangle())
        .onTapGesture { onStub("Search") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Search TrustNet"))
        .accessibilityHint(Text("Search is not available yet; tapping explains when it arrives"))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("ExploreScreen") {
    ExploreScreen(onStub: { _ in }).preferredColorScheme(.dark)
}
