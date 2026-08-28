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
                title: "Verify your identity",
                message: "Sila only admits verified humans. Scan your government ID and complete a short liveness check — it takes about three minutes.",
                badgeText: "Action Required",
                badgeStyle: .warning,
                primaryActionTitle: "Start Verification",
                showsProcessingAnimation: false
            )
        case .inProgress:
            return WallPresentation(
                icon: "hourglass.bottomhalf.filled",
                title: "Finish your verification",
                message: "You started verifying but didn't finish. Pick up where you left off — nothing you submitted has been lost.",
                badgeText: "Action Required",
                badgeStyle: .warning,
                primaryActionTitle: "Continue Verification",
                showsProcessingAnimation: false
            )
        case .pendingReview:
            return WallPresentation(
                icon: "hourglass",
                title: "Under review",
                message: "Your documents are with our reviewers. Most decisions land within a few hours; you'll get an email either way.",
                badgeText: "Under Review",
                badgeStyle: .verified,
                primaryActionTitle: nil,
                showsProcessingAnimation: true
            )
        case .verified:
            return WallPresentation(
                icon: "checkmark.seal.fill",
                title: "You're verified",
                message: "Welcome to Sila. Every account you'll see here belongs to a real, verified human.",
                badgeText: "Verified",
                badgeStyle: .verified,
                primaryActionTitle: "Enter Sila",
                showsProcessingAnimation: false
            )
        case .rejected:
            return WallPresentation(
                icon: "xmark.octagon.fill",
                title: "Verification declined",
                message: "We couldn't verify your identity from what you submitted.",
                badgeText: "Rejected",
                badgeStyle: .danger,
                primaryActionTitle: "Appeal",
                showsProcessingAnimation: false
            )
        }
    }
}

/// Drives ``PendingVerificationWallScreen``.
///
/// Polls `/verification/status` on appear and on pull-to-refresh. Phase 2 will
/// replace ``startVerification()``'s stub with a push into the wizard.
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

    private let service: AuthServiceProtocol
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - status: Status known at construction time (from the session).
    ///   - service: Auth backend.
    ///   - analytics: Event sink.
    public init(
        status: VerificationStatus,
        service: AuthServiceProtocol,
        analytics: AnalyticsClient
    ) {
        self.status = status
        self.service = service
        self.analytics = analytics
    }

    /// How the current status should render.
    public var presentation: WallPresentation { .make(for: status) }

    /// Human-readable submission timestamp, when known.
    public var submittedText: String? {
        guard let submittedAt = report?.submittedAt else { return nil }
        return "Submitted \(Self.relativeFormatter.localizedString(for: submittedAt, relativeTo: Date()))"
    }

    /// Rejection reason from the API, when present.
    public var rejectionReason: String? { report?.rejectionReason }

    /// Fetches `/verification/status`.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let report = try await service.verificationStatus()
            self.report = report
            self.status = report.status
        } catch let error as APIError {
            toast = .error(error.userMessage)
        } catch {
            toast = .error("We couldn't check your status. Pull to try again.")
        }
    }

    /// Phase-2 entry point.
    ///
    /// The Verification module does not exist yet, so this records the intent
    /// and tells the user plainly rather than pretending to navigate.
    public func startVerification() {
        analytics.track(.verificationStarted, properties: ["status": status.rawValue])
        toast = .info("Identity verification arrives in the next release.")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
