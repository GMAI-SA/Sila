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
    @State private var toast: TNToastMessage?

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
            VStack(spacing: TNSpacing.xl) {
                Spacer(minLength: TNSpacing.xxl)

                ZStack {
                    Circle()
                        .fill(TNColor.danger.opacity(0.12))
                        .frame(width: 132, height: 132)
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(TNColor.danger)
                }
                .accessibilityHidden(true)

                VStack(spacing: TNSpacing.sm) {
                    TNBadge("Rejected", style: .danger)

                    Text("Verification declined")
                        .font(TNFont.displayL)
                        .foregroundStyle(TNColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("We couldn't verify your identity, so this account is locked. If you believe this was a mistake, you can appeal.")
                        .font(TNFont.bodyLight)
                        .foregroundStyle(TNColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, TNSpacing.lg)
                .accessibilityElement(children: .combine)

                if let reason, !reason.isEmpty {
                    TNCard(padding: TNSpacing.lg) {
                        VStack(alignment: .leading, spacing: TNSpacing.sm) {
                            Text("Reason given")
                                .font(TNFont.micro)
                                .tracking(0.8)
                                .foregroundStyle(TNColor.textMuted)
                            Text(reason)
                                .font(TNFont.body)
                                .foregroundStyle(TNColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, TNSpacing.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Reason given. \(reason)"))
                    .accessibilityHint(Text("The reviewer's explanation for the decision"))
                }

                VStack(spacing: TNSpacing.md) {
                    TNButton(
                        "Appeal this decision",
                        variant: .primary,
                        icon: "envelope",
                        accessibilityHint: "Opens your mail app with an appeal addressed to the TrustNet review team"
                    ) {
                        openAppeal()
                    }

                    TNButton(
                        "Sign out",
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: "Ends your session and returns to the welcome screen",
                        action: onSignOut
                    )
                }
                .padding(.horizontal, TNSpacing.lg)

                Spacer(minLength: TNSpacing.xxl)
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
            toast = .error("We couldn't open your mail app. Write to \(AppConfig.appealEmail).")
            return
        }
        openURL(url) { accepted in
            if !accepted {
                toast = .error("No mail app is set up. Write to \(AppConfig.appealEmail).")
            }
        }
    }

    private var appealURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppConfig.appealEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TrustNet verification appeal"),
            URLQueryItem(name: "body", value: appealBody)
        ]
        return components.url
    }

    private var appealBody: String {
        var lines = ["I'd like to appeal the verification decision on my TrustNet account."]
        if let email { lines.append(contentsOf: ["", "Account email: \(email)"]) }
        if let reason, !reason.isEmpty { lines.append("Reason given: \(reason)") }
        lines.append(contentsOf: ["", "Why I think this was a mistake:", ""])
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
