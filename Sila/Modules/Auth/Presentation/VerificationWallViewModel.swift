import Foundation
import Observation
import SwiftUI

/// Everything the wall needs to render one ``VerificationStatus``.
///
/// A value type, so "does status X show the Start Verification button?" is a
/// pure function that tests can assert on without instantiating a view.
public struct WallPresentation: Equatable, Sendable {

    /// SF Symbol for the hero glyph.
    public let icon: String
    /// Headline.
    public let title: String
    /// Body copy.
    public let message: String
    /// Badge text, e.g. "Under Review".
    public let badgeText: String
    /// Badge colouring.
    public let badgeStyle: SLBadge.Style
    /// Label for the primary CTA, or `nil` when there is no CTA.
    public let primaryActionTitle: String?
    /// Whether the hero glyph animates (the "processing" indicator).
    public let showsProcessingAnimation: Bool

    /// Maps a status to its presentation.
    /// - Parameter status: The user's current verification stage.
    public static func make(for status: VerificationStatus) -> WallPresentation {
        switch status {
        case .unstarted:
            return WallPresentation(
                icon: "person.badge.shield.checkmark",
                title: L10n.t("auth.wall.unstarted.title"),
                message: L10n.t("auth.wall.unstarted.message"),
                badgeText: L10n.t("auth.wall.badge.actionRequired"),
                badgeStyle: .warning,
                primaryActionTitle: L10n.t("auth.wall.unstarted.action"),
                showsProcessingAnimation: false
            )
        case .inProgress:
            return WallPresentation(
                icon: "hourglass.bottomhalf.filled",
                title: L10n.t("auth.wall.inProgress.title"),
                message: L10n.t("auth.wall.inProgress.message"),
                badgeText: L10n.t("auth.wall.badge.actionRequired"),
                badgeStyle: .warning,
                primaryActionTitle: L10n.t("auth.wall.inProgress.action"),
                showsProcessingAnimation: false
            )
        case .pendingReview:
            return WallPresentation(
                icon: "hourglass",
                title: L10n.t("auth.wall.pendingReview.title"),
                message: L10n.t("auth.wall.pendingReview.message"),
                badgeText: L10n.t("auth.wall.badge.underReview"),
                badgeStyle: .verified,
                primaryActionTitle: nil,
                showsProcessingAnimation: true
            )
        case .verified:
            return WallPresentation(
                icon: "checkmark.seal.fill",
                title: L10n.t("auth.wall.verified.title"),
                message: L10n.t("auth.wall.verified.message"),
                badgeText: L10n.t("auth.wall.badge.verified"),
                badgeStyle: .verified,
                primaryActionTitle: L10n.t("auth.wall.verified.action"),
                showsProcessingAnimation: false
            )
        case .rejected:
            return WallPresentation(
                icon: "xmark.octagon.fill",
                title: L10n.t("auth.wall.rejected.title"),
                message: L10n.t("auth.wall.rejected.message"),
                badgeText: L10n.t("auth.wall.badge.rejected"),
                badgeStyle: .danger,
                primaryActionTitle: L10n.t("auth.wall.rejected.action"),
                showsProcessingAnimation: false
            )
        }
    }
}

/// Drives ``PendingVerificationWallScreen``.
///
/// Reads `/verification/status` on appear and on pull-to-refresh, and — while
/// a submission is under review — every few seconds for a few minutes: the
/// pre-screen answers within a minute, and a person who just submitted should
/// not have to pull to hear that the photo was of the wrong thing. The Nafath
/// flow itself is presented by the screen; ``startVerification()`` remains as
/// the verification kill switch's honest off state.
@MainActor
@Observable
public final class VerificationWallViewModel {

    /// The status currently being displayed.
    public private(set) var status: VerificationStatus
    /// The full report, when one has been fetched.
    public private(set) var report: VerificationStatusReport?
    /// `true` while the status is being refreshed.
    public private(set) var isRefreshing = false
    /// Banner message.
    public var toast: SLToastMessage?
    /// The in-place "are you sure" before a withdrawal.
    public var isConfirmingWithdrawal = false
    public private(set) var isWithdrawing = false
    /// Set while the document flow on screen is the pre-screen's retake: its
    /// camera opens on this document, and cancelling goes back to the
    /// rejected screen.
    public var retake: DocumentRetake?

    private let service: AuthServiceProtocol
    private let verification: VerificationServiceProtocol?
    private let analytics: AnalyticsClient
    private let onDecision: (@MainActor () async -> Void)?
    /// Waits between reads while under review. Injectable so tests do not.
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// - Parameters:
    ///   - status: Status known at construction time (from the session).
    ///   - service: Auth backend.
    ///   - verification: Where a waiting submission is withdrawn. `nil` never
    ///     offers the withdrawal.
    ///   - analytics: Event sink.
    ///   - onDecision: A submission under review was rejected while the wall
    ///     watched — by a moderator or the pre-screen. The session re-routes
    ///     to the rejected screen, which carries the reason, the retake and
    ///     the appeal; the wall has none of those to offer.
    public init(
        status: VerificationStatus,
        service: AuthServiceProtocol,
        verification: VerificationServiceProtocol? = nil,
        analytics: AnalyticsClient,
        onDecision: (@MainActor () async -> Void)? = nil
    ) {
        self.status = status
        self.service = service
        self.verification = verification
        self.analytics = analytics
        self.onDecision = onDecision
    }

