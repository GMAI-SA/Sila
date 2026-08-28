import SwiftUI

/// The verified app's shell: five slots, four screens, one honest stub.
///
/// Replaces Phase 1's `FeedPlaceholderScreen` as the destination for
/// ``SessionRoute/feed``. Compose (Phase 4) and Profile (Phase 7) do not exist
/// yet, so they say so out loud rather than pretending — the same contract the
/// wall's "Start Verification" button already honours.
@MainActor
public struct MainTabView: View {

    /// The four selectable destinations. Compose is an action, not a tab.
    public enum Tab: String, Hashable, Sendable, CaseIterable {
        case home, explore, notifications, profile
    }

    private let container: AppContainer
    @State private var selection: Tab = .home
    @State private var viewModel: HomeViewModel

    /// - Parameter container: The DI root.
    public init(container: AppContainer) {
        self.container = container
        self._viewModel = State(
            initialValue: HomeViewModel(
                service: container.feedService,
                analytics: container.analytics
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            TNTabBar(items: tabBarItems, selection: $selection) { id in
                if id == "compose" { stub("Composing posts") }
            }
        }
        .tnScreenBackground()
    }

    // MARK: - Screens

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            NavigationStack(path: Binding(
                get: { container.router.feedPath },
                set: { container.router.feedPath = $0 }
            )) {
                HomeScreen(
                    viewModel: viewModel,
                    onOpenPost: { container.router.push(FeedRoute.postDetail($0)) },
                    onStub: stub
                )
                .tnNavigationBar(title: "TrustNet")
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(TNColor.primary)

        case .explore:
            ExploreScreen(onStub: stub)

        case .notifications:
            NotificationsScreen(onStub: stub)

        case .profile:
            ProfileStubScreen(
                user: container.session.user,
                onStub: stub,
                onSignOut: {
                    container.router.popFeedToRoot()
                    Task { await container.session.signOut() }
                }
            )
        }
    }

    @ViewBuilder
    private func destination(for route: FeedRoute) -> some View {
        switch route {
        case let .postDetail(post):
            PostDetailScreen(
                viewModel: PostDetailViewModel(
                    post: post,
                    service: container.feedService,
                    analytics: container.analytics
                ),
                onOpenPost: { container.router.push(FeedRoute.postDetail($0)) },
                onStub: stub,
                // Engagement changed on the detail screen must not be lost when
                // the user swipes back to a feed still holding the old copy.
                onDismiss: { viewModel.merge($0) }
            )
        }
    }

    // MARK: - Tab bar

    private var tabBarItems: [TNTabBarItem<Tab>] {
        [
            TNTabBarItem(
                id: "home", icon: "house", selectedIcon: "house.fill",
                label: "Home", hint: "Shows your four feeds", kind: .tab(.home)
            ),
            TNTabBarItem(
                id: "explore", icon: "magnifyingglass", selectedIcon: "magnifyingglass",
                label: "Explore", hint: "Search and trending, coming in a later release", kind: .tab(.explore)
            ),
            TNTabBarItem(
                id: "compose", icon: "plus",
                label: "Post", hint: "Writing posts arrives in a later release", kind: .action
            ),
            TNTabBarItem(
                id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                label: "Alerts", hint: "Your notifications, coming in a later release", kind: .tab(.notifications)
            ),
            TNTabBarItem(
                id: "profile", icon: "person", selectedIcon: "person.fill",
                label: "Profile", hint: "Your account", kind: .tab(.profile)
            )
        ]
    }

    /// Announces a feature that belongs to a later phase, exactly the way the
    /// verification wall's stub does: record the intent, tell the user plainly.
    private func stub(_ feature: String) {
        container.analytics.track(.featureStubShown, properties: ["feature": feature])
        container.router.show(.info("\(feature) arrives in a later release."))
    }
}

/// The Profile tab until Phase 7 builds the real thing.
///
/// It carries the only affordance a user genuinely needs here today — signing
/// out — and does not invent follower counts or a bio.
@MainActor
struct ProfileStubScreen: View {

    let user: AuthUser?
    let onStub: @MainActor (String) -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: TNSpacing.lg) {
            Spacer()

            TNAvatar(
                initials: user?.initials ?? "TN",
                size: .xl,
                isVerified: user?.verificationStatus == .verified,
                displayName: user?.displayName ?? user?.email
            )

            VStack(spacing: TNSpacing.xs) {
                Text(user?.displayName ?? "Your account")
                    .font(TNFont.displayM)
                    .foregroundStyle(TNColor.textPrimary)

                if let email = user?.email {
                    Text(email)
                        .font(TNFont.mono)
                        .foregroundStyle(TNColor.textMuted)
                        .accessibilityLabel(Text("Signed in as \(email)"))
                }

                if user?.verificationStatus == .verified {
                    TNBadge("Verified", style: .verified, icon: "checkmark.seal.fill")
                }
            }

            TNEmptyState(
                icon: "person.crop.square",
                title: "Profiles arrive later",
                subtitle: "Your handle, country flag, bio, follower counts and post history land with the profile release. Nothing here is guessed in the meantime.",
                tint: TNColor.textSecondary,
                actionTitle: "Tell me when it lands",
                action: { onStub("Profiles") }
            )
            .padding(.horizontal, TNSpacing.lg)

            TNButton(
                "Sign out",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Ends your session and returns to the welcome screen",
                action: onSignOut
            )
            .padding(.horizontal, TNSpacing.xxl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }
}

#Preview("MainTabView") {
    MainTabView(container: AppContainer.preview(scenario: .verified))
        .preferredColorScheme(.dark)
}
