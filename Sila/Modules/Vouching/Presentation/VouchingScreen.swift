import SwiftUI

/// "Vouch for someone you know" — the voucher's own list (contract v24 §5).
///
/// From the top: whether they may vouch now and why not; the claims waiting
/// for "that's who I meant" inside their 48 hours; a moderator's question,
/// when there is one; open links; live vouches; and the ones that ended.
/// What the voucher wrote about each person shows here and nowhere else —
/// it is theirs.
@MainActor
public struct VouchingScreen: View {

    @Bindable private var viewModel: VouchingViewModel
    private let onOpenProfile: (@MainActor (String) -> Void)?
    private let onCreateLink: (@MainActor () -> Void)?

    public init(
        viewModel: VouchingViewModel,
        onOpenProfile: (@MainActor (String) -> Void)? = nil,
        onCreateLink: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenProfile = onOpenProfile
        self.onCreateLink = onCreateLink
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("vouch.list.nav"))
            .tnToast($viewModel.toast)
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().tint(SLColor.primary)
        case let .failed(message):
            SLEmptyState(
                icon: "wifi.exclamationmark",
                title: L10n.t("vouch.list.error.title"),
                subtitle: message,
                tint: SLColor.danger,
                actionTitle: L10n.t("profile.action.tryAgain"),
                action: { Task { await viewModel.load() } }
            )
            .padding(SLSpacing.lg)
        case .loaded:
            if viewModel.isOpen, let overview = viewModel.overview {
                list(overview)
            } else {
                SLEmptyState(
                    icon: SLVouchTag.glyph,
                    title: L10n.t("vouch.list.notOpen.title"),
                    subtitle: L10n.t("vouch.list.notOpen.message"),
                    tint: SLColor.textSecondary
                )
                .padding(SLSpacing.lg)
                .accessibilityIdentifier("vouching.list.notOpen")
            }
        }
    }

    private func list(_ overview: VouchingOverview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SLSpacing.lg) {
                header(overview)

                if !overview.pending.isEmpty {
                    section(L10n.t("vouch.list.pending.header")) {
                        ForEach(overview.pending) { vouch in pendingRow(vouch, overview: overview) }
                    }
                }

                let summoned = (overview.vouches + overview.ended).filter(\.awaitsAnswer)
                if !summoned.isEmpty {
                    section(L10n.t("vouch.summons.header")) {
                        ForEach(summoned) { vouch in summonsRow(vouch) }
                    }
                }

                if !overview.invites.isEmpty {
                    section(L10n.t("vouch.list.invites.header")) {
                        ForEach(overview.invites) { invite in inviteRow(invite) }
                    }
                }

                if !overview.active.isEmpty {
                    section(L10n.t("vouch.list.active.header")) {
                        ForEach(overview.active) { vouch in activeRow(vouch) }
                    }
                }

                if !overview.ended.isEmpty {
                    section(L10n.t("vouch.list.ended.header")) {
                        ForEach(overview.ended) { vouch in endedRow(vouch) }
                    }
                }

                if viewModel.isEmpty {
                    SLEmptyState(
                        icon: SLVouchTag.glyph,
                        title: L10n.t("vouch.list.empty.title"),
                        subtitle: L10n.t("vouch.list.empty.message"),
                        tint: SLColor.textSecondary
                    )
                }
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.lg)
        }
        .refreshable { await viewModel.load() }
    }

    // MARK: - Standing

    private func header(_ overview: VouchingOverview) -> some View {
        SLCard(padding: SLSpacing.lg) {
            VStack(alignment: .leading, spacing: SLSpacing.md) {
                Text(L10n.t("vouch.list.intro.title"))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                Text(L10n.t("vouch.list.intro.message", SLFormat.number(overview.rules.vouchDays)))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Slots mean nothing once the right to vouch is gone.
                if overview.slots.total > 0, !viewModel.privilegeLost {
                    Label(L10n.t("vouch.slots", SLFormat.number(overview.slots.used), SLFormat.number(overview.slots.total)),
                          systemImage: "person.2")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }

                if viewModel.privilegeLost {
                    // One strike ends the right to vouch for good (the
                    // owner's decision, 2026-09-25) — said plainly.
                    Label(L10n.t("vouch.refusal.revoked"), systemImage: "hand.raised.slash")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("vouching.list.privilegeLost")
                } else if let refusal = viewModel.refusalText {
                    Text(refusal)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("vouching.list.refusal")
                }

                if let onCreateLink {
                    SLButton(
                        L10n.t("vouch.list.create"),
                        variant: .primary,
                        icon: "link",
                        isEnabled: overview.canVouch,
                        accessibilityHint: overview.canVouch ? L10n.t("vouch.list.create.hint") : (viewModel.refusalText ?? ""),
                        action: onCreateLink
                    )
                    .accessibilityIdentifier("vouching.list.create")
                }

                Text(L10n.t("vouch.list.rules", SLFormat.number(overview.rules.inviteHours),
                            SLFormat.number(overview.rules.confirmHours), SLFormat.number(overview.rules.vouchDays)))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rows

    private func pendingRow(_ vouch: Vouch, overview: VouchingOverview) -> some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                person(vouch)
                if let accepted = vouch.acceptedAt {
                    Text(L10n.t("vouch.list.accepted", SLFormat.relative(accepted)))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
                written(vouch.details, label: vouch.label)
                if let deadline = vouch.confirmBy {
                    Label(L10n.t("vouch.list.confirmWithin", VouchCopy.hoursLeftText(until: deadline)), systemImage: "clock")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.warning)
                }
                let busy = viewModel.busy.contains(vouch.id)
                HStack(alignment: .top, spacing: SLSpacing.sm) {
                    if !viewModel.isConfirming(vouch.id, .decline) {
                        VouchConfirmControl(
                            isConfirming: confirmingBinding(vouch.id, .confirm),
                            isBusy: busy,
                            copy: VouchConfirmControl.Copy(
                                action: L10n.t("vouch.list.confirm"),
                                actionIcon: "checkmark",
                                actionVariant: .primary,
                                title: L10n.t("vouch.list.confirm.title"),
                                message: L10n.t("vouch.list.confirm.message", vouch.vouchee?.handle ?? vouch.voucheeHandle,
                                                SLFormat.number(overview.rules.vouchDays)),
                                confirm: L10n.t("vouch.list.confirm.yes"),
                                confirmVariant: .primary,
                                keep: L10n.t("vouch.list.notYet")
                            ),
                            identifier: "vouching.list.confirm"
                        ) { await viewModel.confirm(vouch) }
                    }
                    if !viewModel.isConfirming(vouch.id, .confirm) {
                        VouchConfirmControl(
                            isConfirming: confirmingBinding(vouch.id, .decline),
                            isBusy: busy,
                            copy: VouchConfirmControl.Copy(
                                action: L10n.t("vouch.list.decline"),
                                title: L10n.t("vouch.list.decline.title", vouch.vouchee?.handle ?? vouch.voucheeHandle),
                                message: L10n.t("vouch.list.decline.message"),
                                confirm: L10n.t("vouch.list.decline"),
                                keep: L10n.t("vouch.list.notYet")
                            ),
                            identifier: "vouching.list.decline"
                        ) { await viewModel.decline(vouch) }
                    }
                }
            }
        }
    }

    private func summonsRow(_ vouch: Vouch) -> some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("vouch.summons.title", vouch.vouchee?.handle ?? vouch.voucheeHandle))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let summons = vouch.summons {
                    Text(L10n.t("vouch.summons.finding", VouchCopy.finding(summons.reason)))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                    if let deadline = summons.deadline {
                        Label(L10n.t("vouch.summons.deadline", VouchCopy.hoursLeftText(until: deadline)), systemImage: "clock")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.warning)
                    }
                }
                Text(L10n.t("vouch.summons.explain"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(
                    L10n.t("vouch.summons.statement"),
                    text: Binding(
                        get: { viewModel.statements[vouch.id] ?? "" },
                        set: { viewModel.statements[vouch.id] = $0.clamped(toServerLength: VouchingViewModel.statementLimit) }
                    ),
                    prompt: Text(L10n.t("vouch.summons.placeholder")).foregroundColor(SLColor.textMuted),
                    axis: .vertical
                )
                .lineLimit(3...8)
                .font(SLFont.body)
                .padding(SLSpacing.md)
                .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface2))
                .accessibilityIdentifier("vouching.summons.statement")
                let busy = viewModel.busy.contains(vouch.id)
                SLButton(L10n.t("vouch.summons.reattest"), variant: .primary, size: .compact, isLoading: busy,
                         asyncAction: { await viewModel.answer(vouch, .reattest) })
                    .accessibilityIdentifier("vouching.summons.reattest")
                SLButton(L10n.t("vouch.summons.withdraw"), variant: .destructive, size: .compact, isEnabled: !busy,
                         asyncAction: { await viewModel.answer(vouch, .withdraw) })
                    .accessibilityIdentifier("vouching.summons.withdraw")
            }
        }
    }

    private func inviteRow(_ invite: VouchInvite) -> some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Label(
                    invite.details.map { L10n.t("vouch.list.invite.for", $0.fullName) } ?? L10n.t("vouch.list.invite.untitled"),
                    systemImage: "link"
                )
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                written(invite.details, label: invite.label, showsName: false)
                if let expires = invite.expiresAt {
                    Text(L10n.t("vouch.list.invite.expires", SLFormat.dateTime(expires)))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
                if invite.mismatches > 0 {
                    Text(L10n.plural("vouch.list.invite.mismatches", invite.mismatches))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.warning)
                }
                VouchConfirmControl(
                    isConfirming: confirmingBinding(invite.id, .burn),
                    isBusy: viewModel.busy.contains(invite.id),
                    copy: VouchConfirmControl.Copy(
                        action: L10n.t("vouch.list.invite.burn"),
                        actionIcon: "flame",
                        title: L10n.t("vouch.list.invite.burn.title"),
                        message: L10n.t("vouch.list.invite.burn.message"),
                        confirm: L10n.t("vouch.list.invite.burn"),
                        keep: L10n.t("vouch.list.notYet")
                    ),
                    identifier: "vouching.list.burn"
                ) { await viewModel.burn(invite) }
            }
        }
    }

    private func activeRow(_ vouch: Vouch) -> some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                person(vouch)
                if let expires = vouch.expiresAt {
                    Label(L10n.t("vouch.list.ends", SLFormat.date(expires), VouchCopy.daysLeftText(until: expires)),
                          systemImage: "hourglass")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
                written(vouch.details, label: vouch.label)
                VouchConfirmControl(
                    isConfirming: confirmingBinding(vouch.id, .withdraw),
                    isBusy: viewModel.busy.contains(vouch.id),
                    copy: VouchConfirmControl.Copy(
                        action: L10n.t("vouch.list.withdraw"),
                        actionIcon: "arrow.uturn.backward",
                        title: L10n.t("vouch.list.withdraw.title", vouch.vouchee?.handle ?? vouch.voucheeHandle),
                        message: L10n.t("vouch.list.withdraw.message"),
                        confirm: L10n.t("vouch.list.withdraw"),
                        keep: L10n.t("vouch.list.notYet")
                    ),
                    identifier: "vouching.list.withdraw"
                ) { await viewModel.withdraw(vouch) }
            }
        }
    }

    private func endedRow(_ vouch: Vouch) -> some View {
        HStack(alignment: .top, spacing: SLSpacing.md) {
            Image(systemName: vouch.status == .graduated ? "checkmark.seal" : "clock.arrow.circlepath")
                .foregroundStyle(vouch.status == .graduated ? SLColor.secondary : SLColor.textMuted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(vouch.atVouchee)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                Text(VouchCopy.endReason(vouch.endReason))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                if let ended = vouch.endedAt {
                    Text(SLFormat.date(ended))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SLSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    /// The person, tappable when the account is still there to open.
    private func person(_ vouch: Vouch) -> some View {
        HStack(spacing: SLSpacing.md) {
            if let person = vouch.vouchee {
                SLAvatar(url: person.avatarURL, initials: person.initials, size: .md,
                         isVerified: person.isVerified, displayName: person.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: person.displayName))
                    Text(person.atHandle)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
            } else {
                Text(L10n.t("vouch.list.gone", vouch.voucheeHandle))
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
            }
            Spacer(minLength: 0)
            if let person = vouch.vouchee, let onOpenProfile {
                Button {
                    onOpenProfile(person.handle)
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SLColor.textMuted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("post.author.openProfile.hint", person.displayName)))
            }
        }
    }

    /// What the voucher wrote — theirs to see, and nobody else's.
    @ViewBuilder
    private func written(_ details: VouchDetails?, label: String?, showsName: Bool = true) -> some View {
        if details != nil || label != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let details {
                    Text(L10n.t("vouch.list.youWrote"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                    let parts = (showsName ? [details.fullName] : [])
                        + [CountryCode.name(details.nationality) ?? details.nationality,
                           ISODay.date(details.dateOfBirth).map(VouchDetailsForm.dayText) ?? details.dateOfBirth]
                    Text(parts.joined(separator: " · "))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let label {
                    Text(L10n.t("vouch.list.note", label))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(title.uppercased())
                .font(SLFont.micro)
                .slTracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func confirmingBinding(_ id: UUID, _ action: VouchingViewModel.RowAction) -> Binding<Bool> {
        Binding(
            get: { viewModel.isConfirming(id, action) },
            set: { viewModel.confirming = $0 ? (id, action) : nil }
        )
    }
}