    /// How the current status should render.
    public var presentation: WallPresentation { .make(for: status) }

    /// Human-readable submission timestamp, when known.
    public var submittedText: String? {
        guard let submittedAt = report?.submittedAt else { return nil }
        return L10n.t("auth.wall.submittedAt", SLFormat.relative(submittedAt))
    }

    /// Rejection reason from the API, when present.
    public var rejectionReason: String? { report?.rejectionReason }

    /// The nationality the person declared, when the server has one.
    public var declaredNationality: String? { report?.nationality }
    /// Nafath is open to this account; otherwise it shows as "coming soon".
    public var nafathAvailable: Bool { report?.nafathAvailable ?? false }

    /// Whether a nationality claim goes straight to Nafath, skipping the
    /// chooser: only a Nafath-only nationality, and only while Nafath is live.
    /// What "Start" opens: the nationality question when there is no claim,
    /// Nafath only for a Nafath-only claim while Nafath is live, otherwise the
    /// method chooser. Every door into Nafath goes through this rule.
    public enum StartStep: Equatable, Sendable { case pickNationality, nafath, chooseMethod }

    nonisolated public static func startStep(declared: String?, nafathAvailable: Bool) -> StartStep {
        guard let declared, !declared.isEmpty else { return .pickNationality }
        return routesStraightToNafath(claim: declared, nafathAvailable: nafathAvailable) ? .nafath : .chooseMethod
    }

    nonisolated public static func routesStraightToNafath(claim: String, nafathAvailable: Bool) -> Bool {
        nafathAvailable && DocumentVerificationViewModel.nafathOnly.contains(claim.uppercased())
    }
    /// The birthdate the person declared, as `YYYY-MM-DD`, or `nil`.
    public var declaredDateOfBirth: String? { report?.dateOfBirth }

    /// Offer "Withdraw and start again" — exactly while the server says a
    /// submission waits for review (contract v25).
    public var canWithdraw: Bool { verification != nil && report?.canWithdraw == true }

    /// Takes a report another call produced (declaring the nationality
    /// answers with one) so the wall reflects it without a second round trip.
    public func adopt(_ report: VerificationStatusReport) {
        self.report = report
        self.status = report.status
    }

    /// Fetches `/verification/status`.
    /// - Parameter quietly: A background read says nothing when it fails;
    ///   the next one, or the person's own pull, will.
    public func refresh(quietly: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let waited = status == .pendingReview
        var decided = false
        do {
            let report = try await service.verificationStatus()
            self.report = report
            self.status = report.status
            decided = waited && report.status == .rejected
        } catch let error as APIError {
            if !quietly && !error.isCancellation { toast = .error(error.userMessage) }
        } catch {
            if !quietly { toast = .error(L10n.t("auth.wall.error.statusCheckFailed")) }
        }
        isRefreshing = false
        if decided, let onDecision {
            analytics.track(.verificationWallShown, properties: ["status": "decided_while_waiting"])
            await onDecision()
        }
    }

    /// Reads the status every `interval` while it is `pending_review`, at most
    /// `attempts` times, and stops at the first answer or when the screen
    /// goes (the task is cancelled). Most decisions a person waits for here
    /// are the pre-screen's, within a minute; after a few minutes the pull
    /// and "Check status" are there.
    public func watchForDecision(every interval: Duration = .seconds(10), attempts: Int = 18) async {
        for _ in 0..<attempts {
            guard status == .pendingReview else { return }
            do { try await pause(interval) } catch { return }
            guard !Task.isCancelled, status == .pendingReview else { return }
            await refresh(quietly: true)
        }
    }

    /// Takes back the submission waiting for review (contract v25), after the
    /// in-place confirmation. On ``WithdrawalOutcome/withdrawn(_:)`` the wall
    /// is back at the start and the caller opens the methods again.
    public func withdraw() async -> WithdrawalOutcome {
        guard let verification, canWithdraw, !isWithdrawing else { return .failed }
        isWithdrawing = true
        defer { isWithdrawing = false }
        do {
            let report = try await verification.withdrawDocument()
            adopt(report)
            isConfirmingWithdrawal = false
            return .withdrawn(report)
        } catch let error as APIError where error.code == .nothingToWithdraw {
            // Decided — or taken back elsewhere — before this arrived. Said,
            // and the wall shows where it stands now; a rejection goes on to
            // the rejected screen.
            isConfirmingWithdrawal = false
            toast = .info(error.userMessage)
            await refresh()
            return .nothingWaiting
        } catch let error as APIError {
            if !error.isCancellation { toast = .error(error.userMessage) }
            return .failed
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
            return .failed
        }
    }

    /// The kill switch's off state.
    ///
    /// When the Verification module is switched off, the wall screen falls
    /// back to this: record the intent, tell the user plainly. With the module
    /// on, ``PendingVerificationWallScreen`` opens the Nafath flow instead and
    /// never calls this.
    public func startVerification() {
        analytics.track(.verificationStarted, properties: ["status": status.rawValue])
        toast = .info(L10n.t("auth.wall.verificationComingSoon"))
    }
}
