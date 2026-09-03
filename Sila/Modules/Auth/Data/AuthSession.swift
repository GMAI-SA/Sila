import Foundation
import Observation

/// Where the app should currently be.
///
/// Routing is derived from session state rather than pushed imperatively, so
/// there is exactly one place that decides whether a user sees the wall.
public enum SessionRoute: Equatable, Sendable {
    /// Boot animation / keychain probe.
    case splash
    /// Not signed in.
    case unauthenticated
    /// Signed in but the email address is unconfirmed.
    case awaitingEmailVerification(email: String)
    /// Signed in, email confirmed, identity not yet approved.
    case verificationWall(VerificationStatus)
    /// Identity check declined.
    case rejected(reason: String?)
    /// Full access. Phase 3 replaces this with the real feed.
    case feed
}

/// The live session: the single owner of "who is signed in and what may they do".
///
/// It is the only type that mutates routing state, and it is the concrete type
/// behind ``AuthSessionProtocol`` — which is all any later phase is allowed to
/// see.
@MainActor
@Observable
public final class AuthSession {

    /// The signed-in account, or `nil`.
    public private(set) var user: AuthUser?
    /// The most recent `/verification/status` payload.
    public private(set) var verificationReport: VerificationStatusReport?
    /// Where the app should be right now.
    public private(set) var route: SessionRoute = .splash
    /// `true` while a session-level network call is in flight.
    public private(set) var isBusy = false

    private let service: AuthServiceProtocol
    private let store: AuthTokenStore
    private let analytics: AnalyticsClient

    public init(service: AuthServiceProtocol, store: AuthTokenStore, analytics: AnalyticsClient) {
        self.service = service
        self.store = store
        self.analytics = analytics
    }

    // MARK: - Boot

    /// Decides the launch destination from what is in the keychain.
    ///
    /// A stored-but-expired token is refreshed once; if that fails the local
    /// secrets are wiped and the user lands on the welcome screen.
    public func restore() async {
        isBusy = true
        defer { isBusy = false }

        guard let token = await store.token() else {
            route = .unauthenticated
            return
        }

        do {
            if token.expiresSoon() {
                let pair = try await service.refreshToken(token)
                user = pair.user
            }
            let fresh = try await service.currentUser()
            user = fresh
            await applyRouteForCurrentUser()
        } catch {
            // Any failure to prove the session is real means: sign in again.
            await store.clear()
            user = nil
            route = .unauthenticated
        }
    }

    // MARK: - Transitions

    /// Adopts a freshly issued session and routes accordingly.
    public func adopt(_ pair: TokenPair) async {
        user = pair.user
        await applyRouteForCurrentUser()
    }

    /// Re-reads `/verification/status` and re-routes.
    public func refreshVerification() async {
        guard user != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let report = try await service.verificationStatus()
            verificationReport = report
            if let current = user {
                let updated = AuthUser(
                    id: current.id,
                    email: current.email,
                    displayName: current.displayName,
                    emailVerified: current.emailVerified,
                    verificationStatus: report.status,
                    createdAt: current.createdAt,
                    handle: current.handle,
                    // The badge follows verification: a status that is no longer
                    // `verified` carries no country, exactly as the server's
                    // `effective_country()` reports it.
                    countryCode: report.status.grantsAccess ? current.countryCode : nil,
                    avatarURL: current.avatarURL
                )
                user = updated
                await store.updateUser(updated)
            }
            applyRoute(for: report.status, reason: report.rejectionReason)
        } catch {
            // Keep the last known state; the wall shows a retry affordance.
        }
    }

    /// Re-reads `/auth/me` and re-routes — the post-verification refresh.
    ///
    /// Distinct from ``refreshVerification()`` because an approval changes
    /// *two* fields — `verification_status` **and** `country_code` — and only
    /// `/auth/me` carries both. Distinct from ``restore()`` because a network
    /// failure here must keep the session, not wipe it: the fallback is the
    /// status endpoint, whose failure path already keeps the last known state.
    public func refreshUser() async {
        guard user != nil else { return }
        isBusy = true
        defer { isBusy = false }
        if let fresh = try? await service.currentUser() {
            user = fresh
            await applyRouteForCurrentUser()
        } else {
            isBusy = false
            await refreshVerification()
        }
    }

    /// Ends the session and returns to the welcome screen.
    public func signOut() async {
        isBusy = true
        defer { isBusy = false }
        try? await service.signOut()
        user = nil
        verificationReport = nil
        route = .unauthenticated
    }

    /// Routes to the OTP wall for an account whose email is unconfirmed.
    public func requireEmailVerification(for email: String) {
        route = .awaitingEmailVerification(email: email)
    }

    /// Sends the user back to the welcome screen without touching the keychain.
    public func showUnauthenticated() {
        route = .unauthenticated
    }

    // MARK: - Routing

    private func applyRouteForCurrentUser() async {
        guard let user else {
            route = .unauthenticated
            return
        }
        guard user.emailVerified else {
            route = .awaitingEmailVerification(email: user.email)
            return
        }
        if user.verificationStatus == .rejected || user.verificationStatus == .pendingReview {
            // Fetch the reason / timestamps the wall wants to show.
            if let report = try? await service.verificationStatus() {
                verificationReport = report
                applyRoute(for: report.status, reason: report.rejectionReason)
                return
            }
        }
        applyRoute(for: user.verificationStatus, reason: verificationReport?.rejectionReason)
    }

    private func applyRoute(for status: VerificationStatus, reason: String?) {
        switch status {
        case .verified:
            route = .feed
        case .rejected:
            route = .rejected(reason: reason)
            analytics.track(.verificationWallShown, properties: ["status": status.rawValue])
        case .unstarted, .inProgress, .pendingReview:
            route = .verificationWall(status)
            analytics.track(.verificationWallShown, properties: ["status": status.rawValue])
        }
    }
}

// MARK: - Public export surface

extension AuthSession: AuthSessionProtocol {

    nonisolated public var currentUser: AuthUser? {
        get async { await self.user }
    }

    nonisolated public var isVerified: Bool {
        get async { await self.user?.verificationStatus == .verified }
    }

    nonisolated public func requireVerified() async throws {
        guard let user = await self.user else { throw AuthGateError.notAuthenticated }
        guard user.verificationStatus == .verified else {
            throw AuthGateError.notVerified(user.verificationStatus)
        }
    }
}
