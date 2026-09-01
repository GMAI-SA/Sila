import SwiftUI

/// **Screen 7 — Rejected.**
///
/// A terminal state: the account is locked and there is no route forward
/// inside the app. The only affordances are an appeal (which leaves the app
/// for the system mail composer) and signing out.
@MainActor
public struct RejectedScreen: View {

    private let reason: String?
    private let email: String?
    private let analytics: AnalyticsClient
    private let onSignOut: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var toast: SLToastMessage?

    /// - Parameters:
    ///   - reason: Rejection reason from `/verification/status`.
    ///   - email: The user's address, quoted in the appeal mail body.
    ///   - analytics: Event sink.
    ///   - onSignOut: Ends the session.
    public init(
        reason: String?,
        email: String? = nil,
        analytics: AnalyticsClient,
        onSignOut: @escaping () -> Void
    ) {
        self.reason = reason
        self.email = email
        self.analytics = analytics
        self.onSignOut = onSignOut
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: SLSpacing.xl) {
                Spacer(minLength: SLSpacing.xxl)

                ZStack {
                    Circle()
                        .fill(SLColor.danger.opacity(0.12))
                        .frame(width: 132, height: 132)
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(SLColor.danger)
                }
                .accessibilityHidden(true)

                VStack(spacing: SLSpacing.sm) {
                    SLBadge(L10n.t("auth.wall.badge.rejected"), style: .danger)

                    Text(L10n.t("auth.rejected.title"))
                        .font(SLFont.displayL)
                        .foregroundStyle(SLColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(L10n.t("auth.rejected.message"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, SLSpacing.lg)
                .accessibilityElement(children: .combine)

                if let reason, !reason.isEmpty {
                    SLCard(padding: SLSpacing.lg) {
                        VStack(alignment: .leading, spacing: SLSpacing.sm) {
                            Text(L10n.t("auth.rejected.reasonLabel"))
                                .font(SLFont.micro)
                                .tracking(0.8)
                                .foregroundStyle(SLColor.textMuted)
                            // Written by a reviewer, in whichever language they
                            // reviewed in — so it reads in its own direction.
                            Text(reason)
                                .font(SLFont.body)
                                .foregroundStyle(SLColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .slContentDirection(
                                    TextDirection.resolve(languageCode: nil, text: reason)
                                )
                        }
                    }
                    .padding(.horizontal, SLSpacing.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(L10n.t("auth.rejected.reason.a11yLabel", reason)))
                    .accessibilityHint(Text(L10n.t("auth.rejected.reason.hint")))
                }

                VStack(spacing: SLSpacing.md) {
                    SLButton(
                        L10n.t("auth.rejected.appeal"),
                        variant: .primary,
                        icon: "envelope",
                        accessibilityHint: L10n.t("auth.rejected.appeal.hint")
                    ) {
                        openAppeal()
                    }

                    SLButton(
                        L10n.t("common.signOut"),
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: L10n.t("auth.signOut.hint"),
                        action: onSignOut
                    )
                }
                .padding(.horizontal, SLSpacing.lg)

                Spacer(minLength: SLSpacing.xxl)
            }
            .frame(maxWidth: .infinity)
        }
        .tnScreenBackground()
        .tnToast($toast)
    }

    /// Builds and opens a pre-filled `mailto:` appeal.
    private func openAppeal() {
        analytics.track(.appealOpened)
        guard let url = appealURL else {
            toast = .error(L10n.t("auth.rejected.appeal.noMailApp", AppConfig.appealEmail))
            return
        }
        openURL(url) { accepted in
            if !accepted {
                toast = .error(L10n.t("auth.rejected.appeal.noMailConfigured", AppConfig.appealEmail))
            }
        }
    }

    private var appealURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppConfig.appealEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: L10n.t("auth.rejected.appeal.subject")),
            URLQueryItem(name: "body", value: appealBody)
        ]
        return components.url
    }

    private var appealBody: String {
        var lines = [L10n.t("auth.rejected.appeal.bodyIntro")]
        if let email {
            lines.append(contentsOf: ["", L10n.t("auth.rejected.appeal.bodyEmail", email)])
        }
        if let reason, !reason.isEmpty {
            lines.append(L10n.t("auth.rejected.appeal.bodyReason", reason))
        }
        lines.append(contentsOf: ["", L10n.t("auth.rejected.appeal.bodyPrompt"), ""])
        return lines.joined(separator: "\n")
    }
}

#Preview("RejectedScreen") {
    RejectedScreen(
        reason: "The photo of your ID was too blurry for our reviewers to read the document number.",
        email: "aziz@example.com",
        analytics: RecordingAnalyticsClient(),
        onSignOut: {}
    )
}
