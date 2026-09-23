import SwiftUI

/// Maps ``AuthSession/route`` onto a screen.
///
/// This is the one place that decides what the user is looking at. The wall
/// and the rejected screen are presented as **roots**, not pushed, so there is
/// no navigation stack to swipe back through — which is what makes the wall an
/// actual wall.
@MainActor
public struct RootView: View {

    private let container: AppContainer
    /// Set once the first-run flow has finished on this launch, so a forced
    /// flow (`-forceOnboarding`) does not come back.
    @State private var onboardingFinished = false

    /// - Parameter container: The DI root.
    public init(container: AppContainer) {
        self.container = container
    }

    public var body: some View {
        ZStack {
            SLColor.background.ignoresSafeArea()

            themedContent
        }
        // The whole tree is torn down and rebuilt when the language changes —
        // that is what makes every `L10n.t` re-resolve without a restart. The
        // router keeps the navigation paths, so the rebuild lands back on the
        // same screens.
        .id(container.language.choice)
        // The chrome's direction follows the chosen language, not only the
        // device's: without this an in-app switch to Arabic would translate
        // every sentence and leave the layout running the wrong way.
        .environment(\.layoutDirection, container.language.layoutDirection)
    }

    @ViewBuilder
    private var themedContent: some View {
        Group {
            if container.suspension.isSuspended, isSignedIn {
                // A root, like the verification wall and the deletion recovery
                // screen — not a sheet and not a push. There is nothing behind
                // it to swipe back to, because for a suspended account there is
                // nothing behind it that works.
                //
                // Ahead of the session switch on purpose: `403 account_suspended`
                // is answered by every endpoint except two, so whatever screen
                // the session route would otherwise pick would spend its life
                // failing. Showing an error with a Retry button would loop
                // somebody through the same 403 until the suspension lapsed,
                // while the appeal — the one action that changes anything —
                // stayed off screen.
                SuspensionScreen(viewModel: suspensionViewModel())
                    .transition(.opacity)
            } else {
                sessionContent
            }
        }
        .animation(.easeInOut(duration: 0.28), value: container.session.route)
        .animation(.easeInOut(duration: 0.28), value: container.suspension.isSuspended)
        .tnToast(Binding(
            get: { container.router.toast },
            set: { container.router.toast = $0 }
        ))
    }

    /// `true` once there is a session a suspension could apply to.
    ///
    /// The welcome and sign-in screens are deliberately exempt: a stale
    /// suspension flag must never be able to stand between somebody and the
    /// sign-in form.
    private var isSignedIn: Bool {
        switch container.session.route {
        case .splash, .unauthenticated: return false
        default: return true
        }
    }

    /// Builds the suspension screen's model.
    ///
    /// Signing out clears the monitor as well as the session, so the next
    /// account to use this device does not inherit somebody else's suspension.
    private func suspensionViewModel() -> SuspensionViewModel {
        SuspensionViewModel(
            service: container.safetyService,
            analytics: container.analytics,
            monitor: container.suspension,
            onSignOut: {
                container.suspension.clear()
                container.router.popFeedToRoot()
                Task { await container.session.signOut() }
            }
        )
    }

