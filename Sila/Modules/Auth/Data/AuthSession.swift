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
    /// Looking around without an account: the square, read-only.
    ///
    /// Deliberately a route rather than a flag on ``feed``. A guest is not a
    /// signed-in person with fewer permissions — there is no account, no
    /// token, no country and nothing to like *with* — and every screen that
    /// forgot to check a flag would have been a screen that crashed or lied.
    case guest
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
    /// Set by ``retryVerification(retaking:)`` for the one wall that call
    /// opens: back into the document flow at once, at the camera, after the
    /// pre-screen turned a submission away. Every other route clears it.
    public private(set) var documentRetake: DocumentRetake?
    /// `true` while a session-level network call is in flight.
    public private(set) var isBusy = false
    /// `true` when the app opened on this device's copy of the account because
    /// the server could not be reached. Cleared once `/auth/me` answers, which
    /// the session keeps trying by itself.
    public private(set) var isOffline = false
    /// What a guest was reaching for when they were invited to join, so the
    /// invitation can name it: "Join Sila to reply" rather than a generic
    /// prompt. Cleared when the sheet closes.
    public var joinPrompt: JoinPrompt?

    /// Looks around without an account.
    public func browseAsGuest() {
        analytics.track(.guestBrowsingStarted)
        route = .guest
    }

    /// Leaves the read-only surface for the door.
    public func leaveGuest() {
        joinPrompt = nil
        route = .unauthenticated
    }

    private let service: AuthServiceProtocol
    private let store: AuthTokenStore
    private let analytics: AnalyticsClient
    /// How long to wait before the `attempt`th try to reach `/auth/me` again
    /// after an offline launch.
    private let reconnectDelay: @Sendable (Int) async -> Void
    private var reconnectTask: Task<Void, Never>?

    /// - Parameter reconnectDelay: The wait between tries to reach the server
    ///   after an offline launch. Defaults to 2, 4, 8… seconds, capped at a
    ///   minute; each try itself waits for the network to come back.
    public init(
        service: AuthServiceProtocol,
        store: AuthTokenStore,
        analytics: AnalyticsClient,
        reconnectDelay: @escaping @Sendable (Int) async -> Void = { await AuthSession.backoff($0) }
    ) {
        self.service = service
        self.store = store
        self.analytics = analytics
        self.reconnectDelay = reconnectDelay
    }

    /// 2, 4, 8, 16, 32, then 60 seconds between tries.
    nonisolated public static func backoff(_ attempt: Int) async {
        let seconds = min(60, 2 << min(attempt, 5))
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    // MARK: - Boot

    /// Decides the launch destination from what is in the keychain.
    ///
    /// A stored-but-expired token is refreshed once, then `/auth/me` confirms
    /// the account. Only the server saying the credentials are dead signs the
    /// person out. A phone that is offline, in a lift, or opening the app
    /// while a deploy answers `502` keeps its session: the app opens on the
    /// account cached in the keychain, says it is offline, and keeps trying.
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
            isOffline = false
            await applyRouteForCurrentUser()
        } catch {
            await restoreFailed(error)
        }
    }

    /// What a launch that could not confirm the session does next.
    private func restoreFailed(_ error: Error) async {
        let failure = SessionCheckFailure(error)
        if failure == .refused {
            await endRefusedSession()
            return
        }
        guard let cached = await store.user() else {
            // Nothing to route on. The keychain is kept, so the next launch
            // tries again; the person can sign in meanwhile.
            route = .unauthenticated
            return
        }
        user = cached
        applyCachedRoute()
        if failure == .unreachable {
            isOffline = true
            scheduleReconnect()
        }
    }

    /// The server said these credentials will never work again.
    private func endRefusedSession() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        await store.clear()
        user = nil
        isOffline = false
        verificationReport = nil
        documentRetake = nil
        route = .unauthenticated
    }

    /// Keeps trying `/auth/me` after an offline launch, until it answers or
    /// the session ends some other way.
    ///
    /// - Parameter immediately: Try once before the first wait.
    private func scheduleReconnect(immediately: Bool = false) {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectTask = Task { [weak self] in
            var attempt = 0
            var wait = !immediately
            while !Task.isCancelled {
                if wait { await delay(attempt) }
                wait = true
                guard !Task.isCancelled, let self else { return }
                if await self.reconnect() { return }
                attempt += 1
            }
        }
    }

    /// The app came back to the foreground: if it is still running on the
    /// cached account, try the server now rather than at the end of the
    /// current wait, which can be a minute long.
    public func retryIfOffline() {
        guard isOffline else { return }
        scheduleReconnect(immediately: true)
    }

    /// One more try. `true` when there is nothing left to try for.
    private func reconnect() async -> Bool {
        guard isOffline, user != nil else { return true }
        do {
            let fresh = try await service.currentUser()
            guard isOffline, user != nil else { return true }
            user = fresh
            isOffline = false
            await applyRouteForCurrentUser()
            return true
        } catch {
            guard isOffline, user != nil else { return true }
            switch SessionCheckFailure(error) {
            case .refused:
                await endRefusedSession()
                return true
            case .declined:
                // The server answered; whatever it said, the screens that
                // make the next call will hear it too.
                isOffline = false
                return true
            case .unreachable:
                return false
            }
        }
    }

    /// Stops trying to reach the server for an offline launch — the session
    /// was replaced, confirmed another way, or ended.
    private func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isOffline = false
    }

    // MARK: - Transitions

    /// Adopts a freshly issued session and routes accordingly.
    public func adopt(_ pair: TokenPair) async {
        stopReconnecting()
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
                var updated = AuthUser(
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
                    avatarURL: current.avatarURL,
                    phone: current.phone,
                    verifiedName: current.verifiedName,
                    hideVerifiedName: current.hideVerifiedName,
                    needsInterestPrompt: current.needsInterestPrompt,
                    experimentBucket: current.experimentBucket
                )
                updated.guidelinesVersion = current.guidelinesVersion
                updated.currentGuidelinesVersion = current.currentGuidelinesVersion
                // The status says nothing about a vouch; only `/auth/me` does.
                updated = updated.settingVouch(current.vouch, standing: current.standing)
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
            stopReconnecting()
            user = fresh
            await applyRouteForCurrentUser()
        } else {
            isBusy = false
            await refreshVerification()
        }
    }

    /// The first-run subjects step was answered or skipped; the server has
    /// stamped it (contract v19), and so does the cached account, so the step
    /// never shows again on this device even before the next `/auth/me`.
    public func markInterestsPrompted() async {
        guard let current = user, current.needsInterestPrompt else { return }
        let updated = current.settingNeedsInterestPrompt(false)
        user = updated
        await store.updateUser(updated)
    }

    /// Reconciles after a call was refused `403 unverified`.
    ///
    /// Contract v9 closed every authenticated route to an unverified account,
    /// so a verification that lapses mid-session turns the whole app into
    /// error alerts with Retry buttons that can only produce the same 403. The
    /// answer is not to guess a screen: `GET /auth/me` deliberately stays open
    /// so the client can find out *why* it was refused, and ``refreshUser()``
    /// already turns that answer into a route.
    ///
    /// The one case worth spelling out is disagreement. If `/auth/me` still
    /// says verified while other calls are refusing, the refusal is believed:
    /// it is the more recent fact and the more restrictive one, and the wall at
    /// least offers a way forward. Sitting on the feed re-erroring offers none.
    public func reconcileVerification() async {
        guard user != nil else { return }
        await refreshUser()
        guard route == .feed else { return }
        analytics.track(.verificationGateTripped, properties: ["source": "disagreement"])
        route = .verificationWall(.unstarted)
    }

    /// Takes the vouch a claim just produced (contract v24), before the next
    /// `/auth/me` says so: the wall's copy becomes "Waiting for @aziz to
    /// confirm it's you" at once.
    public func adoptVouch(_ vouch: VouchState?, standing: Standing = .noStanding) async {
        guard let current = user else { return }
        let updated = current.settingVouch(vouch, standing: standing)
        user = updated
        await store.updateUser(updated)
        await applyRouteForCurrentUser()
    }

    /// Ends the session and returns to the welcome screen.
    /// Runs before the session is dropped — the push registration is
    /// withdrawn while there is still a token to withdraw it with.
    public var willSignOut: (@MainActor () async -> Void)?

    public func signOut() async {
        isBusy = true
        defer { isBusy = false }
        stopReconnecting()
        await willSignOut?()
        try? await service.signOut()
        // The local wipe is what ends the session, whichever service is
        // plugged in, and it takes the export and the cached responses with it.
        await store.clear()
        user = nil
        verificationReport = nil
        documentRetake = nil
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
        // A vouched account is a member: the feed, whatever the identity
        // pipeline says — a refused document included (contract v24 §2).
        if user.isVouched {
            applyRoute(for: user.verificationStatus, reason: nil)
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

    /// Routes on the account as this device last knew it, with no network:
    /// the offline launch, where every call would only wait for a connection
    /// that is not there. The wall's reason and timestamps follow once the
    /// server answers.
    private func applyCachedRoute() {
        guard let user else {
            route = .unauthenticated
            return
        }
        guard user.emailVerified else {
            route = .awaitingEmailVerification(email: user.email)
            return
        }
        applyRoute(for: user.verificationStatus, reason: verificationReport?.rejectionReason)
    }

    /// Puts a rejected account back on the wall so it can try the other
    /// verification route. The status on the server is still `rejected`;
    /// only the screen changes, and the next refresh routes on whatever the
    /// new attempt produced.
    ///
    /// - Parameter retake: After a rejection by the pre-screen, the wall opens
    ///   the document flow straight away instead of offering the routes —
    ///   new pictures are the answer, not another door.
    public func retryVerification(retaking retake: DocumentRetake? = nil) {
        documentRetake = retake
        route = .verificationWall(.rejected)
        analytics.track(.verificationWallShown, properties: ["status": retake == nil ? "rejected_retry" : "rejected_retake"])
    }

    private func applyRoute(for status: VerificationStatus, reason: String?) {
        documentRetake = nil
        if user?.isVouched == true, status != .verified {
            route = .feed
            return
        }
        switch status {
        case .verified:
            route = .feed
        case .rejected where user?.vouch?.isPending == true:
            // A claim waiting for its voucher is the wall's to show, with
            // its own copy (contract v24 §2) — a refused document does not
            // stop somebody being vouched for, and the claim is what they
            // are waiting on now.
            route = .verificationWall(.rejected)
            analytics.track(.verificationWallShown, properties: ["status": "vouch_pending"])
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
