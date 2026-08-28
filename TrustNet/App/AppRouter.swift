import Foundation
import Observation

/// Screens reachable inside the unauthenticated navigation stack.
public enum AuthRoute: Hashable, Sendable {
    /// Email + password + confirm.
    case register
    /// Six-digit code entry for a given address and purpose.
    case otp(email: String, purpose: OTPPurpose)
    /// Email + password, with optional biometric unlock.
    case signIn
    /// Address entry for the forgotten-password OTP.
    case forgotPassword
}

/// Screens reachable inside the verified app's home stack.
public enum FeedRoute: Hashable, Sendable {
    /// A post with its reply thread.
    case postDetail(Post)
}

/// Navigation coordinator.
///
/// Owns the `NavigationStack` paths and the modals. Cross-screen routing
/// decisions that depend on *session state* live in ``AuthSession``; this type
/// only moves the user around inside a stack.
@MainActor
@Observable
public final class AppRouter {

    /// The auth stack's path.
    public var authPath: [AuthRoute] = []
    /// The home (Phase 3) stack's path.
    public var feedPath: [FeedRoute] = []
    /// Legal document currently presented in a sheet, if any.
    public var presentedLegalDocument: LegalDocument?
    /// The composer currently presented as a sheet, if any.
    public var presentedComposer: ComposerContext?
    /// App-level toast.
    public var toast: TNToastMessage?

    public init() {}

    /// A legal document shown in a web sheet from the register screen.
    public enum LegalDocument: String, Identifiable, Sendable {
        case terms, privacy

        public var id: String { rawValue }

        /// Sheet title.
        public var title: String {
            switch self {
            case .terms: return "Terms of Service"
            case .privacy: return "Privacy Policy"
            }
        }

        /// Remote URL, or `nil` if the configured string is malformed.
        public var url: URL? {
            switch self {
            case .terms: return URL(string: AppConfig.termsURLString)
            case .privacy: return URL(string: AppConfig.privacyURLString)
            }
        }
    }

    // MARK: - Stack operations

    /// Pushes a screen onto the auth stack.
    public func push(_ route: AuthRoute) {
        authPath.append(route)
    }

    /// Pops one screen, if there is one.
    public func pop() {
        guard !authPath.isEmpty else { return }
        authPath.removeLast()
    }

    /// Returns to the welcome screen.
    public func popToRoot() {
        authPath.removeAll()
    }

    /// Replaces the whole stack with the OTP screen for `email`.
    ///
    /// Used when `/auth/login` answers `email_unverified` — the user should not
    /// be able to swipe back into a sign-in form that will keep failing.
    public func replaceWithOTP(email: String, purpose: OTPPurpose) {
        authPath = [.otp(email: email, purpose: purpose)]
    }

    /// Pushes a screen onto the home stack.
    public func push(_ route: FeedRoute) {
        feedPath.append(route)
    }

    /// Empties the home stack — used when the session ends.
    public func popFeedToRoot() {
        feedPath.removeAll()
    }

    /// Presents a legal document sheet.
    public func present(_ document: LegalDocument) {
        presentedLegalDocument = document
    }

    /// Shows an app-level toast.
    public func show(_ toast: TNToastMessage) {
        self.toast = toast
    }

    /// Closes the composer sheet.
    public func dismissComposer() {
        presentedComposer = nil
    }
}

extension AppRouter: ComposerLaunching {
    /// Presents the Phase-4 composer.
    ///
    /// Conforming here is what lets Feed and Explore start a composition
    /// without importing the Composer module's screens.
    public func openComposer(_ context: ComposerContext) {
        presentedComposer = context
    }
}
