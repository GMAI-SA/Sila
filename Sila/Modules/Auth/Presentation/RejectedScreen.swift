import SwiftUI

/// **Screen 7 — Rejected.**
///
/// A terminal state, and the one screen the platform owes an explanation on:
/// the account is closed, the reason is shown, and the person can contest it
/// **here**. An appeal is recorded on the server and decided by a moderator
/// on the dashboard. Until contract v13 the only appeal was a `mailto:` — a
/// decision nobody could contest inside the product was not one the
/// platform could stand behind.
///
/// Two kinds of closure share the screen and differ in one thing. A
/// *rejection* may be tried again by the other route. A *withdrawn badge*
/// (`verification_revoked`) may only be appealed: re-running Nafath around a
/// moderator's decision is not a way back, so the button is not offered.
@MainActor
public struct RejectedScreen: View {

    private let reason: String?
    private let appealOnFile: VerificationAppealReceipt?
    private let analytics: AnalyticsClient
    private let onAppeal: ((String) async throws -> VerificationAppealReceipt)?
    private let onTryAgain: (() -> Void)?
    private let onSignOut: () -> Void

    @State private var showsForm = false
    @State private var message = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var sent: VerificationAppealReceipt?
    @State private var toast: SLToastMessage?

    /// - Parameters:
    ///   - reason: Rejection reason from `/verification/status`.
    ///   - appeal: The appeal already on file against this decision, if any.
    ///   - analytics: Event sink.
    ///   - onAppeal: Sends an appeal. `nil` hides the appeal affordance.
    ///   - onTryAgain: Reopens the verification wall so the person can try
    ///     the other route — a document rejected for a blurry photograph is
    ///     not a verdict on the person. `nil` hides the button; so does a
    ///     withdrawn badge.
    ///   - onSignOut: Ends the session.
    public init(
        reason: String?,
        appeal: VerificationAppealReceipt? = nil,
        analytics: AnalyticsClient,
        onAppeal: ((String) async throws -> VerificationAppealReceipt)? = nil,
        onTryAgain: (() -> Void)? = nil,
        onSignOut: @escaping () -> Void
    ) {
        self.reason = reason
        self.appealOnFile = appeal
        self.analytics = analytics
        self.onAppeal = onAppeal
        self.onTryAgain = onTryAgain
        self.onSignOut = onSignOut
    }

    private var isRevocation: Bool { VerificationRejection.isRevocation(reason) }

    /// The appeal to show: the one just sent, else the one the server knew about.
    private var receipt: VerificationAppealReceipt? { sent ?? appealOnFile }

