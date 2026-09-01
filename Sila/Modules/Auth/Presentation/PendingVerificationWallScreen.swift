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
            VStack(spacing: SLSpacing.xl) {
                Spacer(minLength: SLSpacing.xxl)

                hero

                VStack(spacing: SLSpacing.sm) {
                    SLBadge(
                        viewModel.presentation.badgeText,
                        style: viewModel.presentation.badgeStyle
                    )

                    Text(viewModel.presentation.title)
                        .font(SLFont.displayL)
                        .foregroundStyle(SLColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(viewModel.presentation.message)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let reason = viewModel.rejectionReason {
                        // The reviewer wrote this, not us: it can arrive in
                        // either language and has to read in its own.
                        Text(reason)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .multilineTextAlignment(.center)
                            .padding(.top, SLSpacing.xs)
                            .environment(
                                \.layoutDirection,
                                TextDirection.resolve(languageCode: nil, text: reason).layoutDirection
                            )
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(spokenSummary))
                .accessibilityHint(Text(L10n.t("auth.wall.a11yHint")))

                if let submitted = viewModel.submittedText {
                    SLCard(padding: SLSpacing.md) {
                        HStack(spacing: SLSpacing.sm) {
                            Image(systemName: "clock")
                                .foregroundStyle(SLColor.textSecondary)
                            Text(submitted)
                                .font(SLFont.mono)
                                .foregroundStyle(SLColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, SLSpacing.lg)
                }

                actions

                Spacer(minLength: SLSpacing.xxl)
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
        VStack(spacing: SLSpacing.md) {
            if let title = viewModel.presentation.primaryActionTitle {
                SLButton(
                    title,
                    variant: .primary,
                    accessibilityHint: L10n.t("auth.wall.startVerification.hint")
                ) {
                    viewModel.startVerification()
                }
            }

            SLButton(
                L10n.t("auth.wall.checkStatus"),
                variant: .secondary,
                isLoading: viewModel.isRefreshing,
                accessibilityHint: L10n.t("auth.wall.checkStatus.hint")
            ) {
                Task { await viewModel.refresh() }
            }

            SLButton(
                L10n.t("common.signOut"),
                variant: .ghost,
                size: .compact,
                isLoading: isSigningOut,
                accessibilityHint: L10n.t("auth.signOut.hint")
            ) {
                isSigningOut = true
                onSignOut()
            }
        }
        .padding(.horizontal, SLSpacing.lg)
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
