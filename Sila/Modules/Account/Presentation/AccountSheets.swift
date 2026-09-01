import SwiftUI

// MARK: - Password

/// `POST /me/password`.
///
/// The current password is the first field, not a footnote at the bottom: it is
/// the thing that makes this call safe, and a form that asks for it last teaches
/// people to fill it in without reading what they are confirming.
@MainActor
struct PasswordChangeSheet: View {

    @Bindable var viewModel: AccountViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                if viewModel.passwordChanged != nil {
                    changed
                } else {
                    form
                }
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: AccountSheet.password.title)
        .toolbar { closeButton(viewModel) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            Text(L10n.t("account.password.intro"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SLTextField(
                L10n.t("account.field.currentPassword.label"),
                text: $viewModel.passwordCurrent,
                placeholder: L10n.t("account.password.current.placeholder"),
                isSecure: true,
                contentType: .password,
                accessibilityHint: L10n.t("account.password.current.hint")
            )

            SLTextField(
                L10n.t("account.password.new.label"),
                text: $viewModel.passwordNew,
                placeholder: L10n.plural(
                    "account.password.new.placeholder",
                    AccountLimits.minimumPasswordLength
                ),
                isSecure: true,
                contentType: .newPassword,
                accessibilityHint: L10n.t("account.password.new.hint")
            )

            SLTextField(
                L10n.t("account.password.repeat.label"),
                text: $viewModel.passwordRepeat,
                placeholder: L10n.t("account.password.repeat.placeholder"),
                isSecure: true,
                contentType: .newPassword,
                error: viewModel.passwordValidationError,
                accessibilityHint: L10n.t("account.password.repeat.hint")
            )

            if let error = viewModel.passwordError {
                errorBox(error)
            }

            SLButton(
                L10n.t("account.password.submit"),
                variant: .primary,
                isLoading: viewModel.isChangingPassword,
                isEnabled: viewModel.canChangePassword,
                accessibilityHint: L10n.t("account.password.submit.hint"),
                asyncAction: { await viewModel.changePassword() }
            )
        }
    }

    private var changed: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: "checkmark.shield.fill",
                title: L10n.t("account.password.changed.title"),
                subtitle: viewModel.passwordChangeOutcome,
                tint: SLColor.secondary
            )

            SLButton(
                L10n.t("account.password.signOutNow"),
                variant: .secondary,
                accessibilityHint: L10n.t("account.password.signOutNow.hint"),
                action: {
                    viewModel.presentedSheet = nil
                    viewModel.signOut()
                }
            )

            SLButton(
                L10n.t("account.password.staySignedIn"),
                variant: .ghost,
                size: .compact,
                accessibilityHint: L10n.t("account.password.staySignedIn.hint"),
                action: { viewModel.presentedSheet = nil }
            )
        }
    }
}

// MARK: - Email

/// `POST /me/email/request` → `POST /me/email/confirm`.
///
/// Two steps, and the screen says where the code goes before it is sent. That
/// detail is not a nicety: the code arrives at the address being *moved to*, so
/// somebody who mistypes it will sit waiting on a mailbox that never receives
/// anything, and somebody who assumes it goes to their current inbox will report
/// the feature as broken.
@MainActor
struct EmailChangeSheet: View {