    private var remaining: Int {
        VerificationAppealReceipt.maximumLength
            - message.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSend: Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && remaining >= 0 && !isSending && onAppeal != nil
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

                    Text(L10n.t(isRevocation ? "auth.rejected.revoked.title" : "auth.rejected.title"))
                        .font(SLFont.displayL)
                        .foregroundStyle(SLColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(L10n.t(isRevocation ? "auth.rejected.revoked.message" : "auth.rejected.message"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, SLSpacing.lg)
                .accessibilityElement(children: .combine)

                if let shown = VerificationRejection.display(reason) {
                    SLCard(padding: SLSpacing.lg) {
                        VStack(alignment: .leading, spacing: SLSpacing.sm) {
                            Text(L10n.t("auth.rejected.reasonLabel"))
                                .font(SLFont.micro)
                                .tracking(0.8)
                                .foregroundStyle(SLColor.textMuted)
                            // A machine reason reads in the interface language;
                            // a reviewer's words read in their own direction.
                            Text(shown)
                                .font(SLFont.body)
                                .foregroundStyle(SLColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .slContentDirection(
                                    VerificationRejection.isMachineReason(reason)
                                        ? TextDirection.resolve(languageCode: L10n.languageCode, text: shown)
                                        : TextDirection.resolve(languageCode: nil, text: shown)
                                )
                        }
                    }
                    .padding(.horizontal, SLSpacing.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(L10n.t("auth.rejected.reason.a11yLabel", shown)))
                    .accessibilityHint(Text(L10n.t("auth.rejected.reason.hint")))
                }

                if let receipt {
                    appealReceipt(receipt)
                        .padding(.horizontal, SLSpacing.lg)
                } else if showsForm {
                    appealForm
                        .padding(.horizontal, SLSpacing.lg)
                }

                VStack(spacing: SLSpacing.md) {
                    if let onTryAgain, !isRevocation {
                        SLButton(
                            L10n.t("auth.rejected.tryAgain"),
                            variant: .primary,
                            icon: "arrow.counterclockwise",
                            accessibilityHint: L10n.t("auth.rejected.tryAgain.hint"),
                            action: onTryAgain
                        )
                    }

                    if receipt == nil, !showsForm, onAppeal != nil {
                        SLButton(
                            L10n.t("auth.rejected.appeal"),
                            variant: (onTryAgain == nil || isRevocation) ? .primary : .secondary,
                            icon: "text.bubble",
                            accessibilityHint: L10n.t("auth.rejected.appeal.hint")
                        ) {
                            analytics.track(.appealOpened)
                            withAnimation { showsForm = true }
                        }
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

    // MARK: - Appeal

    private var appealForm: some View {
        SLCard(padding: SLSpacing.lg) {
            VStack(alignment: .leading, spacing: SLSpacing.md) {
                Text(L10n.t("auth.rejected.appeal.prompt"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SLTextField(
                    L10n.t("auth.rejected.appeal.field"),
                    text: $message,
                    placeholder: L10n.t("auth.rejected.appeal.placeholder"),
                    autocapitalization: .sentences,
                    accessibilityHint: L10n.t("auth.rejected.appeal.prompt")
                )
                // Their own account of what happened, in whichever language
                // they think in.
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: message))

                Text(L10n.plural("safety.appeal.charactersLeft", remaining))
                    .font(SLFont.micro)
                    .foregroundStyle(remaining < 0 ? SLColor.danger : SLColor.textMuted)

                if let sendError {
                    Text(sendError)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isStaticText)
                }

                SLButton(
                    L10n.t("auth.rejected.appeal.send"),
                    variant: .primary,
                    isLoading: isSending,
                    isEnabled: canSend,
                    accessibilityHint: L10n.t("auth.rejected.appeal.send.hint"),
                    asyncAction: { await send() }
                )
            }
        }
    }

    private func appealReceipt(_ receipt: VerificationAppealReceipt) -> some View {
        SLCard(padding: SLSpacing.lg) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(
                    receipt.submittedAt.map { L10n.t("auth.rejected.appeal.receipt", SLFormat.date($0)) }
                        ?? L10n.t("auth.rejected.appeal.receipt.noDate")
                )
                .font(SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
                Text(receipt.status.label)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func send() async {
        guard let onAppeal, canSend else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            let receipt = try await onAppeal(trimmed)
            withAnimation {
                sent = receipt
                showsForm = false
            }
            message = ""
            toast = .success(L10n.t("auth.rejected.appeal.sent"))
        } catch let error as APIError where error.code == .alreadyAppealed {
            // The answer to the question, not a failure: it is already in.
            analytics.track(.appealAlreadyOnFile)
            withAnimation {
                sent = VerificationAppealReceipt(status: .pending)
                showsForm = false
            }
        } catch let error as APIError {
            sendError = error.userMessage
        } catch {
            sendError = error.localizedDescription
        }
    }
}

#Preview("RejectedScreen") {
    RejectedScreen(
        reason: "The photo of your ID was too blurry for our reviewers to read the document number.",
        analytics: RecordingAnalyticsClient(),
        onAppeal: { _ in VerificationAppealReceipt(status: .pending, submittedAt: Date()) },
        onSignOut: {}
    )
}

#Preview("RejectedScreen — withdrawn") {
    RejectedScreen(
        reason: "verification_revoked",
        appeal: VerificationAppealReceipt(status: .pending, submittedAt: Date()),
        analytics: RecordingAnalyticsClient(),
        onTryAgain: {},
        onSignOut: {}
    )
}
