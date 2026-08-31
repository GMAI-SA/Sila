import SwiftUI

/// The `…` overflow menu that carries block, mute and report.
///
/// Behind an overflow on purpose. Reply and Follow are what somebody came to the
/// screen to do; putting Report beside them as a peer would make every post look
/// like an accusation waiting to happen, and would push the buttons people
/// actually use into a scroll. Behind the `…` these three are one tap away and
/// nowhere near the primary path — which is where a safety tool belongs: findable
/// without hunting, not competing.
///
/// The menu itself does the copy work the dialogs cannot: a header on the group
/// says the two silent actions are silent, because that sentence has to be
/// readable *before* somebody commits to either, not in the toast afterwards.
@MainActor
public struct SafetyMenu: View {

    private let actions: SafetyMenuActions

    /// - Parameter actions: What this menu can do, for one person.
    public init(actions: SafetyMenuActions) {
        self.actions = actions
    }

    public var body: some View {
        Section {
            reportButton
            muteButton
            blockButton
        } header: {
            // The one line that has to be readable before either silent action
            // is taken, rather than confessed in a toast afterwards.
            Text("Blocking and muting are silent — \(actions.target.name) is never told.")
        }
    }

    // MARK: - Items

    /// Report. Not destructive-red: reporting is not an attack, and colouring it
    /// like one discourages the reports a platform most needs.
    private var reportButton: some View {
        Button(action: actions.onReport) {
            Label("Report…", systemImage: "flag")
        }
        .accessibilityHint(Text(
            "Opens a list of reasons. Reporting is confidential — "
                + "\(actions.target.name) is never shown who reported them."
        ))
    }

    /// Mute or unmute. One tap either way, and the label says which.
    @ViewBuilder
    private var muteButton: some View {
        if actions.isMuted {
            Button(action: actions.onUnmute) {
                Label("Unmute \(actions.target.atHandle)", systemImage: "speaker.wave.2")
            }
            .disabled(actions.isBusy)
            .accessibilityHint(Text("Lets their posts back into your feeds. They are not told."))
        } else {
            Button(action: actions.onMute) {
                Label("Mute \(actions.target.atHandle)", systemImage: "speaker.slash")
            }
            .disabled(actions.isBusy || actions.isBlocked)
            .accessibilityHint(Text(SafetyCopy.muteEffect + " " + SafetyCopy.muteIsSilent))
        }
    }

    /// Block or unblock.
    ///
    /// The ellipsis on "Block…" is load-bearing: it is the platform's convention
    /// for "this opens something else", and it is true here — the next thing that
    /// happens is a list of consequences, not a block.
    @ViewBuilder
    private var blockButton: some View {
        if actions.isBlocked {
            Button(action: actions.onUnblock) {
                Label("Unblock \(actions.target.atHandle)", systemImage: "hand.raised.slash")
            }
            .disabled(actions.isBusy)
            .accessibilityHint(Text(
                "Lets you see each other again. It does not restore any follow that was severed."
            ))
        } else {
            Button(role: .destructive, action: actions.onBlock) {
                Label("Block \(actions.target.atHandle)…", systemImage: "hand.raised")
            }
            .disabled(actions.isBusy)
            .accessibilityHint(Text(
                "Asks you to confirm first, and says what a block removes."
            ))
        }
    }
}

/// The `…` control itself: a button that opens a ``SafetyMenu``.
///
/// A separate view so the post card and the profile header render the same
/// target, the same size and the same VoiceOver label, rather than each growing
/// its own.
@MainActor
public struct SafetyMenuButton: View {