    @Bindable var viewModel: AccountViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                switch viewModel.emailStage {
                case .entry: entry
                case let .awaitingCode(address): code(sentTo: address)
                case let .confirmed(address): confirmed(address)
                }
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: AccountSheet.email.title)
        .toolbar { closeButton(viewModel) }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            Text(L10n.t(
                "account.email.intro",
                viewModel.account?.email ?? L10n.t("account.email.intro.thisAddress")
            ))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SLTextField(
                L10n.t("account.field.currentPassword.label"),
                text: $viewModel.emailPassword,
                placeholder: L10n.t("account.field.currentPassword.placeholder"),
                isSecure: true,
                contentType: .password,
                accessibilityHint: L10n.t("account.email.password.hint")
            )

            // An address is Latin text with a `@` and dots in it; laid out
            // right-to-left the domain ends up before the local part.
            SLTextField(
                L10n.t("account.email.new.label"),
                text: $viewModel.emailNew,
                placeholder: "you@newaddress.com",
                keyboard: .emailAddress,
                contentType: .emailAddress,
                accessibilityHint: L10n.t("account.email.new.hint")
            )
            .slContentDirection(.leftToRight)

            if let error = viewModel.emailError {
                errorBox(error)
            }

            SLButton(
                L10n.t("account.email.send"),
                variant: .primary,
                isLoading: viewModel.isWorkingOnEmail,
                isEnabled: viewModel.canRequestEmailChange,
                accessibilityHint: L10n.t("account.email.send.hint"),
                asyncAction: { await viewModel.requestEmailChange() }
            )
        }
    }

    private func code(sentTo address: String) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLCard {
                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    Text(L10n.t("account.email.code.sentTo"))
                        .font(SLFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(SLColor.textSecondary)
                    Text(address)
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textPrimary)
                        .slContentDirection(.leftToRight)
                    Text(L10n.t("account.email.code.note"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            // A one-time code is digits. It is typed and read left-to-right.
            SLTextField(
                L10n.t("account.email.code.label"),
                text: $viewModel.emailCode,
                placeholder: String(repeating: "0", count: AppConfig.otpLength),
                keyboard: .numberPad,
                contentType: .oneTimeCode,
                accessibilityHint: L10n.plural(
                    "account.email.code.hint",
                    AppConfig.otpLength,
                    address
                )
            )
            .slContentDirection(.leftToRight)

            if let error = viewModel.emailError {
                errorBox(error)
            }

            SLButton(
                L10n.t("account.email.confirm"),
                variant: .primary,
                isLoading: viewModel.isWorkingOnEmail,
                isEnabled: viewModel.canConfirmEmailChange,
                accessibilityHint: L10n.t("account.email.confirm.hint", address),
                asyncAction: { await viewModel.confirmEmailChange() }
            )

            SLButton(
                L10n.t("account.email.useDifferent"),
                variant: .ghost,
                size: .compact,
                accessibilityHint: L10n.t("account.email.useDifferent.hint"),
                action: { viewModel.resetEmailChange() }
            )
        }
    }

    private func confirmed(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: "envelope.badge.shield.half.filled",
                title: L10n.t("account.email.done.title"),
                subtitle: L10n.t("account.email.done.subtitle", address),
                tint: SLColor.secondary
            )
            SLButton(
                L10n.t("common.done"),
                variant: .primary,
                accessibilityHint: L10n.t("account.email.done.hint"),
                action: {
                    viewModel.resetEmailChange()
                    viewModel.presentedSheet = nil
                }
            )
        }
    }
}

// MARK: - Phone

/// `PUT /me/phone`.
///
/// The whole screen is built to stop a number here from being read as a
/// credential. It is labelled a contact detail, the caption says outright that
/// Sila has not checked it, and there is no badge anywhere on it — because on a
/// platform where a tick means an identity was verified, letting an unverified
/// number wear anything that resembles one would cheapen every real badge.
@MainActor
struct PhoneSheet: View {

    @Bindable var viewModel: AccountViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                SLCard {
                    VStack(alignment: .leading, spacing: SLSpacing.xs) {
                        Text(L10n.t("account.phone.notAVerification"))
                            .font(SLFont.micro)
                            .tracking(0.8)
                            .foregroundStyle(SLColor.warning)
                        Text(PhoneNumber.unverifiedCaption)
                            .font(SLFont.body)
                            .foregroundStyle(SLColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.t("account.phone.badgeNote"))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                if let current = viewModel.displayPhone {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("account.phone.onFile"))
                            .font(SLFont.micro)
                            .tracking(0.8)
                            .foregroundStyle(SLColor.textSecondary)
                        // `+966 501 234 567` is one left-to-right run. Mirrored,
                        // the `+` lands at the end and the groups read backwards.
                        Text(current)
                            .font(SLFont.mono)
                            .foregroundStyle(SLColor.textPrimary)
                            .slContentDirection(.leftToRight)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(L10n.t("account.phone.onFile.a11y", current)))
                }

