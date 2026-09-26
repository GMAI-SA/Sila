import SwiftUI
import UIKit

/// A vouch link, opened (contract v24 §5 and §11).
///
/// Who is vouching — their seal, flag and "verified since" — and until when
/// the link works; then the person's own full name, nationality and date of
/// birth, the four promises, and **Accept the vouch**. Signed out, the same
/// landing asks them to join first, and the link waits for them.
///
/// A mismatch says which fields did not match what the voucher entered —
/// never what the voucher entered — and keeps what was typed so it can be
/// corrected; the third closes the link.
@MainActor
public struct VouchClaimScreen: View {

    @State private var viewModel: VouchClaimViewModel
    private let onCreateAccount: (() -> Void)?
    private let onSignIn: (() -> Void)?
    private let onClose: () -> Void

    /// - Parameters:
    ///   - onCreateAccount: Signed out: leave for registration; the link
    ///     comes back after the email code.
    ///   - onSignIn: Signed out: leave for the sign-in form.
    ///   - onClose: Done, or not now — the link is let go.
    public init(
        viewModel: @autoclosure () -> VouchClaimViewModel,
        onCreateAccount: (() -> Void)? = nil,
        onSignIn: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel())
        self.onCreateAccount = onCreateAccount
        self.onSignIn = onSignIn
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .padding(.horizontal, SLSpacing.lg)
                        .padding(.vertical, SLSpacing.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A mismatch is said above the fields; the form is scrolled
                // back to it, so the tries left are read, not missed.
                .onChange(of: viewModel.attemptsLeft) { _, left in
                    guard left != nil else { return }
                    withAnimation { proxy.scrollTo(Self.mismatchAnchor, anchor: .top) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("vouch.claim.nav"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFinished ? L10n.t("common.done") : L10n.t("vouch.own.later"), action: onClose)
                        .accessibilityIdentifier("vouching.claim.close")
                }
            }
        }
        .tint(SLColor.primary)
        .task { await viewModel.load() }
    }

    private static let mismatchAnchor = "vouching.claim.mismatchAnchor"

    private var isFinished: Bool {
        switch viewModel.phase {
        case .claimed, .unavailable, .closed, .refused: return true
        case .loading, .open: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
                .tint(SLColor.primary)
                .frame(maxWidth: .infinity)
                .padding(.top, SLSpacing.xxl)
                .accessibilityLabel(Text(L10n.t("vouch.claim.loading")))

        case .unavailable:
            SLEmptyState(
                icon: "link.badge.plus",
                title: L10n.t("vouch.claim.unavailable.title"),
                subtitle: L10n.t("vouch.claim.unavailable.message"),
                tint: SLColor.textSecondary
            )
            .accessibilityIdentifier("vouching.claim.unavailable")

        case .closed:
            SLEmptyState(
                icon: "lock.fill",
                title: L10n.t("vouch.claim.closed.title"),
                subtitle: L10n.t("vouch.claim.closed.message"),
                tint: SLColor.danger
            )
            .accessibilityIdentifier("vouching.claim.closed")

        case let .refused(message):
            SLEmptyState(
                icon: "person.crop.circle.badge.exclamationmark",
                title: L10n.t("vouch.claim.refused.title"),
                subtitle: message,
                tint: SLColor.warning
            )
            .accessibilityIdentifier("vouching.claim.refused")

        case let .claimed(vouch):
            claimed(vouch)

        case let .open(landing):
            VStack(alignment: .leading, spacing: SLSpacing.xl) {
                voucherCard(landing)
                if !viewModel.isSignedIn {
                    joinFirst
                } else if !viewModel.hasAcknowledgedWarnings {
                    // Before the details form, every time (contract v24
                    // §12): what the details are for, and what false ones cost.
                    VouchWarningCard(
                        title: L10n.t("vouch.warning.person.title"),
                        warnings: [
                            L10n.t("vouch.warning.person.one", landing.voucher.handle),
                            L10n.t("vouch.warning.person.two", landing.voucher.handle)
                        ],
                        identifier: "vouching.warning.person",
                        onContinue: { withAnimation { viewModel.hasAcknowledgedWarnings = true } },
                        onCancel: onClose
                    )
                } else {
                    form(landing)
                }
            }
        }
    }

    // MARK: - The voucher

    private func voucherCard(_ landing: VouchInviteLanding) -> some View {
        let voucher = landing.voucher
        return VStack(alignment: .leading, spacing: SLSpacing.md) {
            HStack(spacing: SLSpacing.md) {
                SLAvatar(url: voucher.avatarURL, initials: voucher.initials, size: .lg,
                         isVerified: voucher.isVerified, displayName: voucher.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SLSpacing.xs) {
                        Text(voucher.displayName)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                            .slContentDirection(TextDirection.resolve(languageCode: nil, text: voucher.displayName))
                        if voucher.isVerified { SLVerifiedBadge(size: 15, isPulsing: false) }
                        SLCountryBadge(countryCode: voucher.countryCode)
                    }
                    Text(voucher.atHandle)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                    if voucher.isVerified, let since = voucher.verifiedSince {
                        Text(L10n.t("profile.verifiedSince", SLFormat.monthAndYear(since)))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Text(L10n.t("vouch.claim.title", voucher.handle))
                .font(SLFont.displayM)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("vouching.claim.title")

            if let expires = landing.expiresAt {
                Label(L10n.t("vouch.claim.expires", SLFormat.dateTime(expires)), systemImage: "clock")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
    }

    // MARK: - Signed out

    private var joinFirst: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            Text(L10n.t("vouch.claim.guest"))
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onCreateAccount {
                SLButton(L10n.t("guest.join.create"), variant: .primary, action: onCreateAccount)
                    .accessibilityIdentifier("vouching.claim.createAccount")
            }
            if let onSignIn {
                SLButton(L10n.t("guest.join.signIn"), variant: .secondary, action: onSignIn)
                    .accessibilityIdentifier("vouching.claim.signIn")
            }
        }
    }

    // MARK: - The claim

    private func form(_ landing: VouchInviteLanding) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            Text(L10n.t("vouch.claim.message", landing.voucher.handle))
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let mismatch = viewModel.mismatchText {
                mismatchBanner(mismatch)
                    .id(Self.mismatchAnchor)
            }

            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                sectionHeader(L10n.t("vouch.claim.details.header"))
                Text(L10n.t("vouch.claim.details.hint", landing.voucher.handle))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                VouchDetailsForm(
                    draft: $viewModel.draft,
                    isOwn: true,
                    mismatched: Set(viewModel.mismatched),
                    errors: viewModel.fieldErrors
                )
            }

            VStack(alignment: .leading, spacing: SLSpacing.md) {
                sectionHeader(L10n.t("vouch.claim.attest.header"))
                AttestationRow(text: L10n.t("vouch.claim.attest.adult"), isOn: $viewModel.adult, identifier: "vouching.claim.attest.adult")
                AttestationRow(text: L10n.t("vouch.claim.attest.realName"), isOn: $viewModel.realName, identifier: "vouching.claim.attest.realName")
                AttestationRow(text: L10n.t("vouch.claim.attest.singleAccount"), isOn: $viewModel.singleAccount, identifier: "vouching.claim.attest.singleAccount")
                AttestationRow(text: L10n.t("vouch.claim.attest.terms"), isOn: $viewModel.terms, identifier: "vouching.claim.attest.terms")
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vouching.claim.error")
            }

            SLButton(
                L10n.t("vouch.claim.accept"),
                variant: .primary,
                isLoading: viewModel.isSubmitting,
                isEnabled: viewModel.canSubmit,
                accessibilityHint: L10n.t("vouch.claim.accept.hint", landing.voucher.handle),
                asyncAction: {
                    // The keyboard goes, so the answer — a mismatch above,
                    // or the claim — is what is on screen.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    await viewModel.submit()
                }
            )
            .accessibilityIdentifier("vouching.claim.accept")
        }
    }

    /// Which fields did not match, and how many tries are left — nothing the
    /// voucher wrote.
    private func mismatchBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: SLSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SLColor.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text(text)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let left = viewModel.attemptsLeft {
                    Text(VouchCopy.attemptsLeft(left))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                }
            }
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.danger.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vouching.claim.mismatch")
    }

    private func claimed(_ vouch: VouchState?) -> some View {
        let handle = vouch?.voucher?.handle ?? vouch?.voucherHandle ?? viewModel.voucher?.handle ?? ""
        return VStack(spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: SLVouchTag.glyph,
                title: L10n.t("vouch.wall.pending.title", handle),
                subtitle: L10n.t("vouch.claim.done", handle),
                tint: SLColor.secondary
            )
            SLButton(L10n.t("common.done"), variant: .primary, action: onClose)
                .accessibilityIdentifier("vouching.claim.done")
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SLFont.micro)
            .slTracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}
