import SwiftUI
import UIKit

/// Drives ``VouchInviteSheet`` — minting a vouch link (contract v24 §5, §11).
///
/// The voucher says who the person is (full name, nationality, date of
/// birth — 18 or older), may keep a private note, ticks the four promises
/// under the line that says what they are putting behind it, and gets a
/// link to share at once: the token is in this one response and nowhere
/// else, ever.
@MainActor
@Observable
public final class VouchInviteViewModel {

    public var draft = VouchDetailsDraft()
    public var label = ""
    public var knowsPersonally = false
    public var adult = false
    public var realName = false
    public var singleAccount = false
    public private(set) var isMinting = false
    public private(set) var minted: MintedInvite?
    public private(set) var fieldErrors: [VouchDetailField: String] = [:]
    public var errorMessage: String?
    /// The two plain warnings were read and accepted (contract v24 §12).
    /// Every time the sheet opens: never remembered.
    public var hasAcknowledgedWarnings = false

    /// The note's limit on the server.
    public static let labelLimit = 60

    private let service: VouchingServiceProtocol
    private let analytics: AnalyticsClient
    private let onMinted: @MainActor () async -> Void

    public init(service: VouchingServiceProtocol, analytics: AnalyticsClient, onMinted: @escaping @MainActor () async -> Void) {
        self.service = service
        self.analytics = analytics
        self.onMinted = onMinted
    }

    public var hasAttested: Bool { knowsPersonally && adult && realName && singleAccount }

    public var canMint: Bool {
        hasAcknowledgedWarnings && draft.details != nil && hasAttested && !isMinting && minted == nil
    }

    public func mint() async {
        errorMessage = nil
        fieldErrors = [:]
        guard hasAcknowledgedWarnings else { return }
        guard let details = draft.details else {
            errorMessage = L10n.t("vouch.error.detailsRequired")
            return
        }
        guard hasAttested else {
            errorMessage = L10n.t("vouch.error.attestationsRequired")
            return
        }
        if draft.isUnderAge() {
            // Nobody under 18 can be vouched for; said before a link is spent.
            fieldErrors = [.dateOfBirth: L10n.t("vouch.error.underAge")]
            return
        }
        isMinting = true
        defer { isMinting = false }
        do {
            minted = try await service.mintInvite(label: String(label.prefix(Self.labelLimit)), details: details)
            await onMinted()
        } catch let error as APIError {
            guard !error.isCancellation else { return }
            switch error.code {
            case .invalidFullName: fieldErrors = [.fullName: L10n.t("vouch.error.invalidFullName")]
            case .invalidCountry: fieldErrors = [.nationality: L10n.t("vouch.error.invalidCountry")]
            case .invalidDateOfBirth: fieldErrors = [.dateOfBirth: L10n.t("vouch.error.invalidDateOfBirth")]
            case .vouchUnderAge: fieldErrors = [.dateOfBirth: L10n.t("vouch.error.underAge")]
            default: errorMessage = error.userMessage
            }
        } catch {
            errorMessage = L10n.t("common.somethingWentWrong")
        }
    }

    public func didShare() {
        analytics.track(.vouchLinkShared)
    }
}

/// Minting a vouch link, then sharing it.
@MainActor
public struct VouchInviteSheet: View {

    @Bindable private var viewModel: VouchInviteViewModel
    private let inviteHours: Int
    private let onClose: () -> Void
    @State private var copied = false

