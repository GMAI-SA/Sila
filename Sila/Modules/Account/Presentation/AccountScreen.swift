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
            .tnNavigationBar(
                title: viewModel.route == .recovery
                    ? L10n.t("account.nav.deletionTitle")
                    : L10n.t("account.nav.title")
            )
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Present on the recovery screen too. Trapping somebody
                        // in a sheet would be its own kind of dead end, and
                        // leaving is not the same as giving up the cancel —
                        // reopening Account brings them straight back here.
                        Button(L10n.t("common.done")) { onClose() }
                            .foregroundStyle(SLColor.primary)
                            .accessibilityLabel(Text(L10n.t("common.done")))
                            .accessibilityHint(Text(L10n.t("account.done.hint")))
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
                    title: L10n.t("account.load.error.title"),
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: L10n.t("account.load.retry"),
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
        .accessibilityLabel(Text(L10n.t("account.loading.a11y")))
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
                        // A display name is the user's own text: an English name
                        // inside an Arabic interface still reads left to right,
                        // and the fallback sentence follows the interface.
                        Text(viewModel.account?.displayName ?? L10n.t("account.identity.noName"))
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .slContentDirection(
                                TextDirection.resolve(
                                    languageCode: nil,
                                    text: viewModel.account?.displayName
                                )
                            )

                        // The one badge on this screen, and it comes from
                        // identity verification. Nothing else here borrows it.
                        SLCountryBadge(countryCode: viewModel.account?.countryCode)
                    }

                    if let handle = viewModel.account?.atHandle {
                        // `@aziz_sa` is a Latin token. Laid out right-to-left the
                        // `@` jumps to the wrong end of it.
                        Text(handle)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                            .slContentDirection(.leftToRight)
                    }

                    Text(viewModel.account?.email ?? "")
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .slContentDirection(.leftToRight)
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Picture

    private var pictureSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("account.section.picture"))

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
                    Text(L10n.t(
                        viewModel.account?.avatarPath == nil
                            ? "account.picture.choose"
                            : "account.picture.replace"
                    ))
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
                .accessibilityLabel(Text(L10n.t("account.picture.choose.a11yLabel")))
                .accessibilityHint(Text(L10n.plural(
                    "account.picture.choose.a11yHint",
                    AvatarUpload.maximumBytes / (1024 * 1024)
                )))

                if viewModel.account?.avatarPath != nil {
                    SLButton(
                        L10n.t("account.picture.remove"),
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !viewModel.isWorkingOnAvatar,
                        accessibilityHint: L10n.t("account.picture.remove.hint"),
                        asyncAction: { await viewModel.removeAvatar() }
                    )
                    .frame(width: 100)
                }
            }

            if viewModel.isWorkingOnAvatar {
                Text(L10n.t("account.picture.uploading"))
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
            sectionHeader(L10n.t("account.section.profile"))

            // The name and the bio are the user's own writing, so both fields
            // follow what is being typed into them rather than the interface.
            SLTextField(
                L10n.t("account.profile.displayName.label"),
                text: $viewModel.profileDraft.displayName,
                placeholder: L10n.t("account.profile.displayName.placeholder"),
                autocapitalization: .words,
                accessibilityHint: L10n.t("account.profile.displayName.hint")
            )
            .slContentDirection(
                TextDirection.resolve(languageCode: nil, text: viewModel.profileDraft.displayName)
            )

            // A handle is `[a-z0-9_]`. It is typed and read left-to-right in
            // every interface language; the example is not translated copy.
            SLTextField(
                L10n.t("account.profile.handle.label"),
                text: $viewModel.profileDraft.handle,
                placeholder: "aziz_sa",
                accessibilityHint: L10n.t("account.profile.handle.hint")
            )
            .slContentDirection(.leftToRight)

            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                SLTextField(
                    L10n.t("account.profile.bio.label"),
                    text: $viewModel.profileDraft.bio,
                    placeholder: L10n.t("account.profile.bio.placeholder"),
                    autocapitalization: .sentences,
                    accessibilityHint: L10n.plural(
                        "account.profile.bio.hint",
                        AccountLimits.maximumBioLength
                    )
                )
                .slContentDirection(
                    TextDirection.resolve(languageCode: nil, text: viewModel.profileDraft.bio)
                )

                Text(L10n.plural("account.profile.bio.remaining", viewModel.bioRemaining))
                    .font(SLFont.micro)
                    .foregroundStyle(viewModel.bioRemaining < 0 ? SLColor.danger : SLColor.textMuted)
                    .accessibilityLabel(Text(L10n.plural(
                        "account.profile.bio.remaining.a11y",
                        viewModel.bioRemaining
                    )))
            }

            if let error = viewModel.profileValidationError ?? viewModel.profileError {
                inlineError(error)
            }

            HStack(spacing: SLSpacing.md) {
                Text(L10n.t(
                    viewModel.hasProfileChanges
                        ? "account.profile.status.unsaved"
                        : "account.profile.status.saved"
                ))
                    .font(SLFont.caption)
                    .foregroundStyle(
                        viewModel.hasProfileChanges ? SLColor.warning : SLColor.textSecondary
                    )

                Spacer(minLength: 0)

                if viewModel.hasProfileChanges {
                    SLButton(
                        L10n.t("account.profile.discard"),
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !viewModel.isSavingProfile,
                        accessibilityHint: L10n.t("account.profile.discard.hint"),
                        action: { viewModel.discardProfileChanges() }
                    )
                    .frame(width: 92)
                }

                SLButton(
                    L10n.t("common.save"),
                    variant: .primary,
                    size: .compact,
                    isLoading: viewModel.isSavingProfile,
                    isEnabled: viewModel.canSaveProfile,
                    accessibilityHint: L10n.t("account.profile.save.hint"),
                    asyncAction: { await viewModel.saveProfile() }
                )
                .frame(width: 104)
            }
        }
    }

    // MARK: - Contact

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("account.section.contact"))

            settingsRow(
                icon: "envelope",
                title: L10n.t("account.email.row.title"),
                value: viewModel.account?.email ?? "—",
                // An address never reverses, whatever the interface is doing.
                valueDirection: .leftToRight,
                detail: L10n.t("account.email.row.detail"),
                actionLabel: L10n.t("account.email.row.action"),
                hint: L10n.t("account.email.row.hint")
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
            title: L10n.t("account.phone.row.title"),
            value: viewModel.displayPhone ?? L10n.t("account.phone.row.empty"),
            // An E.164 number is a run of digits behind a `+`. Rendered
            // right-to-left the plus lands after the number and the grouping
            // reads backwards, so a stored number is pinned; the "Not set"
            // sentence is interface copy and follows the interface.
            valueDirection: viewModel.displayPhone == nil
                ? (L10n.isRightToLeft ? .rightToLeft : .leftToRight)
                : .leftToRight,
            detail: PhoneNumber.unverifiedCaption,
            actionLabel: L10n.t(
                viewModel.hasPhone ? "account.phone.row.change" : "account.phone.row.add"
            ),
            hint: L10n.t("account.phone.row.hint")
        ) {
            viewModel.phoneDraft = viewModel.account?.phone ?? ""
            viewModel.presentedSheet = .phone
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("account.section.security"))

            settingsRow(
                icon: "lock",
                title: L10n.t("account.password.row.title"),
                value: "••••••••",
                detail: L10n.t("account.password.row.detail"),
                actionLabel: L10n.t("account.password.row.action"),
                hint: L10n.t("account.password.row.hint")
            ) {
                viewModel.presentedSheet = .password
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("account.section.data"))

            SLCard {
                VStack(alignment: .leading, spacing: SLSpacing.sm) {
                    Text(L10n.t("account.export.title"))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)

                    Text(L10n.t("account.export.detail"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = viewModel.exportError {
                        inlineError(error)
                    }

                    HStack(spacing: SLSpacing.md) {
                        SLButton(
                            L10n.t(
                                viewModel.exportFile == nil
                                    ? "account.export.download"
                                    : "account.export.downloadAgain"
                            ),
                            variant: .secondary,
                            size: .compact,
                            isLoading: viewModel.isExporting,
                            accessibilityHint: L10n.t("account.export.download.hint"),
                            asyncAction: { await viewModel.exportAccount() }
                        )

                        if let file = viewModel.exportFile {
                            ShareLink(item: file) {
                                Text(L10n.t("account.export.share"))
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.primary)
                                    .frame(height: 40)
                            }
                            .accessibilityLabel(Text(L10n.t("account.export.share.a11yLabel")))
                            .accessibilityHint(Text(L10n.t("account.export.share.hint")))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Deletion

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("account.section.delete"))

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
                        L10n.t("account.delete.open"),
                        variant: .destructive,
                        size: .compact,
                        accessibilityHint: L10n.t("account.delete.open.hint"),
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

    /// One settings row: an icon, a label, the value, and the control that
    /// changes it.
    ///
    /// - Parameter valueDirection: Which way the *value* reads. The label, the
    ///   caption and the button follow the interface; an email address or an
    ///   E.164 number does not, and pinning it here is the whole reason this is
    ///   a parameter rather than an assumption.
    private func settingsRow(
        icon: String,
        title: String,
        value: String,
        valueDirection: TextDirection? = nil,
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
                            .slContentDirection(
                                valueDirection
                                    ?? (L10n.isRightToLeft ? .rightToLeft : .leftToRight)
                            )
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
