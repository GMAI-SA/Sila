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

    /// - Parameter container: The DI root.
    public init(container: AppContainer) {
        self.container = container
    }

    public var body: some View {
        ZStack {
            SLColor.background.ignoresSafeArea()

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
                    analytics: container.analytics,
                    onSignOut: { Task { await container.session.signOut() } }
                )
                .transition(.opacity)

            case let .rejected(reason):
                RejectedScreen(
                    reason: reason,
                    email: container.session.user?.email,
                    analytics: container.analytics,
                    onSignOut: { Task { await container.session.signOut() } }
                )
                .transition(.opacity)

            case .feed:
                if container.flags.feed {
                    MainTabView(container: container)
                        .transition(.opacity)
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

    // MARK: - Unauthenticated stack

    private var authStack: some View {
        NavigationStack(path: Binding(
            get: { container.router.authPath },
            set: { container.router.authPath = $0 }
        )) {
            WelcomeScreen(
                onCreateAccount: { container.router.push(.register) },
                onSignIn: { container.router.push(.signIn) }
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
                    container.router.push(.otp(email: email, purpose: .reset))
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
                    Button("Sign out") {
                        Task { await container.session.signOut() }
                    }
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityLabel(Text("Sign out"))
                    .accessibilityHint(Text("Ends your session and returns to the welcome screen"))
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
                title: "You're in",
                subtitle: "The feed arrives in Phase 3. Your account is verified and ready.",
                tint: SLColor.secondary
            )

            if let email = user?.email {
                Text(email)
                    .font(SLFont.mono)
                    .foregroundStyle(SLColor.textMuted)
                    .accessibilityLabel(Text("Signed in as \(email)"))
            }

            SLButton(
                "Sign out",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Ends your session and returns to the welcome screen",
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