                SLTextField(
                    L10n.t("account.field.currentPassword.label"),
                    text: $viewModel.phonePassword,
                    placeholder: L10n.t("account.field.currentPassword.placeholder"),
                    isSecure: true,
                    contentType: .password,
                    accessibilityHint: L10n.t("account.phone.password.hint")
                )

                SLTextField(
                    L10n.t("account.phone.field.label"),
                    text: $viewModel.phoneDraft,
                    placeholder: "+966501234567",
                    keyboard: .phonePad,
                    contentType: .telephoneNumber,
                    error: viewModel.phoneError,
                    accessibilityHint: L10n.t("account.phone.field.hint")
                )
                .slContentDirection(.leftToRight)

                SLButton(
                    L10n.t("account.phone.save"),
                    variant: .primary,
                    isLoading: viewModel.isSavingPhone,
                    isEnabled: viewModel.canSavePhone,
                    accessibilityHint: L10n.t("account.phone.save.hint"),
                    asyncAction: { await viewModel.savePhone() }
                )

                if viewModel.hasPhone {
                    SLButton(
                        L10n.t("account.phone.remove"),
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !viewModel.phonePassword.isEmpty && !viewModel.isSavingPhone,
                        accessibilityHint: L10n.t("account.phone.remove.hint"),
                        asyncAction: { await viewModel.removePhone() }
                    )
                }
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: AccountSheet.phone.title)
        .toolbar { closeButton(viewModel) }
    }
}

// MARK: - Deletion

/// `POST /me/delete`.
///
/// Everything that is about to happen is on screen before the button can be
/// pressed, and the button cannot be pressed until two separate deliberate acts
/// have happened: the password is typed, and the word `DELETE` is typed exactly.
/// Neither is theatre — the first is what the server checks, and the second is
/// what stops a mis-tap from ending an account.
@MainActor
struct DeleteAccountSheet: View {

    @Bindable var viewModel: AccountViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                consequences