    public init(viewModel: VouchInviteViewModel, inviteHours: Int = 72, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.inviteHours = inviteHours
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let minted = viewModel.minted {
                        ready(minted)
                    } else if !viewModel.hasAcknowledgedWarnings {
                        // Before the details form, every time (contract
                        // v24 §12): what vouching costs, in two sentences.
                        VouchWarningCard(
                            title: L10n.t("vouch.warning.voucher.title"),
                            warnings: [L10n.t("vouch.warning.voucher.one"), L10n.t("vouch.warning.voucher.two")],
                            identifier: "vouching.warning.voucher",
                            onContinue: { withAnimation { viewModel.hasAcknowledgedWarnings = true } },
                            onCancel: onClose
                        )
                    } else {
                        form
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("vouch.new.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.minted == nil ? L10n.t("common.cancel") : L10n.t("common.done"), action: onClose)
                        .accessibilityIdentifier("vouching.new.close")
                }
            }
        }
        .tint(SLColor.primary)
        .interactiveDismissDisabled(viewModel.isMinting)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xl) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                header(L10n.t("vouch.new.who.header"))
                Text(L10n.t("vouch.new.who.hint"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                VouchDetailsForm(draft: $viewModel.draft, isOwn: false, errors: viewModel.fieldErrors)
            }

            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                SLTextField(
                    L10n.t("vouch.new.note"),
                    text: Binding(
                        get: { viewModel.label },
                        set: { viewModel.label = String($0.prefix(VouchInviteViewModel.labelLimit)) }
                    ),
                    placeholder: L10n.t("vouch.new.note.placeholder"),
                    autocapitalization: .sentences
                )
            }

            VStack(alignment: .leading, spacing: SLSpacing.md) {
                header(L10n.t("vouch.new.attest.header"))
                AttestationRow(text: L10n.t("vouch.new.attest.knows"), isOn: $viewModel.knowsPersonally, identifier: "vouching.new.attest.knows")
                AttestationRow(text: L10n.t("vouch.new.attest.adult"), isOn: $viewModel.adult, identifier: "vouching.new.attest.adult")
                AttestationRow(text: L10n.t("vouch.new.attest.realName"), isOn: $viewModel.realName, identifier: "vouching.new.attest.realName")
                AttestationRow(text: L10n.t("vouch.new.attest.singleAccount"), isOn: $viewModel.singleAccount, identifier: "vouching.new.attest.singleAccount")
            }

            // The voucher's responsibility line — the words a strike rests
            // on, shown where the promise is made (contract v24 §7).
            Text(L10n.t("vouch.new.responsibility"))
                .font(SLFont.body)
                .foregroundStyle(SLColor.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(SLSpacing.md)
                .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.warning.opacity(0.08)))
                .accessibilityIdentifier("vouching.new.responsibility")

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SLButton(
                L10n.t("vouch.new.create"),
                variant: .primary,
                icon: "link",
                isLoading: viewModel.isMinting,
                isEnabled: viewModel.canMint,
                asyncAction: { await viewModel.mint() }
            )
            .accessibilityIdentifier("vouching.new.create")
        }
    }

    private func ready(_ minted: MintedInvite) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: "link.circle.fill",
                title: L10n.t("vouch.new.ready.title"),
                subtitle: L10n.t("vouch.new.ready.message",
                                 minted.invite.details?.fullName ?? viewModel.draft.fullName,
                                 SLFormat.number(inviteHours)),
                tint: SLColor.secondary
            )
            Text(minted.url.absoluteString)
                .font(SLFont.mono)
                .foregroundStyle(SLColor.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SLSpacing.md)
                .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1))
                .environment(\.layoutDirection, .leftToRight)
            ShareLink(item: minted.url, message: Text(L10n.t("vouch.new.shareText"))) {
                Label(L10n.t("vouch.new.share"), systemImage: "square.and.arrow.up")
                    .font(SLFont.bodyEmphasis)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Color(tnHex: 0x02121C))
                    .background(SLColor.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
            }
            .simultaneousGesture(TapGesture().onEnded { viewModel.didShare() })
            .accessibilityIdentifier("vouching.new.share")
            SLButton(copied ? L10n.t("vouch.new.copied") : L10n.t("vouch.new.copy"), variant: .secondary, icon: "doc.on.doc") {
                UIPasteboard.general.url = minted.url
                copied = true
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SLFont.micro)
            .tracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}
