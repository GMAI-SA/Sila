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
    /// The minted link has left the sheet — shared, or copied. Until then the
    /// sheet does not close without asking: the server gives the link in the
    /// mint's one response and never again, and the day's link is spent.
    public private(set) var hasSavedLink = false
    /// "Close without sharing it?", asked in place.
    public var isConfirmingClose = false

    /// The note's limit on the server, in code points (see
    /// ``Swift/String/serverLength``).
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
            minted = try await service.mintInvite(label: label.clamped(toServerLength: Self.labelLimit), details: details)
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

    /// The share sheet finished with the link sent somewhere.
    public func didShare() {
        hasSavedLink = true
        isConfirmingClose = false
        analytics.track(.vouchLinkShared)
    }

    /// The link went to the clipboard.
    public func didCopy() {
        hasSavedLink = true
        isConfirmingClose = false
    }

    /// Whether the sheet may close without a word: nothing minted, or the
    /// link already taken somewhere.
    public var mayCloseFreely: Bool { minted == nil || hasSavedLink }

    /// Done, or Cancel: closes when nothing would be lost, and otherwise asks
    /// first. - Returns: whether to close now.
    public func requestClose() -> Bool {
        if mayCloseFreely || isConfirmingClose { return true }
        isConfirmingClose = true
        return false
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
                    Button(viewModel.minted == nil ? L10n.t("common.cancel") : L10n.t("common.done")) {
                        if viewModel.requestClose() { onClose() }
                    }
                    .accessibilityIdentifier("vouching.new.close")
                }
            }
        }
        .tint(SLColor.primary)
        // No swipe away while the link is being made, nor once it is made and
        // has gone nowhere yet: it is shown this once.
        .interactiveDismissDisabled(viewModel.isMinting || !viewModel.mayCloseFreely)
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
                    text: $viewModel.label,
                    placeholder: L10n.t("vouch.new.note.placeholder"),
                    autocapitalization: .sentences
                )
                .onChange(of: viewModel.label) { _, value in
                    // Counted the way the server counts (code points), so a
                    // note with harakat is not refused as too long.
                    let clamped = value.clamped(toServerLength: VouchInviteViewModel.labelLimit)
                    if clamped != value { viewModel.label = clamped }
                }
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
            // The system share sheet, opened by UIKit so its completion says
            // whether the link actually went somewhere. A `ShareLink` with a
            // tap gesture beside it never opened at all: the gesture took
            // the tap.
            Button {
                ActivitySharing.present(items: [L10n.t("vouch.new.shareText"), minted.url]) { completed in
                    if completed { viewModel.didShare() }
                }
            } label: {
                Label(L10n.t("vouch.new.share"), systemImage: "square.and.arrow.up")
                    .font(SLFont.bodyEmphasis)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Color(tnHex: 0x02121C))
                    .background(SLColor.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
                    .contentShape(RoundedRectangle(cornerRadius: SLRadius.md))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("vouching.new.share")
            SLButton(copied ? L10n.t("vouch.new.copied") : L10n.t("vouch.new.copy"), variant: .secondary, icon: "doc.on.doc") {
                UIPasteboard.general.url = minted.url
                copied = true
                viewModel.didCopy()
            }
            .accessibilityIdentifier("vouching.new.copy")
            if viewModel.isConfirmingClose {
                closeWarning
            }
        }
    }

    /// Asked in place before a link that went nowhere is closed away.
    private var closeWarning: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("vouch.new.closeWarning"))
                .font(SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            SLButton(L10n.t("vouch.new.closeWarning.close"), variant: .destructive, size: .compact, action: onClose)
                .accessibilityIdentifier("vouching.new.closeAnyway")
            SLButton(L10n.t("vouch.new.closeWarning.keep"), variant: .ghost, size: .compact) {
                viewModel.isConfirmingClose = false
            }
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.warning.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vouching.new.closeWarning")
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SLFont.micro)
            .slTracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The system share sheet, over whatever is on top, with its answer.
@MainActor
enum ActivitySharing {

    /// - Parameter completion: `true` when the items were sent somewhere,
    ///   `false` when the sheet was closed without.
    static func present(items: [Any], completion: @escaping @MainActor (Bool) -> Void) {
        guard let top = SelfVerificationPresenter.topViewController() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in completion(completed) }
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}
