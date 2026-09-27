import SwiftUI

/// Drives ``OwnVouchScreen`` — the vouched person's own vouch (`GET /me/vouch`).
@MainActor
@Observable
public final class OwnVouchViewModel {

    public private(set) var mine: MyVouch?
    public private(set) var isLoading = false
    public private(set) var isRemoving = false
    public var isConfirmingRemoval = false
    public var toast: SLToastMessage?

    private let service: VouchingServiceProtocol
    private let onChanged: @MainActor () async -> Void

    /// - Parameter onChanged: The tag came off: the session re-reads
    ///   `/auth/me` and routes — back to the wall until they verify.
    public init(service: VouchingServiceProtocol, initial: MyVouch? = nil, onChanged: @escaping @MainActor () async -> Void) {
        self.service = service
        self.mine = initial
        self.onChanged = onChanged
    }

    public var vouch: VouchState? { mine?.vouch }
    public var rights: VouchRights { mine?.rights ?? .vouchedDefault }
    public var limits: VouchLimits { mine?.limits ?? VouchLimits() }

    /// What the vouch allows, and what opens only with verification.
    public var granted: [String] { rights.keys.filter { rights.allows($0) } }
    public var withheld: [String] { rights.keys.filter { !rights.allows($0) } }

    public func load() async {
        isLoading = mine == nil
        defer { isLoading = false }
        do {
            mine = try await service.myVouch()
        } catch let error as APIError {
            if !error.isCancellation { toast = .error(error.userMessage) }
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
        }
    }

    /// Takes the tag off (or withdraws a pending claim). Everything written
    /// stays; the account is back at the wall until it verifies.
    public func remove() async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await service.removeMyVouch()
            isConfirmingRemoval = false
            toast = .success(L10n.t("vouch.mine.removed"))
            await onChanged()
        } catch let error as APIError where error.code == .vouchNotFound {
            isConfirmingRemoval = false
            await onChanged()
        } catch let error as APIError {
            if !error.isCancellation { toast = .error(error.userMessage) }
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
        }
    }
}

/// "Your vouch": whose word the name carries, how long it lasts, what it
/// lets you do and what waits for your own verification — and the one door
/// that lasts (contract v24 §2, §4).
@MainActor
public struct OwnVouchScreen: View {

    @Bindable private var viewModel: OwnVouchViewModel
    private let onVerify: (@MainActor () -> Void)?
    private let onOpenProfile: (@MainActor (String) -> Void)?

