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
            Text("Changing your password signs every device out — this one included. "
                 + "That is the point: a password change is what you do when you think "
                 + "a session isn't yours.")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SLTextField(
                "Current password",
                text: $viewModel.passwordCurrent,
                placeholder: "The one you use now",
                isSecure: true,
                contentType: .password,
                accessibilityHint: "Proves this is your account, not just an unlocked phone"
            )

            SLTextField(
                "New password",
                text: $viewModel.passwordNew,
                placeholder: "At least \(AccountLimits.minimumPasswordLength) characters",
                isSecure: true,
                contentType: .newPassword,
                accessibilityHint: "The password you want from now on"
            )

            SLTextField(
                "Repeat new password",
                text: $viewModel.passwordRepeat,
                placeholder: "The same again",
                isSecure: true,
                contentType: .newPassword,
                error: viewModel.passwordValidationError,
                accessibilityHint: "Typed twice so a slip does not lock you out"
            )

            if let error = viewModel.passwordError {
                errorBox(error)
            }

            SLButton(
                "Change password",
                variant: .primary,
                isLoading: viewModel.isChangingPassword,
                isEnabled: viewModel.canChangePassword,
                accessibilityHint: "Replaces your password and signs every device out",
                asyncAction: { await viewModel.changePassword() }
            )
        }
    }

    private var changed: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: "checkmark.shield.fill",
                title: "Password changed",
                subtitle: viewModel.passwordChangeOutcome,
                tint: SLColor.secondary
            )

            SLButton(
                "Sign out now",
                variant: .secondary,
                accessibilityHint: "Ends this session so you can sign in with the new password",
                action: {
                    viewModel.presentedSheet = nil
                    viewModel.signOut()
                }
            )

            SLButton(
                "Stay signed in for now",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Closes this sheet without ending the session",
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
            Text("You sign in with \(viewModel.account?.email ?? "this address"). "
                 + "Sila will email a six-digit code to the **new** address — not to this "
                 + "one — because the only thing worth proving here is that you can read "
                 + "the mailbox you are moving to.")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SLTextField(
                "Current password",
                text: $viewModel.emailPassword,
                placeholder: "Your password",
                isSecure: true,
                contentType: .password,
                accessibilityHint: "Required: an unlocked phone must not be enough to move an account"
            )

            SLTextField(
                "New email",
                text: $viewModel.emailNew,
                placeholder: "you@newaddress.com",
                keyboard: .emailAddress,
                contentType: .emailAddress,
                accessibilityHint: "The address the confirmation code will be sent to"
            )

            if let error = viewModel.emailError {
                errorBox(error)
            }

            SLButton(
                "Send code to the new address",
                variant: .primary,
                isLoading: viewModel.isWorkingOnEmail,
                isEnabled: viewModel.canRequestEmailChange,
                accessibilityHint: "Emails a six-digit code to the address you typed above",
                asyncAction: { await viewModel.requestEmailChange() }
            )
        }
    }

    private func code(sentTo address: String) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLCard {
                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    Text("CODE SENT TO")
                        .font(SLFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(SLColor.textSecondary)
                    Text(address)
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textPrimary)
                    Text("Not to your current address. Your email does not change until "
                         + "the code is accepted, so you can still sign in with the old one.")
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            SLTextField(
                "Code",
                text: $viewModel.emailCode,
                placeholder: String(repeating: "0", count: AppConfig.otpLength),
                keyboard: .numberPad,
                contentType: .oneTimeCode,
                accessibilityHint: "The \(AppConfig.otpLength) digits emailed to \(address)"
            )

            if let error = viewModel.emailError {
                errorBox(error)
            }

            SLButton(
                "Confirm new email",
                variant: .primary,
                isLoading: viewModel.isWorkingOnEmail,
                isEnabled: viewModel.canConfirmEmailChange,
                accessibilityHint: "Moves your account to \(address)",
                asyncAction: { await viewModel.confirmEmailChange() }
            )

            SLButton(
                "Use a different address",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Discards this code and starts again",
                action: { viewModel.resetEmailChange() }
            )
        }
    }

    private func confirmed(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: "envelope.badge.shield.half.filled",
                title: "Email changed",
                subtitle: "You now sign in with \(address). Your old address no longer works.",
                tint: SLColor.secondary
            )
            SLButton(
                "Done",
                variant: .primary,
                accessibilityHint: "Closes this sheet",
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
                        Text("NOT A VERIFICATION")
                            .font(SLFont.micro)
                            .tracking(0.8)
                            .foregroundStyle(SLColor.warning)
                        Text(PhoneNumber.unverifiedCaption)
                            .font(SLFont.body)
                            .foregroundStyle(SLColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Your country flag and your verified badge come from identity "
                             + "verification, and a phone number cannot change either of them.")
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                if let current = viewModel.displayPhone {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ON FILE")
                            .font(SLFont.micro)
                            .tracking(0.8)
                            .foregroundStyle(SLColor.textSecondary)
                        Text(current)
                            .font(SLFont.mono)
                            .foregroundStyle(SLColor.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Number on file, unverified: \(current)"))
                }

                SLTextField(
                    "Current password",
                    text: $viewModel.phonePassword,
                    placeholder: "Your password",
                    isSecure: true,
                    contentType: .password,
                    accessibilityHint: "Required for any change to your account details"
                )

                SLTextField(
                    "Phone number",
                    text: $viewModel.phoneDraft,
                    placeholder: "+966501234567",
                    keyboard: .phonePad,
                    contentType: .telephoneNumber,
                    error: viewModel.phoneError,
                    accessibilityHint: "International format, starting with a plus and a country code"
                )

                SLButton(
                    "Save number",
                    variant: .primary,
                    isLoading: viewModel.isSavingPhone,
                    isEnabled: viewModel.canSavePhone,
                    accessibilityHint: "Stores this number as a contact detail. It is not verified.",
                    asyncAction: { await viewModel.savePhone() }
                )

                if viewModel.hasPhone {
                    SLButton(
                        "Remove the number on file",
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !viewModel.phonePassword.isEmpty && !viewModel.isSavingPhone,
                        accessibilityHint: "Deletes your contact number. Also needs your password.",
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
                    "Current password",
                    text: $viewModel.deletion.currentPassword,
                    placeholder: "Your password",
                    isSecure: true,
                    contentType: .password,
                    accessibilityHint: "Proves this is your account before anything is deleted"
                )

                SLTextField(
                    "Type \(DeletionConfirmation.requiredWord)",
                    text: $viewModel.deletion.typedWord,
                    placeholder: DeletionConfirmation.requiredWord,
                    // Deliberately **not** `.characters`. Auto-capitalising would
                    // turn a distracted "delete" into a valid confirmation, and
                    // the whole reason this field exists is that typing the word
                    // has to be a deliberate act rather than a reflex.
                    autocapitalization: .never,
                    accessibilityHint: "Type the word \(DeletionConfirmation.requiredWord) in "
                        + "capital letters, exactly, to confirm"
                )

                if let reason = viewModel.deletionBlockingReason {
                    Text(reason)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("Not ready yet. \(reason)"))
                }

                if let error = viewModel.deletionError {
                    errorBox(error)
                }

                SLButton(
                    "Delete my account",
                    variant: .destructive,
                    isLoading: viewModel.isDeleting,
                    isEnabled: viewModel.canConfirmDeletion,
                    accessibilityHint: "Deactivates your account now and schedules it for "
                        + "deletion in \(DeletionDisclosure.graceDays) days",
                    asyncAction: { await viewModel.requestDeletion() }
                )

                SLButton(
                    "Keep my account",
                    variant: .ghost,
                    accessibilityHint: "Closes this without deleting anything",
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
            Text("What happens when you confirm")
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
            SLBadge("Scheduled for deletion", style: .danger, icon: "clock.badge.exclamationmark")

            Text("This account is being deleted")
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
            return "Everything is still here, and cancelling below brings it all back."
        }
        if days <= 0 {
            return "The deletion runs today. Cancelling now still works, but not for much longer."
        }
        return "Everything is still here for another \(days) day\(days == 1 ? "" : "s"). "
            + "Cancel below and your posts, follows and settings come back exactly as they were."
    }

    private var whatIsHappening: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            Text("Right now")
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
    static let currentState = [
        "Your posts are hidden from every feed, search result and thread, and your "
            + "profile does not resolve.",
        "Nothing else on Sila works while this is pending — that is why this is the "
            + "only screen you can reach.",
        "Nothing has been destroyed. Cancelling restores all of it."
    ]

    private var cancelAction: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            if let error = viewModel.recoveryError {
                errorBox(error)
            }

            SLButton(
                "Cancel deletion",
                variant: .primary,
                isLoading: viewModel.isCancellingDeletion,
                accessibilityHint: "Restores your account, your posts and your settings immediately",
                asyncAction: { await viewModel.cancelDeletion() }
            )
        }
    }

    private var signOut: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text("If you meant to leave, there is nothing more to do. The deletion "
                 + "finishes on its own.")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            SLButton(
                "Sign out",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Leaves the app. The deletion stays scheduled.",
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
        Button("Cancel") { viewModel.presentedSheet = nil }
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityLabel(Text("Cancel"))
            .accessibilityHint(Text("Closes this form without changing anything"))
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
