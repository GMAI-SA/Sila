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

/// Screens reachable inside the verified app's home and Explore stacks.
///
/// Shared by both stacks rather than duplicated per tab: the same two
/// destinations chain into each other — a post leads to its author, whose
/// timeline leads to another post — and a second enum would only let the two
/// tabs drift apart.
public enum FeedRoute: Hashable, Sendable {
    /// One conversation. Carries the whole thread rather than an id because the
    /// list already holds it, and re-fetching a conversation to open it would
    /// show an empty screen on a slow connection for something already on file.
    case conversation(Conversation)
    /// A post with its reply thread.
    case postDetail(Post)
    /// One account's public page. Carries the handle rather than a
    /// ``UserSummary`` because the profile is re-read from the server on
    /// arrival — the copy attached to a post is whatever was true when that
    /// page was fetched.
    case profile(handle: String)
}

/// Screens reachable inside the Rooms tab's stack.
///
/// A stack of its own rather than another ``FeedRoute`` case, because a room is
/// a *connection*, not a document: it carries a live media token, it has to be
/// torn down when it is popped, and pushing one onto the feed's history would
/// let somebody swipe back into a room they had already left.
///
/// ``room(_:)`` carries the whole ``RoomJoin`` — the token included — because
/// the join happened before the push. Doing it the other way round would put a
/// room screen on the display and only then discover the person had been
/// removed from that room.
public enum RoomsRoute: Hashable, Sendable {
    /// A live room, already joined.
    case room(RoomJoin)
    /// One account's public page, reached from the participant list.
    case profile(handle: String)
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
    /// The Explore tab's own stack path.
    ///
    /// Separate from ``feedPath`` so opening a search result — or the profile
    /// behind it — never disturbs the history the home feed is holding.
    public var explorePath: [FeedRoute] = []
    /// The Profile tab's own stack path, above the viewer's own profile.
    public var profilePath: [FeedRoute] = []
    /// The Notifications tab's own stack path.
    ///
    /// Notifications lead *into* the app — a reply row opens a thread, a follow
    /// row opens a person — so the tab needs a stack of its own. Sharing the
    /// home feed's would mean opening a notification rearranged the history
    /// somebody left behind on Home.
    public var notificationsPath: [FeedRoute] = []

    /// The Messages tab's stack.
    public var messagesPath: [FeedRoute] = []
    /// The Rooms tab's own stack path.
    public var roomsPath: [RoomsRoute] = []
    /// `true` while the create-room sheet is up.
    public var isCreatingRoom = false
    /// Legal document currently presented in a sheet, if any.
    public var presentedLegalDocument: LegalDocument?
    /// The composer currently presented as a sheet, if any.
    public var presentedComposer: ComposerContext?
    /// App-level toast.
    public var toast: SLToastMessage?

    public init() {}

    /// A legal document shown in a web sheet from the register screen.
    public enum LegalDocument: String, Identifiable, Sendable {
        case terms, privacy

        public var id: String { rawValue }

        /// Sheet title.
        public var title: String {
            switch self {
            case .terms: return L10n.t("app.legal.terms")
            case .privacy: return L10n.t("app.legal.privacy")
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

    /// Empties every in-app stack — used when the session ends.
    ///
    /// All five, not just the feed: a profile or a search result left on the
    /// Explore stack would still be there behind the next sign-in, and a room
    /// left on the Rooms stack would still be holding a media token belonging
    /// to a session that has ended.
    public func popFeedToRoot() {
        feedPath.removeAll()
        explorePath.removeAll()
        profilePath.removeAll()
        notificationsPath.removeAll()
        roomsPath.removeAll()
    }

    /// Presents a legal document sheet.
    public func present(_ document: LegalDocument) {
        presentedLegalDocument = document
    }

    /// Shows an app-level toast.
    public func show(_ toast: SLToastMessage) {
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