    public init(
        viewModel: OwnVouchViewModel,
        onVerify: (@MainActor () -> Void)?,
        onOpenProfile: (@MainActor (String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onVerify = onVerify
        self.onOpenProfile = onOpenProfile
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                if viewModel.isLoading {
                    ProgressView().tint(SLColor.primary).frame(maxWidth: .infinity)
                } else if let mine = viewModel.mine {
                    switch mine.standing {
                    case .verified:
                        SLEmptyState(
                            icon: "checkmark.seal.fill",
                            title: L10n.t("vouch.mine.verified.title"),
                            subtitle: L10n.t("vouch.mine.verified.message"),
                            tint: SLColor.secondary
                        )
                    case .vouched:
                        vouched(mine)
                    case .noStanding:
                        if let vouch = mine.vouch, vouch.isPending {
                            pending(vouch)
                        } else if mine.vouch == nil, let ended = mine.lastEnded {
                            // Landed here with no live vouch (contract v24
                            // §15): why the last one ended, and the way on.
                            endedVouch(ended)
                        } else {
                            SLEmptyState(
                                icon: SLVouchTag.glyph,
                                title: L10n.t("vouch.mine.none.title"),
                                subtitle: L10n.t("vouch.mine.none.message"),
                                tint: SLColor.textSecondary
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.lg)
        }
        .refreshable { await viewModel.load() }
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("vouch.mine.nav"))
        .tnToast($viewModel.toast)
        .task { await viewModel.load() }
    }

    // MARK: - Vouched

    @ViewBuilder
    private func vouched(_ mine: MyVouch) -> some View {
        if let vouch = mine.vouch {
            let handle = vouch.voucher?.handle ?? vouch.voucherHandle
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                if let confirmed = vouch.confirmedAt {
                    Text(L10n.t("vouch.mine.intro", handle, SLFormat.date(confirmed)))
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let voucher = vouch.voucher, let onOpenProfile {
                    SLButton(L10n.t("vouch.explainer.see", voucher.handle), variant: .ghost, size: .compact,
                             icon: "person.crop.circle") { onOpenProfile(voucher.handle) }
                }
            }
            countdown(vouch)
        }
        makeItYourOwn(mine.vouch)
        rightsList(L10n.t("vouch.mine.can.header"), keys: viewModel.granted, granted: true)
        rightsList(L10n.t("vouch.mine.cannot.header"), keys: viewModel.withheld, granted: false)
        limits
        removal
    }

    /// The 30 days, and the door after them.
    private func countdown(_ vouch: VouchState) -> some View {
        SLCard(padding: SLSpacing.lg) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                if let expires = vouch.expiresAt {
                    Text(VouchCopy.daysLeftText(until: expires))
                        .font(SLFont.displayM)
                        .foregroundStyle(SLColor.warning)
                        .accessibilityIdentifier("vouching.mine.daysLeft")
                    Text(L10n.t("vouch.mine.countdown.detail", SLFormat.date(expires)))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func makeItYourOwn(_ vouch: VouchState?) -> some View {
        if let onVerify {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("vouch.own.title"))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                if let vouch {
                    Text(VouchCopy.makeItYourOwn(voucher: vouch.voucher?.handle ?? vouch.voucherHandle))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SLButton(L10n.t("vouch.own.action"), variant: .primary, icon: "checkmark.seal",
                         accessibilityHint: L10n.t("vouch.own.action.hint"), action: onVerify)
                    .accessibilityIdentifier("vouching.mine.verify")
            }
        }
    }

    @ViewBuilder
    private func rightsList(_ title: String, keys: [String], granted: Bool) -> some View {
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(title.uppercased())
                    .font(SLFont.micro)
                    .slTracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(keys, id: \.self) { key in
                    Label(VouchRightsCopy.title(key), systemImage: granted ? "checkmark.circle" : "lock")
                        .font(SLFont.caption)
                        .foregroundStyle(granted ? SLColor.textPrimary : SLColor.textSecondary)
                }
            }
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(L10n.t("vouch.mine.limits.header").uppercased())
                .font(SLFont.micro)
                .slTracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            let limits = viewModel.limits
            Text(L10n.t("vouch.mine.limits.posts", SLFormat.number(limits.postsPerHour), SLFormat.number(limits.postsPerDay)))
            Text(L10n.t("vouch.mine.limits.mentions", SLFormat.number(limits.mentionsPerPost)))
            Text(L10n.t("vouch.mine.limits.follows", SLFormat.number(limits.followsPerHour)))
        }
        .font(SLFont.caption)
        .foregroundStyle(SLColor.textSecondary)
    }

    private var removal: some View {
        VouchConfirmControl(
            isConfirming: $viewModel.isConfirmingRemoval,
            isBusy: viewModel.isRemoving,
            copy: VouchConfirmControl.Copy(
                action: L10n.t("vouch.mine.remove"),
                actionIcon: "tag.slash",
                title: L10n.t("vouch.mine.remove.title"),
                message: L10n.t("vouch.mine.remove.message"),
                confirm: L10n.t("vouch.mine.remove.yes"),
                keep: L10n.t("vouch.mine.keep")
            ),
            identifier: "vouching.mine.remove"
        ) { await viewModel.remove() }
    }

    // MARK: - Ended

    private func endedVouch(_ ended: LastEndedVouch) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            VouchEndedCard(ended: ended, identifier: "vouching.mine.ended")
            if let onVerify {
                SLButton(L10n.t("vouch.own.action"), variant: .primary, icon: "checkmark.seal",
                         accessibilityHint: L10n.t("vouch.own.action.hint"), action: onVerify)
                    .accessibilityIdentifier("vouching.mine.ended.verify")
            }
        }
    }

    // MARK: - Pending

    private func pending(_ vouch: VouchState) -> some View {
        let handle = vouch.voucher?.handle ?? vouch.voucherHandle
        return VStack(alignment: .leading, spacing: SLSpacing.md) {
            SLEmptyState(
                icon: SLVouchTag.glyph,
                title: L10n.t("vouch.wall.pending.title", handle),
                subtitle: vouch.confirmBy.map { L10n.t("vouch.wall.pending.message", handle, SLFormat.dateTime($0)) }
                    ?? L10n.t("vouch.wall.pending.messageNoDate", handle),
                tint: SLColor.warning
            )
            makeItYourOwn(nil)
        }
    }
}

/// The rights table's rows, in words.
public enum VouchRightsCopy {
    public static func title(_ key: String) -> String {
        switch key {
        case "post_international": return L10n.t("vouch.right.postInternational")
        case "reply_international": return L10n.t("vouch.right.replyInternational")
        case "post_country_or_region": return L10n.t("vouch.right.postCountryOrRegion")
        case "react": return L10n.t("vouch.right.react")
        case "repost": return L10n.t("vouch.right.repost")
        case "bookmark": return L10n.t("vouch.right.bookmark")
        case "follow": return L10n.t("vouch.right.follow")
        case "join_open_communities": return L10n.t("vouch.right.joinOpenCommunities")
        case "join_verified_only_communities": return L10n.t("vouch.right.joinVerifiedOnlyCommunities")
        case "listen_in_rooms": return L10n.t("vouch.right.listenInRooms")
        case "speak_in_rooms": return L10n.t("vouch.right.speakInRooms")
        case "raise_hand": return L10n.t("vouch.right.raiseHand")
        case "host_rooms": return L10n.t("vouch.right.hostRooms")
        case "direct_messages": return L10n.t("vouch.right.directMessages")
        case "vouch_for_others": return L10n.t("vouch.right.vouchForOthers")
        case "challenge_identities": return L10n.t("vouch.right.challengeIdentities")
        case "moderate": return L10n.t("vouch.right.moderate")
        case "seal_flag_or_verified_name": return L10n.t("vouch.right.sealFlagOrVerifiedName")
        case "ranked_and_trending": return L10n.t("vouch.right.rankedAndTrending")
        default: return NotificationGroup.humanised(key)
        }
    }
}
