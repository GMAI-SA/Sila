import SwiftUI

/// The inline reply bar at the bottom of ``PostDetailScreen``.
///
/// Two states, decided by `viewer.can_reply`:
///
/// - **Allowed** — an expanding input, a character ring, `@mention`
///   autocomplete and a Reply button.
/// - **Blocked** — the server's `reply_block_reason` in human language, and no
///   input at all. Rendering a text field that can only ever produce a 403 is
///   the exact dead-end the product refuses to ship.
///
/// There is no scope picker here: a reply inherits its parent's audience, so
/// offering a choice would be theatre.
@MainActor
public struct ReplyComposerBar: View {

    @Bindable private var viewModel: ComposerViewModel
    @FocusState private var isFocused: Bool
    @State private var isExpanded = false

    /// - Parameter viewModel: Built with ``ComposerContext/reply(to:)``.
    public init(viewModel: ComposerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLDivider()

            if let message = viewModel.replyBlockedMessage {
                blocked(message)
            } else {
                composer
            }
        }
        .background(SLColor.surface1)
        .tnToast($viewModel.toast)
    }

    // MARK: - Blocked

    private func blocked(_ message: String) -> some View {
        HStack(alignment: .center, spacing: SLSpacing.md) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundStyle(SLColor.warning)

            Text(message)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("composer.reply.blocked.a11yLabel", message)))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            if isExpanded {
                MentionSuggestionList(viewModel: viewModel)
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.top, SLSpacing.sm)
            }

            HStack(alignment: .bottom, spacing: SLSpacing.md) {
                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    if isExpanded, let handle = viewModel.context.replyTarget?.author.atHandle {
                        // The handle is a Latin run inside an Arabic sentence;
                        // `String(format:)` isolates it so the "@" stays glued
                        // to the name instead of drifting to the far end.
                        Text(L10n.t("composer.reply.replyingTo", handle))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .accessibilityHidden(true)
                    }

                    TextField(
                        placeholder,
                        text: Binding(
                            get: { viewModel.text(at: 0) },
                            set: { viewModel.setText($0, at: 0) }
                        ),
                        axis: .vertical
                    )
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    // Follows the reply being typed, not the app's language.
                    .slContentDirection(draftDirection)
                    .accessibilityLabel(Text(L10n.t("composer.reply.editor.a11yLabel")))
                    .accessibilityHint(Text(L10n.plural("composer.reply.editor.a11yHint", ComposerConstants.characterLimit)))
                }

                if isExpanded {
                    ComposerCharacterRing(metrics: viewModel.metrics(at: 0))
                }

                SLButton(
                    L10n.t("composer.action.reply"),
                    variant: .primary,
                    size: .compact,
                    isLoading: viewModel.isPosting,
                    isEnabled: viewModel.canPost,
                    accessibilityHint: L10n.t("composer.reply.send.a11yHint"),
                    asyncAction: {
                        await viewModel.post()
                        isFocused = false
                    }
                )
                .frame(width: 84)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.md)
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            // Stay open while there is text, so the ring does not vanish under
            // the user's thumb the instant the keyboard dismisses.
            isExpanded = focused || viewModel.hasContent
        }
        .onChange(of: viewModel.hasContent) { _, hasContent in
            isExpanded = hasContent || isFocused
        }
    }

    private var placeholder: String {
        guard let handle = viewModel.context.replyTarget?.author.atHandle else {
            return L10n.t("composer.placeholder.postYourReply")
        }
        return L10n.t("composer.placeholder.replyTo", handle)
    }

    /// The direction of the reply as it is being written — re-read on every
    /// keystroke so an Arabic reply on an English phone flips as soon as the
    /// first letter lands, and an empty field simply follows the interface.
    private var draftDirection: TextDirection {
        TextDirection.resolve(languageCode: nil, text: viewModel.text(at: 0))
    }
}

#Preview("ReplyComposerBar — allowed") {
    VStack {
        Spacer()
        ReplyComposerBar(
            viewModel: ComposerViewModel(
                context: .reply(to: FeedServiceMock.internationalRoot),
                author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
                composer: ComposerServiceMock(),
                search: SearchServiceMock(),
                analytics: RecordingAnalyticsClient()
            )
        )
    }
    .background(SLColor.background)
    .preferredColorScheme(.dark)
}

#Preview("ReplyComposerBar — country-locked") {
    VStack {
        Spacer()
        ReplyComposerBar(
            viewModel: ComposerViewModel(
                context: .reply(to: FeedServiceMock.countryThread),
                author: ComposerAuthor(handle: "yuki", countryCode: "JP", isVerified: true),
                composer: ComposerServiceMock(),
                search: SearchServiceMock(),
                analytics: RecordingAnalyticsClient()
            )
        )
    }
    .background(SLColor.background)
    .preferredColorScheme(.dark)
}