    private let actions: SafetyMenuActions
    private let size: CGFloat
    private let onOpen: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - actions: What the menu can do.
    ///   - size: Glyph point size. Defaults to the post card's.
    ///   - onOpen: Called when the menu is opened, for analytics.
    public init(
        actions: SafetyMenuActions,
        size: CGFloat = 15,
        onOpen: (@MainActor () -> Void)? = nil
    ) {
        self.actions = actions
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Menu {
            SafetyMenu(actions: actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(SLColor.textSecondary)
                // A 44pt target on a glyph that is 15pt wide. The alternative is
                // a safety control people miss and hit the post underneath.
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .simultaneousGesture(TapGesture().onEnded { onOpen?() })
        .accessibilityLabel(Text("More options for \(actions.target.name)"))
        .accessibilityHint(Text("Report, mute or block this account"))
    }
}

// MARK: - The block confirmation

/// The dialog in front of every block.
///
/// An `alert` rather than a `confirmationDialog`, and that is a deliberate
/// downgrade in slickness: an action sheet on iOS gives its message a few lines
/// of small grey text, and four consequences — one of which is "unblocking will
/// not undo this" — do not survive that treatment. An alert renders the whole
/// list at readable size and makes the user reach past it to the destructive
/// button.
@MainActor
struct BlockConfirmationModifier: ViewModifier {

    @Binding var confirmation: BlockConfirmation?
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.alert(
            confirmation?.title ?? "Block this account?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { pending in
            Button("Cancel", role: .cancel) { onCancel() }
            Button(pending.confirmTitle, role: .destructive) { onConfirm() }
        } message: { pending in
            // All four consequences, verbatim from the domain, plus the line
            // saying where to undo it. Nothing here is summarised: the third
            // sentence — that unblocking does not restore the follows — is the
            // one people do not expect, and it is the reason this is a dialog
            // and not a toast.
            Text(
                pending.consequences.joined(separator: "\n\n")
                    + "\n\n" + SafetyCopy.blockReversible
            )
        }
    }
}

extension View {

    /// Attaches the block confirmation, the report sheet and the safety toast.
    ///
    /// One modifier at the top of the app rather than three per screen: the
    /// dialog has to survive the card it was opened from disappearing — which is
    /// exactly what a block does to it — and a sheet anchored to a row that is
    /// about to be removed is a sheet that closes itself halfway through.
    @MainActor
    public func safetyPresentation(_ viewModel: SafetyViewModel) -> some View {
        modifier(SafetyPresentation(viewModel: viewModel))
    }
}

/// Hosts everything the safety flows present.
@MainActor
struct SafetyPresentation: ViewModifier {

    @Bindable var viewModel: SafetyViewModel

    func body(content: Content) -> some View {
        content
            .modifier(
                BlockConfirmationModifier(
                    confirmation: $viewModel.pendingBlock,
                    onConfirm: { Task { await viewModel.confirmBlock() } },
                    onCancel: { viewModel.cancelBlock() }
                )
            )
            .sheet(item: $viewModel.presentedReport) { subject in
                NavigationStack {
                    ReportSheet(viewModel: viewModel.reportViewModel(for: subject))
                }
                .tint(SLColor.primary)
                .presentationDetents([.large])
            }
            .tnToast($viewModel.toast)
    }
}

extension ReportSubject: Identifiable {
    /// Identity is what is being reported, so re-presenting the same subject is
    /// the same sheet rather than a second one stacked on it.
    public var id: String {
        switch self {
        case let .post(id, _, _): return "post:\(id.uuidString)"
        case let .account(target): return "user:\(target.handle)"
        }
    }
}

#Preview("Safety menu") {
    let target = SafetyTarget(handle: "yuki", name: "Yuki Tanaka")
    return VStack(spacing: SLSpacing.xl) {
        SafetyMenuButton(
            actions: SafetyMenuActions(
                target: target,
                isBlocked: false,
                isMuted: false,
                isBusy: false,
                onBlock: {}, onUnblock: {}, onMute: {}, onUnmute: {}, onReport: {}
            )
        )
        SafetyMenuButton(
            actions: SafetyMenuActions(
                target: target,
                isBlocked: true,
                isMuted: false,
                isBusy: false,
                onBlock: {}, onUnblock: {}, onMute: {}, onUnmute: {}, onReport: {}
            )
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
    .preferredColorScheme(.dark)
}
