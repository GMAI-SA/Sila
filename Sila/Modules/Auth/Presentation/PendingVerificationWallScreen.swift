import SwiftUI

/// **Screen 6 — Pending verification wall.**
///
/// The hard gate. Everyone who is signed in but not yet verified lands here,
/// and the **only** ways off it are completing verification — by Nafath or
/// by document — or signing out. There is no `NavigationStack` and no back
/// button, by design: the screen is presented as a root, not pushed.
@MainActor
public struct PendingVerificationWallScreen: View {

    @State private var viewModel: VerificationWallViewModel
    @State private var isChoosingMethod = false
    @State private var isPickingNationality = false
    @State private var isSavingNationality = false
    @State private var chooseAfterPicking = false
    @State private var reopenPickerAfterChoosing = false
    @State private var pendingRoute: VerificationRoute?
    @State private var route: VerificationRoute?
    private let verification: VerificationServiceProtocol?
    private let analytics: AnalyticsClient
    private let onSignOut: () -> Void
    private let onVerified: (() async -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSigningOut = false
    @State private var rotation: Double = 0

    /// - Parameters:
    ///   - status: Status known from the session.
    ///   - service: Auth backend.
    ///   - verification: The verification backend. `nil` — the kill switch's
    ///     off state — keeps "Start Verification" as the honest stub toast.
    ///   - analytics: Event sink.
    ///   - onSignOut: Ends the session.
    ///   - onVerified: Refreshes the session after a flow finishes — the
    ///     account's `verification_status` (and, on approval, `country_code`)
    ///     changed, and this is what moves the wall on.
    public init(
        status: VerificationStatus,
        service: AuthServiceProtocol,
        verification: VerificationServiceProtocol? = nil,
        analytics: AnalyticsClient,
        onSignOut: @escaping () -> Void,
        onVerified: (() async -> Void)? = nil
    ) {
        _viewModel = State(initialValue: VerificationWallViewModel(
            status: status,
            service: service,
            analytics: analytics
        ))
        self.verification = verification
        self.analytics = analytics
        self.onSignOut = onSignOut
        self.onVerified = onVerified
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

                    if let reason = VerificationRejection.display(viewModel.rejectionReason) {
                        // A machine reason reads in the interface language; a
                        // reviewer's words read in their own direction.
                        Text(reason)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .multilineTextAlignment(.center)
                            .padding(.top, SLSpacing.xs)
                            .environment(
                                \.layoutDirection,
                                VerificationRejection.isMachineReason(viewModel.rejectionReason)
                                    ? TextDirection.resolve(languageCode: L10n.languageCode, text: reason).layoutDirection
                                    : TextDirection.resolve(languageCode: nil, text: reason).layoutDirection
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
        // The claim comes first. Once it is saved the chooser opens — after
        // this sheet has gone, for the same reason as below.
        .sheet(isPresented: $isPickingNationality, onDismiss: {
            if chooseAfterPicking {
                chooseAfterPicking = false
                isChoosingMethod = true
            }
        }) {
            NationalityPickerSheet(selected: viewModel.declaredNationality, isSaving: isSavingNationality) { code in
                Task { await declare(code) }
            }
            .interactiveDismissDisabled(isSavingNationality)
        }
        // The chooser is a sheet; the chosen flow is a cover. Presenting the
        // cover while the sheet is still dismissing is a glitch, so the
        // choice is remembered and acted on in `onDismiss`.
        .sheet(isPresented: $isChoosingMethod, onDismiss: {
            if reopenPickerAfterChoosing {
                reopenPickerAfterChoosing = false
                isPickingNationality = true
                return
            }
            if let chosen = pendingRoute {
                pendingRoute = nil
                route = chosen
            }
        }) {
            VerificationMethodSheet(
                declaredNationality: viewModel.declaredNationality,
                onChangeNationality: {
                    // Back to the picker, through the same latch the picker
                    // uses to reach here — one sheet at a time.
                    reopenPickerAfterChoosing = true
                    isChoosingMethod = false
                }
            ) { chosen in
                analytics.track(.verificationMethodChosen, properties: ["method": chosen.rawValue])
                pendingRoute = chosen
                isChoosingMethod = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(item: $route, onDismiss: {
            if let next = pendingRoute {
                pendingRoute = nil
                route = next
            }
        }) { chosen in
            if let verification {
                switch chosen {
                case .nafath:
                    NafathVerificationScreen(
                        viewModel: NafathVerificationViewModel(
                            service: verification,
                            analytics: analytics
                        ),
                        onApproved: {
                            route = nil
                            // The account's `verification_status` and
                            // `country_code` changed server-side; the session
                            // re-reads both and routes past the wall.
                            Task { await refreshAfterFlow() }
                        },
                        onSignInInstead: {
                            // "This identity already has a Sila account" — the
                            // way forward is the sign-in form, which means
                            // ending this session.
                            route = nil
                            onSignOut()
                        },
                        onClose: {
                            route = nil
                            // The status may have moved (e.g. to in_progress);
                            // the wall should say so rather than sit stale.
                            Task { await viewModel.refresh() }
                        }
                    )
                case .document:
                    DocumentVerificationScreen(
                        viewModel: DocumentVerificationViewModel(
                            service: verification,
                            analytics: analytics
                        ),
                        onSubmitted: {
                            route = nil
                            // Now `pending_review`: the session re-reads the
                            // status and the wall shows "under review".
                            Task { await refreshAfterFlow() }
                        },
                        onSignInInstead: {
                            route = nil
                            onSignOut()
                        },
                        onUseNafath: {
                            // A Saudi document: close this flow, open Nafath
                            // once the cover has actually gone.
                            analytics.track(.verificationMethodChosen, properties: ["method": "nafath_redirect"])
                            pendingRoute = .nafath
                            route = nil
                        },
                        onClose: {
                            route = nil
                            Task { await viewModel.refresh() }
                        }
                    )
                }
            }
        }
    }

    /// Sends the claim, then moves on to the route chooser.
    private func declare(_ code: String) async {
        guard let verification, !isSavingNationality else { return }
        isSavingNationality = true
        defer { isSavingNationality = false }
        do {
            let report = try await verification.setNationality(code)
            viewModel.adopt(report)
            analytics.track(.nationalityDeclared)
            chooseAfterPicking = true
            isPickingNationality = false
        } catch let error as APIError {
            viewModel.toast = .error(error.userMessage)
        } catch {
            viewModel.toast = .error(L10n.t("common.somethingWentWrong"))
        }
    }

    /// Refreshes the session when the host gave us a way to, and the local
    /// wall otherwise.
    private func refreshAfterFlow() async {
        if let onVerified {
            await onVerified()
        } else {
            await viewModel.refresh()
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
                    primaryAction()
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

    /// What the primary CTA actually does, by status.
    ///
    /// `unstarted` / `inProgress` / `rejected` offer the choice of route —
    /// a rejection on one route is a reason to try the other. `verified`
    /// re-reads the session instead: the route has moved on, into the app,
    /// and the button's job is to take the user there.
    private func primaryAction() {
        switch viewModel.status {
        case .verified:
            Task { await refreshAfterFlow() }
        case .unstarted, .inProgress, .pendingReview, .rejected:
            guard verification != nil else {
                viewModel.startVerification()
                return
            }
            analytics.track(.verificationStarted, properties: ["status": viewModel.status.rawValue])
            // No claim yet: ask for it first. The chooser follows on its own.
            if viewModel.declaredNationality == nil {
                isPickingNationality = true
            } else {
                isChoosingMethod = true
            }
        }
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