                Text(DeletionDisclosure.permanent)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(DeletionDisclosure.exportFirst)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.warning)
                    .fixedSize(horizontal: false, vertical: true)

                SLTextField(
                    L10n.t("account.field.currentPassword.label"),
                    text: $viewModel.deletion.currentPassword,
                    placeholder: L10n.t("account.field.currentPassword.placeholder"),
                    isSecure: true,
                    contentType: .password,
                    accessibilityHint: L10n.t("account.delete.password.hint")
                )

                SLTextField(
                    L10n.t("account.delete.typeWord.label", DeletionConfirmation.requiredWord),
                    text: $viewModel.deletion.typedWord,
                    placeholder: DeletionConfirmation.requiredWord,
                    // Deliberately **not** `.characters`. Auto-capitalising would
                    // turn a distracted "delete" into a valid confirmation, and
                    // the whole reason this field exists is that typing the word
                    // has to be a deliberate act rather than a reflex.
                    autocapitalization: .never,
                    accessibilityHint: L10n.t(
                        "account.delete.typeWord.hint",
                        DeletionConfirmation.requiredWord
                    )
                )

                if let reason = viewModel.deletionBlockingReason {
                    Text(reason)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(L10n.t("account.delete.notReady.a11y", reason)))
                }

                if let error = viewModel.deletionError {
                    errorBox(error)
                }

                SLButton(
                    L10n.t("account.delete.confirmButton"),
                    variant: .destructive,
                    isLoading: viewModel.isDeleting,
                    isEnabled: viewModel.canConfirmDeletion,
                    accessibilityHint: L10n.plural(
                        "account.delete.confirmButton.hint",
                        DeletionDisclosure.graceDays
                    ),
                    asyncAction: { await viewModel.requestDeletion() }
                )

                SLButton(
                    L10n.t("account.delete.keepButton"),
                    variant: .ghost,
                    accessibilityHint: L10n.t("account.delete.keepButton.hint"),
                    action: { viewModel.presentedSheet = nil }
                )
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: AccountSheet.delete.title)
        .toolbar { closeButton(viewModel) }
    }

    private var consequences: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            Text(L10n.t("account.delete.consequences.header"))
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(DeletionDisclosure.consequences.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: SLSpacing.sm) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(SLColor.danger)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.lg)
                .strokeBorder(SLColor.danger.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Recovery

/// The screen a deactivated account lands on, and the only one it can use.
///
/// It exists because `403 account_deactivated` is a *state*, not a failure. The
/// credentials are good and the server is fine; the person is inside the window
/// that was put there so a deletion made in anger, by mistake, or with somebody
/// standing over them can be taken back. Showing them an error alert with a
/// Retry button would loop them through the same 403 until the purge ran, and
/// the one action that helps would never appear.
@MainActor
struct AccountRecoveryScreen: View {

    @Bindable var viewModel: AccountViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.xl) {
                header
                whatIsHappening
                cancelAction
                signOut
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        // Harmless when ``AccountScreen`` already loaded, and what makes this
        // screen work when it is presented on its own.
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            SLBadge(L10n.t("account.recovery.badge"), style: .danger, icon: "clock.badge.exclamationmark")

            Text(L10n.t("account.recovery.title"))
                .font(SLFont.displayM)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(countdown)
                .font(SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// How long is left, said in days rather than as a timestamp.
    ///
    /// A date alone makes somebody do the arithmetic under stress; the number of
    /// days is the thing they are actually asking.
    private var countdown: String {
        guard let days = viewModel.daysUntilPurge() else {
            return L10n.t("account.recovery.countdown.unknown")
        }
        if days <= 0 {
            return L10n.t("account.recovery.countdown.today")
        }
        return L10n.plural("account.recovery.countdown.days", days)
    }

    private var whatIsHappening: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            Text(L10n.t("account.recovery.currentState.header"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(Self.currentState.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: SLSpacing.sm) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(SLColor.textMuted)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.lg)
                .strokeBorder(SLColor.stroke, lineWidth: 1)
        )
    }

    /// The facts about the current state, held here so they are asserted in
    /// tests rather than left to drift.
    static var currentState: [String] {
        [
            L10n.t("account.recovery.currentState.posts"),
            L10n.t("account.recovery.currentState.scope"),
            L10n.t("account.recovery.currentState.reversible")
        ]
    }

    private var cancelAction: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            if let error = viewModel.recoveryError {
                errorBox(error)
            }

            SLButton(
                L10n.t("account.recovery.cancelDeletion"),
                variant: .primary,
                isLoading: viewModel.isCancellingDeletion,
                accessibilityHint: L10n.t("account.recovery.cancelDeletion.hint"),
                asyncAction: { await viewModel.cancelDeletion() }
            )
        }
    }

    private var signOut: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("account.recovery.signOut.note"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            SLButton(
                L10n.t("common.signOut"),
                variant: .ghost,
                size: .compact,
                accessibilityHint: L10n.t("account.recovery.signOut.hint"),
                action: { viewModel.signOut() }
            )
        }
    }
}

// MARK: - Shared bits

/// A destructive-red inline error panel.
@MainActor
func errorBox(_ text: String) -> some View {
    HStack(alignment: .top, spacing: SLSpacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(SLColor.danger)
            .accessibilityHidden(true)
        Text(text)
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(SLSpacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SLColor.danger.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
    .accessibilityElement(children: .combine)
}

/// The Cancel button every credential sheet carries.
@MainActor
func closeButton(_ viewModel: AccountViewModel) -> some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
        Button(L10n.t("common.cancel")) { viewModel.presentedSheet = nil }
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityLabel(Text(L10n.t("common.cancel")))
            .accessibilityHint(Text(L10n.t("account.sheet.cancel.hint")))
    }
}

#Preview("Recovery") {
    AccountRecoveryScreen(
        viewModel: AccountViewModel(
            service: AccountServiceMock(scenario: .pendingDeletion),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}