    @ViewBuilder
    private var sessionContent: some View {
        Group {
            switch container.session.route {
            case .splash:
                SplashScreen(session: container.session)
                    .transition(.opacity)

            case .unauthenticated:
                authStack
                    .transition(.opacity)

            case let .awaitingEmailVerification(email):
                emailVerificationRoot(email: email)
                    .transition(.opacity)

            case let .verificationWall(status):
                PendingVerificationWallScreen(
                    status: status,
                    service: container.authService,
                    // `nil` when the phase is off, which restores the honest
                    // stub toast rather than a button that goes nowhere.
                    verification: container.flags.verification ? container.verificationService : nil,
                    analytics: container.analytics,
                    onSignOut: { Task { await container.session.signOut() } },
                    onVerified: { await container.session.refreshUser() }
                )
                .transition(.opacity)

            case let .rejected(reason):
                RejectedScreen(
                    reason: reason,
                    appeal: container.session.verificationReport?.appeal,
                    analytics: container.analytics,
                    onAppeal: { message in
                        try await container.verificationService.appealVerification(message: message)
                    },
                    onTryAgain: { container.session.retryVerification() },
                    onSignOut: { Task { await container.session.signOut() } }
                )
                .transition(.opacity)

            case .guest:
                // The same shell the signed-in app uses, reading the public
                // half of the API. Every action meets an invitation instead
                // of a failure — see `GuestTabView`.
                GuestTabView(container: container)
                    .transition(.opacity)

            case .feed:
                if container.flags.feed, showsOnboarding {
                    Owned({ onboardingViewModel() }) { viewModel in
                        OnboardingFlow(viewModel: viewModel, onOpenRoom: { room in
                            container.router.pendingLink = .room(id: room.id)
                        })
                    }
                    .transition(.opacity)
                } else if container.flags.feed {
                    MainTabView(container: container)
                        .transition(.opacity)
                        // Once, on reaching the feed. `/languages` is
                        // authenticated, so there is nothing to ask for before
                        // this point, and nothing on screen waits for the answer.
                        .task { await container.loadLanguages() }
                } else {
                    // The Phase-3 kill switch: a verified user still gets in,
                    // they just get the pre-feed screen.
                    FeedPlaceholderScreen(
                        user: container.session.user,
                        onSignOut: { Task { await container.session.signOut() } }
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - First run

    /// The subjects-and-people step shows once, for a verified account the
    /// server has never asked (contract v19 `needs_interest_prompt`).
    private var showsOnboarding: Bool {
        guard container.flags.onboarding, !onboardingFinished else { return false }
        return container.flags.forceOnboarding || container.session.user?.needsInterestPrompt == true
    }

    private func onboardingViewModel() -> OnboardingViewModel {
        OnboardingViewModel(
            discover: container.discoverService,
            preferences: container.preferencesService,
            profile: container.flags.profile ? container.profileService : nil,
            rooms: container.flags.rooms ? container.roomsService : nil,
            analytics: container.analytics,
            onFinish: {
                onboardingFinished = true
                Task { await container.session.markInterestsPrompted() }
            }
        )
    }

    // MARK: - Unauthenticated stack

    private var authStack: some View {
        NavigationStack(path: Binding(
            get: { container.router.authPath },
            set: { container.router.authPath = $0 }
        )) {
            WelcomeScreen(
                onCreateAccount: { container.router.push(.register) },
                onSignIn: { container.router.push(.signIn) },
                onBrowse: { container.session.browseAsGuest() }
            )
            .navigationDestination(for: AuthRoute.self) { route in
                destination(for: route)
            }
        }
        .tint(SLColor.primary)
    }

    @ViewBuilder
    private func destination(for route: AuthRoute) -> some View {
        switch route {
        case .register:
            RegisterScreen(
                service: container.authService,
                router: container.router,
                onRegistered: { email in
                    container.router.push(.otp(email: email, purpose: .register))
                }
            )

        case let .otp(email, purpose):
            OTPVerificationScreen(
                email: email,
                purpose: purpose,
                service: container.authService,
                onVerified: { pair in
                    Task {
                        container.router.popToRoot()
                        await container.session.adopt(pair)
                    }
                }
            )

        case .signIn:
            SignInScreen(
                service: container.authService,
                prefilledEmail: lastSignedInEmail,
                biometricsEnabled: container.flags.biometricSignIn,
                onSignedIn: { pair in
                    Task {
                        container.router.popToRoot()
                        await container.session.adopt(pair)
                    }
                },
                onNeedsEmailVerification: { email in
                    container.router.replaceWithOTP(email: email, purpose: .login)
                },
                onForgotPassword: { container.router.push(.forgotPassword) }
            )

        case .forgotPassword:
            ForgotPasswordScreen(
                service: container.authService,
                prefilledEmail: lastSignedInEmail,
                onCodeSent: { email in
                    // Not the OTP screen: that one exchanges a code for a
                    // session, and the server refuses a reset code there on
                    // purpose. A reset code buys one thing, which is the
                    // screen below.
                    container.router.push(.resetPassword(email: email))
                }
            )

        case let .resetPassword(email):
            ResetPasswordScreen(
                email: email,
                service: container.authService,
                onDone: { email in
                    // Back to sign-in with the address already there, and a
                    // word confirming the password actually changed.
                    container.storage.set(email, for: .lastSignedInEmail)
                    container.router.popToRoot()
                    container.router.toast = .success(L10n.t("auth.resetPassword.done"))
                }
            )
        }
    }

    /// The OTP screen shown as a root when a restored session has an
    /// unconfirmed email — there is nothing to navigate back to.
    private func emailVerificationRoot(email: String) -> some View {
        NavigationStack {
            OTPVerificationScreen(
                email: email,
                purpose: .login,
                service: container.authService,
                onVerified: { pair in
                    Task { await container.session.adopt(pair) }
                }
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("common.signOut")) {
                        Task { await container.session.signOut() }
                    }
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityLabel(Text(L10n.t("common.signOut")))
                    .accessibilityHint(Text(L10n.t("app.signOut.hint")))
                }
            }
        }
        .tint(SLColor.primary)
    }

    private var lastSignedInEmail: String {
        container.storage.value(for: .lastSignedInEmail, as: String.self) ?? ""
    }
}

/// The pre-feed screen, retained as ``FeatureFlags/feed``'s off state.
///
/// ``MainTabView`` is what a verified user sees now. This stays so the feed
/// phase has a real kill switch that still lets a verified user sign out.
@MainActor
struct FeedPlaceholderScreen: View {

    let user: AuthUser?
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: SLSpacing.lg) {
            Spacer()

            SLAvatar(
                initials: user?.initials ?? "TN",
                size: .xl,
                isVerified: true,
                displayName: user?.displayName ?? user?.email
            )

            SLEmptyState(
                icon: "checkmark.seal.fill",
                title: L10n.t("app.placeholder.title"),
                subtitle: L10n.t("app.placeholder.subtitle"),
                tint: SLColor.secondary
            )

            if let email = user?.email {
                Text(email)
                    .font(SLFont.mono)
                    .foregroundStyle(SLColor.textMuted)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: email))
                    .accessibilityLabel(Text(L10n.t("app.placeholder.signedInAs", email)))
            }

            SLButton(
                L10n.t("common.signOut"),
                variant: .ghost,
                size: .compact,
                accessibilityHint: L10n.t("app.signOut.hint"),
                action: onSignOut
            )
            .padding(.horizontal, SLSpacing.xxl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }
}

#Preview("RootView — wall") {
    RootView(container: AppContainer.preview(scenario: .pendingReview))
}

#Preview("RootView — verified") {
    RootView(container: AppContainer.preview(scenario: .verified))
}
