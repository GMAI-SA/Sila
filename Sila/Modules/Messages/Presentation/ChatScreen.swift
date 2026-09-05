import SwiftUI

/// One conversation.
///
/// Nothing here says "encrypted", and nothing implies it. The server can read
/// these messages — that is what lets a report about one be acted on — and a
/// lock icon over a channel that is not end-to-end encrypted is the most
/// consequential lie an interface can tell.
@MainActor
public struct ChatScreen: View {

    @Bindable private var viewModel: ChatViewModel
    private let onOpenProfile: @MainActor (String) -> Void
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?

    @FocusState private var isComposing: Bool

    public init(
        viewModel: ChatViewModel,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenProfile = onOpenProfile
        self.safetyMenu = safetyMenu
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .navigationTitle(viewModel.conversation.other.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let safetyMenu,
                   let actions = safetyMenu(SafetyTarget(user: viewModel.conversation.other)) {
                    SafetyMenu(actions: actions)
                }
            }
        }
        .tnScreenBackground()
        .task { await viewModel.load() }
        .tnToast($viewModel.toast)
        .accessibilityIdentifier("chat.screen")
        .confirmationDialog(
            L10n.t("messages.delete.title"),
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("messages.delete.confirm"), role: .destructive) {
                Task { await viewModel.confirmDeletion() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                viewModel.pendingDeletion = nil
            }
        } message: {
            // Says what deletion actually does. The row survives with its text
            // blanked so a report keeps its evidence.
            Text(L10n.t("messages.delete.explanation"))
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SLSpacing.sm) {
                    if !viewModel.canSend {
                        requestBanner
                    }

                    ForEach(viewModel.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) {
                // Newest message in view, the way every messaging app behaves.
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Shown when the thread is a request the viewer has not accepted.
    ///
    /// Readable, not answerable: replying *is* accepting, and doing that
    /// silently would take the decision away from the person the folder exists
    /// to protect.
    private var requestBanner: some View {
        Text(L10n.t("messages.request.banner"))
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SLSpacing.md)
            .background(SLColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
            .padding(.bottom, SLSpacing.sm)
    }

    private func bubble(_ message: DirectMessage) -> some View {
        let mine = viewModel.isMine(message)
        return HStack {
            if mine { Spacer(minLength: SLSpacing.xxl) }

            VStack(alignment: mine ? .trailing : .leading, spacing: SLSpacing.xs) {
                Text(message.text ?? L10n.t("messages.bubble.deleted"))
                    .font(SLFont.body)
                    .italic(message.deleted)
                    .foregroundStyle(
                        message.deleted
                            ? SLColor.textMuted
                            : (mine ? Color(tnHex: 0x02121C) : SLColor.textPrimary)
                    )
                    .multilineTextAlignment(mine ? .trailing : .leading)
                    // Each message keeps its own direction.
                    .environment(
                        \.layoutDirection,
                        TextDirection.resolve(languageCode: nil, text: message.text).layoutDirection
                    )

                Text(RelativeTime.short(message.createdAt))
                    .font(SLFont.caption)
                    .foregroundStyle(mine ? Color(tnHex: 0x02121C).opacity(0.7) : SLColor.textMuted)
            }
            .padding(.horizontal, SLSpacing.md)
            .padding(.vertical, SLSpacing.sm)
            .background(mine ? SLColor.primary : SLColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))
            .contextMenu {
                if mine && !message.deleted {
                    Button(L10n.t("messages.delete.action"), role: .destructive) {
                        viewModel.requestDeletion(of: message)
                    }
                }
            }

            if !mine { Spacer(minLength: SLSpacing.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                mine
                    ? L10n.t("messages.bubble.mine.a11yLabel", message.text ?? "")
                    : L10n.t("messages.bubble.theirs.a11yLabel", viewModel.conversation.other.displayName, message.text ?? "")
            )
        )
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if viewModel.canSend {
            VStack(spacing: 0) {
                SLDivider()

                HStack(alignment: .bottom, spacing: SLSpacing.sm) {
                    TextField(
                        L10n.t("messages.composer.placeholder"),
                        text: $viewModel.draft,
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(SLFont.body)
                    .focused($isComposing)
                    .accessibilityIdentifier("chat.input")

                    if viewModel.isOverLimit {
                        Text(String(viewModel.remaining))
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .accessibilityLabel(Text(L10n.t("messages.composer.overLimit")))
                    }

                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                viewModel.isSendable ? SLColor.primary : SLColor.textMuted
                            )
                    }
                    .disabled(!viewModel.isSendable)
                    .accessibilityIdentifier("chat.send")
                    .accessibilityLabel(Text(L10n.t("messages.composer.send")))
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.sm)
            }
            .background(SLColor.surface1)
        }
    }
}
