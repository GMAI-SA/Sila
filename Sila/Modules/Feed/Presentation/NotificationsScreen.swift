import SwiftUI

/// Likes, reposts, follows and mentions.
///
/// Contract v2 has no notifications endpoint. Rather than render a plausible
/// list of fake activity, the screen states plainly that the feed of
/// notifications does not exist yet — an empty inbox a user can trust beats a
/// populated one they cannot.
@MainActor
public struct NotificationsScreen: View {

    private let onStub: @MainActor (String) -> Void

    /// - Parameter onStub: Announces a feature that belongs to a later release.
    public init(onStub: @escaping @MainActor (String) -> Void) {
        self.onStub = onStub
    }

    public var body: some View {
        VStack(spacing: SLSpacing.lg) {
            Spacer()

            SLEmptyState(
                icon: "bell",
                title: "Notifications are coming",
                subtitle: "Likes, reposts, follows, mentions and Community Notes will land here with the next backend release. Until the API exists, this screen stays honest and empty.",
                tint: SLColor.primary,
                actionTitle: "Tell me when it lands",
                action: { onStub("Notifications") }
            )
            .padding(.horizontal, SLSpacing.lg)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }
}

#Preview("NotificationsScreen") {
    NotificationsScreen(onStub: { _ in }).preferredColorScheme(.dark)
}
