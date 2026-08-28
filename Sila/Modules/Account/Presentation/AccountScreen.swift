import PhotosUI
import SwiftUI

/// Account settings: who you are, how you sign in, and how you leave.
///
/// The screen is organised around one idea — **a session is not consent.**
/// Nothing here that changes a credential, or takes the account away, happens
/// from a tap. Each of those lives behind its own sheet and each sheet asks for
/// the current password, because the alternative is that an unattended unlocked
/// phone is enough to take somebody's account over by swapping its email.
///
/// Two smaller rules follow from the product rather than from the endpoints:
///
/// * **The phone number is never drawn as verified.** No tick, no green, no
///   "confirmed". There is no SMS provider behind it, and on a platform whose
///   whole proposition is proven identity, a number somebody typed in must not
///   be allowed to resemble the badge that means a government checked.
/// * **What the server does to a picture is stated, not hidden.** Every upload
///   is re-encoded and its EXIF dropped, which is the difference between
///   "set a photo" and "publish the coordinates it was taken at".
@MainActor
public struct AccountScreen: View {

    @Bindable private var viewModel: AccountViewModel
    private let onClose: (@MainActor () -> Void)?

    @State private var pickedPhoto: PhotosPickerItem?

    /// - Parameters:
    ///   - viewModel: Owns the account, the drafts and the routing.
    ///   - onClose: Dismisses the screen. `nil` hides the Done button.
    public init(viewModel: AccountViewModel, onClose: (@MainActor () -> Void)? = nil) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: viewModel.route == .recovery ? "Account deletion" : "Account")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Present on the recovery screen too. Trapping somebody
                        // in a sheet would be its own kind of dead end, and
                        // leaving is not the same as giving up the cancel —
                        // reopening Account brings them straight back here.
                        Button("Done") { onClose() }
                            .foregroundStyle(SLColor.primary)
                            .accessibilityLabel(Text("Done"))
                            .accessibilityHint(Text("Closes account settings"))
                    }
                }
            }
            .task { await viewModel.load() }
            .tnToast($viewModel.toast)
            .sheet(item: $viewModel.presentedSheet, onDismiss: dismissedSheet) { sheet in
                NavigationStack {
                    sheetContent(sheet)
                }
                .tint(SLColor.primary)
                .presentationDetents([.large])
            }
    }

    private func dismissedSheet() {
        // `item` is already nil by the time this runs, so the sheet that closed
        // is inferred from what still holds state. Clearing every form is the
        // safe reading: none of them should outlive their sheet.
        for sheet in [AccountSheet.password, .email, .phone, .delete] {
            viewModel.sheetDismissed(sheet)
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var content: some View {
        switch viewModel.route {
        case .recovery:
            AccountRecoveryScreen(viewModel: viewModel)
        case .settings:
            settings
        }
    }

    @ViewBuilder
    private var settings: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            loadingState
        } else if let error = viewModel.loadError, !viewModel.hasLoaded {
            ScrollView {
                SLEmptyState(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load your account",
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: "Try again",
                    action: { Task { await viewModel.reload() } }
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl * 2)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.xl) {
                    identityCard
                    pictureSection
                    profileSection
                    contactSection
                    securitySection
                    dataSection
                    dangerSection
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.lg)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var loadingState: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SLSkeletonRow(lineCount: 2).padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Loading your account"))
    }

    // MARK: - Identity

    private var identityCard: some View {
        SLCard {
            HStack(spacing: SLSpacing.lg) {
                SLAvatar(
                    url: viewModel.account?.avatarURL,
                    initials: viewModel.account?.initials ?? "··",
                    size: .lg,
                    isVerified: viewModel.account?.verificationStatus == .verified,
                    displayName: viewModel.account?.displayName ?? viewModel.account?.email
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SLSpacing.sm) {
                        Text(viewModel.account?.displayName ?? "No name set")
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)

                        // The one badge on this screen, and it comes from
                        // identity verification. Nothing else here borrows it.
                        SLCountryBadge(countryCode: viewModel.account?.countryCode)
                    }

                    if let handle = viewModel.account?.atHandle {
                        Text(handle)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                    }

                    Text(viewModel.account?.email ?? "")
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Picture

    private var pictureSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader("PROFILE PICTURE")

            // Stated up front, not tucked under a chevron: one of these facts is
            // that a photo carries where it was taken, and nobody reads
            // "set a photo" as a decision about their location history.
            Text(AvatarUpload.processingDisclosure)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.avatarError {
                inlineError(error)
            }

            HStack(spacing: SLSpacing.md) {
                PhotosPicker(
                    selection: $pickedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Text(viewModel.account?.avatarPath == nil ? "Choose photo" : "Replace photo")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(SLColor.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: SLRadius.md)
                                .strokeBorder(SLColor.primary.opacity(0.45), lineWidth: 1)
                        )
                }
                .disabled(viewModel.isWorkingOnAvatar)
                .opacity(viewModel.isWorkingOnAvatar ? 0.45 : 1)
                .accessibilityLabel(Text("Choose a profile picture"))
                .accessibilityHint(Text(
                    "Opens your photo library. Images over 5 megabytes are refused before uploading."
                ))

                if viewModel.account?.avatarPath != nil {
                    SLButton(
                        "Remove",
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !viewModel.isWorkingOnAvatar,
                        accessibilityHint: "Deletes your profile picture from Sila",
                        asyncAction: { await viewModel.removeAvatar() }
                    )
                    .frame(width: 100)
                }
            }

            if viewModel.isWorkingOnAvatar {
                Text("Uploading…")
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                // An empty `Data` is deliberate: it routes into the same
                // client-side refusal as an unreadable file, so a picker that
                // hands back nothing produces a sentence rather than silence.
                let data = (try? await item.loadTransferable(type: Data.self)) ?? Data()
                await viewModel.setAvatar(data: data)
                pickedPhoto = nil
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader("PROFILE")

            SLTextField(
                "Display name",
                text: $viewModel.profileDraft.displayName,
                placeholder: "The name people see",
                autocapitalization: .words,
                accessibilityHint: "The name shown beside your posts"
            )

            SLTextField(
                "Handle",
                text: $viewModel.profileDraft.handle,
                placeholder: "aziz_sa",
                accessibilityHint: "Three to twenty characters of lowercase letters, numbers and underscores"
            )

            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                SLTextField(
                    "Bio",
                    text: $viewModel.profileDraft.bio,
                    placeholder: "A line or two about you",
                    autocapitalization: .sentences,
                    accessibilityHint: "Up to \(AccountLimits.maximumBioLength) characters shown on your profile"
                )

                Text("\(viewModel.bioRemaining) characters left")
                    .font(SLFont.micro)
                    .foregroundStyle(viewModel.bioRemaining < 0 ? SLColor.danger : SLColor.textMuted)
                    .accessibilityLabel(Text("\(viewModel.bioRemaining) characters left in your bio"))
            }

            if let error = viewModel.profileValidationError ?? viewModel.profileError {
                inlineError(error)
            }

            HStack(spacing: SLSpacing.md) {
                Text(viewModel.hasProfileChanges ? "Unsaved changes" : "Everything here is saved")
                    .font(SLFont.caption)
                    .foregroundStyle(
                        viewModel.hasProfileChanges ? SLColor.warning : SLColor.textSecondary
                    )

                Spacer(minLength: 0)

                if viewModel.hasProfileChanges {
                    SLButton(
                        "Discard",
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !viewModel.isSavingProfile,
                        accessibilityHint: "Restores the profile Sila has stored",
                        action: { viewModel.discardProfileChanges() }
                    )
                    .frame(width: 92)
                }

                SLButton(
                    "Save",
                    variant: .primary,
                    size: .compact,
                    isLoading: viewModel.isSavingProfile,
                    isEnabled: viewModel.canSaveProfile,
                    accessibilityHint: "Sends your name, handle and bio to Sila",
                    asyncAction: { await viewModel.saveProfile() }
                )
                .frame(width: 104)
            }
        }
    }

    // MARK: - Contact

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader("CONTACT")

            settingsRow(
                icon: "envelope",
                title: "Email",
                value: viewModel.account?.email ?? "—",
                detail: "The address you sign in with. Changing it needs your password "
                    + "and a code sent to the new address.",
                actionLabel: "Change",
                hint: "Opens the two-step email change"
            ) {
                viewModel.presentedSheet = .email
            }

            phoneRow
        }
    }

    /// The contact number.
    ///
    /// Deliberately has no badge, no tick and no colour. `phone_verified` is not
    /// even decoded — see ``Account`` — so there is nothing here a checkmark
    /// could be bound to by accident. The caption says what the number is and,
    /// just as importantly, what it is not.
    private var phoneRow: some View {
        settingsRow(
            icon: "phone",
            title: "Phone number",
            value: viewModel.displayPhone ?? "Not set",
            detail: PhoneNumber.unverifiedCaption,
            actionLabel: viewModel.hasPhone ? "Change" : "Add",
            hint: "Opens the contact number form, which needs your password"
        ) {
            viewModel.phoneDraft = viewModel.account?.phone ?? ""
            viewModel.presentedSheet = .phone
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader("SECURITY")

            settingsRow(
                icon: "lock",
                title: "Password",
                value: "••••••••",
                detail: "Changing it signs every device out, including this one.",
                actionLabel: "Change",
                hint: "Opens the password change form"
            ) {
                viewModel.presentedSheet = .password
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader("YOUR DATA")

            SLCard {
                VStack(alignment: .leading, spacing: SLSpacing.sm) {
                    Text("Download everything")
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)

                    Text("Your account, every post you have written, your topic settings "
                         + "and who you follow, as a JSON file. Automatic topic labels are "
                         + "left out and the file says so: they are guesses Sila made about "
                         + "your posts, not anything you wrote.")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = viewModel.exportError {
                        inlineError(error)
                    }

                    HStack(spacing: SLSpacing.md) {
                        SLButton(
                            viewModel.exportFile == nil ? "Download" : "Download again",
                            variant: .secondary,
                            size: .compact,
                            isLoading: viewModel.isExporting,
                            accessibilityHint: "Fetches a copy of everything Sila holds about you",
                            asyncAction: { await viewModel.exportAccount() }
                        )

                        if let file = viewModel.exportFile {
                            ShareLink(item: file) {
                                Text("Save or share")
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.primary)
                                    .frame(height: 40)
                            }
                            .accessibilityLabel(Text("Save or share your data export"))
                            .accessibilityHint(Text("Opens the share sheet with the downloaded file"))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Deletion

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader("DELETE ACCOUNT")

            SLCard {
                VStack(alignment: .leading, spacing: SLSpacing.sm) {
                    Text(DeletionDisclosure.immediate)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(DeletionDisclosure.recoverable)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SLButton(
                        "Delete account…",
                        variant: .destructive,
                        size: .compact,
                        accessibilityHint: "Opens the deletion form, which explains what happens "
                            + "and asks for your password",
                        action: { viewModel.presentedSheet = .delete }
                    )
                    .padding(.top, SLSpacing.xs)
                }
            }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: AccountSheet) -> some View {
        switch sheet {
        case .password:
            PasswordChangeSheet(viewModel: viewModel)
        case .email:
            EmailChangeSheet(viewModel: viewModel)
        case .phone:
            PhoneSheet(viewModel: viewModel)
        case .delete:
            DeleteAccountSheet(viewModel: viewModel)
        }
    }

    // MARK: - Building blocks

    private func settingsRow(
        icon: String,
        title: String,
        value: String,
        detail: String,
        actionLabel: String,
        hint: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack(spacing: SLSpacing.md) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SLColor.primary)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(SLFont.micro)
                            .tracking(0.6)
                            .foregroundStyle(SLColor.textSecondary)
                        Text(value)
                            .font(SLFont.body)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    Spacer(minLength: 0)

                    SLButton(
                        actionLabel,
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: hint,
                        action: action
                    )
                    .frame(width: 92)
                }

                Text(detail)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlineError(_ text: String) -> some View {
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

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(SLFont.micro)
            .tracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Account — populated") {
    NavigationStack {
        AccountScreen(
            viewModel: AccountViewModel(
                service: AccountServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Account — new account") {
    NavigationStack {
        AccountScreen(
            viewModel: AccountViewModel(
                service: AccountServiceMock(scenario: .fresh),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Account — pending deletion") {
    NavigationStack {
        AccountScreen(
            viewModel: AccountViewModel(
                service: AccountServiceMock(scenario: .pendingDeletion),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}
