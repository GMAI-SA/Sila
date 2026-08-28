import SwiftUI

/// **Screen 6 — Pending verification wall.**
///
/// The hard gate. Everyone who is signed in but not yet verified lands here,
/// and the **only** ways off it are completing verification (Phase 2) or
/// signing out. There is no `NavigationStack` and no back button, by design:
/// the screen is presented as a root, not pushed.
@MainActor
public struct PendingVerificationWallScreen: View {

    @State private var viewModel: VerificationWallViewModel
    private let onSignOut: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSigningOut = false
    @State private var rotation: Double = 0

    /// - Parameters:
    ///   - status: Status known from the session.
    ///   - service: Auth backend.
    ///   - analytics: Event sink.
    ///   - onSignOut: Ends the session.
    public init(
        status: VerificationStatus,
        service: AuthServiceProtocol,
        analytics: AnalyticsClient,
        onSignOut: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: VerificationWallViewModel(
            status: status,
            service: service,
            analytics: analytics
        ))
        self.onSignOut = onSignOut
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: TNSpacing.xl) {
                Spacer(minLength: TNSpacing.xxl)

                hero

                VStack(spacing: TNSpacing.sm) {
                    TNBadge(
                        viewModel.presentation.badgeText,
                        style: viewModel.presentation.badgeStyle
                    )

                    Text(viewModel.presentation.title)
                        .font(TNFont.displayL)
                        .foregroundStyle(TNColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(viewModel.presentation.message)
                        .font(TNFont.bodyLight)
                        .foregroundStyle(TNColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let reason = viewModel.rejectionReason {
                        Text(reason)
                            .font(TNFont.caption)
                            .foregroundStyle(TNColor.danger)
                            .multilineTextAlignment(.center)
                            .padding(.top, TNSpacing.xs)
                    }
                }
                .padding(.horizontal, TNSpacing.lg)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(spokenSummary))
                .accessibilityHint(Text("Your account is limited until identity verification is complete"))

                if let submitted = viewModel.submittedText {
                    TNCard(padding: TNSpacing.md) {
                        HStack(spacing: TNSpacing.sm) {
                            Image(systemName: "clock")
                                .foregroundStyle(TNColor.textSecondary)
                            Text(submitted)
                                .font(TNFont.mono)
                                .foregroundStyle(TNColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, TNSpacing.lg)
                }

                actions

                Spacer(minLength: TNSpacing.xxl)
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable { await viewModel.refresh() }
        .tnScreenBackground()
        .tnToast($viewModel.toast)
        .task {
            await viewModel.refresh()
            startProcessingAnimation()
        }
    }

    // MARK: - Pieces

    private var hero: some View {
        ZStack {
            Circle()
                .fill(viewModel.presentation.badgeStyle.tint.opacity(0.12))
                .frame(width: 132, height: 132)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    viewModel.presentation.badgeStyle.tint,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 132, height: 132)
                .rotationEffect(.degrees(rotation))
                .opacity(viewModel.presentation.showsProcessingAnimation ? 1 : 0)

            Image(systemName: viewModel.presentation.icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(viewModel.presentation.badgeStyle.tint)
        }
        .accessibilityHidden(true)
    }

    private var actions: some View {
        VStack(spacing: TNSpacing.md) {
            if let title = viewModel.presentation.primaryActionTitle {
                TNButton(
                    title,
                    variant: .primary,
                    accessibilityHint: "Opens the identity verification steps"
                ) {
                    viewModel.startVerification()
                }
            }

            TNButton(
                "Check status",
                variant: .secondary,
                isLoading: viewModel.isRefreshing,
                accessibilityHint: "Re-checks whether a reviewer has made a decision"
            ) {
                Task { await viewModel.refresh() }
            }

            TNButton(
                "Sign out",
                variant: .ghost,
                size: .compact,
                isLoading: isSigningOut,
                accessibilityHint: "Ends your session and returns to the welcome screen"
            ) {
                isSigningOut = true
                onSignOut()
            }
        }
        .padding(.horizontal, TNSpacing.lg)
    }

    private var spokenSummary: String {
        var parts = [
            viewModel.presentation.badgeText,
            viewModel.presentation.title,
            viewModel.presentation.message
        ]
        if let reason = viewModel.rejectionReason { parts.append(reason) }
        return parts.joined(separator: ". ")
    }

    private func startProcessingAnimation() {
        guard viewModel.presentation.showsProcessingAnimation, !reduceMotion else { return }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

#Preview("Wall — Under Review") {
    let container = AppContainer.preview(scenario: .pendingReview)
    return PendingVerificationWallScreen(
        status: .pendingReview,
        service: container.authService,
        analytics: container.analytics,
        onSignOut: {}
    )
}

#Preview("Wall — Action Required") {
    let container = AppContainer.preview(scenario: .unstarted)
    return PendingVerificationWallScreen(
        status: .unstarted,
        service: container.authService,
        analytics: container.analytics,
        onSignOut: {}
    )
}

#Preview("Wall — In Progress") {
    let container = AppContainer.preview(scenario: .inProgress)
    return PendingVerificationWallScreen(
        status: .inProgress,
        service: container.authService,
        analytics: container.analytics,
        onSignOut: {}
    )
}
