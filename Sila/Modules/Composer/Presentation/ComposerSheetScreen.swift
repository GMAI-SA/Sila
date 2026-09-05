import PhotosUI
import SwiftUI

/// The composer, presented as a sheet from the tab bar's centre `[+]`.
///
/// Three surfaces in one: a root post (scope picker + thread), a quote (scope
/// picker + the quoted card beneath the editor) and — through
/// ``ReplyComposerBar`` — a reply.
///
/// > Note: The Phase-4 spec's toolbar listed Photo, Video, Poll and Schedule.
/// > Photo now exists — the server grew `POST /media/posts`. Video, Poll and
/// > Schedule still have no endpoint behind them, so those buttons stay absent
/// > rather than present-and-dead. The **scope picker** keeps the centre of the
/// > screen, because on Sila the audience is the product, not a setting.
@MainActor
public struct ComposerSheetScreen: View {

    @Bindable private var viewModel: ComposerViewModel
    @FocusState private var focusedSegment: UUID?
    @State private var picked: [PhotosPickerItem] = []

    /// - Parameter viewModel: Owns the draft and the posting chain.
    public init(viewModel: ComposerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    if let message = viewModel.partialFailureMessage {
                        partialFailureBanner(message)
                    }

                    if viewModel.context.showsScopePicker {
                        ScopePickerSection(viewModel: viewModel)
                    }

                    segmentsSection

                    if let quoted = viewModel.context.quotedPost {
                        quotedSection(quoted)
                    }

                    // Only on a root post or a quote. A reply carries no
                    // pictures, because the reply bar is one line by design and
                    // a thumbnail strip inside it would make it something else.
                    if viewModel.context.showsScopePicker {
                        attachmentsSection
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.md)
                .padding(.bottom, SLSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .tnScreenBackground()
            .tnNavigationBar(title: viewModel.context.title)
            .toolbar { toolbarContent }
            .tnToast($viewModel.toast)
            .onAppear { focusedSegment = viewModel.segments.first?.id }
            .confirmationDialog(
                L10n.t("composer.discard.title"),
                isPresented: Binding(
                    get: { viewModel.isConfirmingDiscard },
                    set: { if !$0 { viewModel.cancelDiscard() } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.t("composer.discard.confirm"), role: .destructive) { viewModel.confirmDiscard() }
                Button(L10n.t("composer.discard.keepWriting"), role: .cancel) { viewModel.cancelDiscard() }
            } message: {
                Text(L10n.t("composer.discard.message"))
            }
        }
        .tint(SLColor.primary)
        .interactiveDismissDisabled(viewModel.hasContent)
    }

    // MARK: - Attachments

    /// Picked images, and the button that picks them.
    ///
    /// Each thumbnail carries its own remove button rather than a swipe or a
    /// long press: attaching the wrong photograph is easy and undoing it should
    /// not be a thing you have to discover.
    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            if !viewModel.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SLSpacing.sm) {
                        ForEach(Array(viewModel.attachments.enumerated()), id: \.element) { index, path in
                            ZStack(alignment: .topTrailing) {
                                AsyncImage(url: AppConfig.mediaURL(path)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    SLColor.surface2
                                }
                                .frame(width: 88, height: 88)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))

                                Button {
                                    viewModel.removeAttachment(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(SLColor.textPrimary, SLColor.surface1)
                                }
                                .padding(SLSpacing.xs)
                                .accessibilityLabel(Text(L10n.t("composer.images.remove")))
                            }
                        }
                    }
                }
            }

            HStack(spacing: SLSpacing.sm) {
                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: ComposerConstants.maximumImages - viewModel.attachments.count,
                    matching: .images
                ) {
                    Label(L10n.t("composer.images.add"), systemImage: "photo.on.rectangle")
                        .font(SLFont.caption)
                }
                .disabled(viewModel.attachments.count >= ComposerConstants.maximumImages)
                .accessibilityIdentifier("composer.addImage")

                if viewModel.isUploadingImage {
                    ProgressView()
                        .tint(SLColor.primary)
                        .accessibilityLabel(Text(L10n.t("composer.images.uploading")))
                }
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    // One at a time, so a failure names one picture rather than
                    // abandoning the rest of the selection.
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await viewModel.attach(data)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(L10n.t("common.cancel")) { viewModel.requestDismiss() }
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityIdentifier("composer.cancel")
                .accessibilityLabel(Text(L10n.t("common.cancel")))
                .accessibilityHint(Text(
                    viewModel.hasContent
                        ? L10n.t("composer.cancel.a11yHintDiscard")
                        : L10n.t("composer.cancel.a11yHintClose")
                ))
        }

        ToolbarItem(placement: .topBarTrailing) {
            SLButton(
                viewModel.context.actionTitle,
                variant: .primary,
                size: .compact,
                isLoading: viewModel.isPosting,
                isEnabled: viewModel.canPost,
                accessibilityHint: postHint,
                asyncAction: { await viewModel.post() }
            )
            .frame(width: 88)
        }
    }

    private var postHint: String {
        if viewModel.segments.count > 1 {
            return L10n.plural("composer.post.a11yHintThread", viewModel.segments.count)
        }
        return L10n.t("composer.post.a11yHintSingle", viewModel.scopeSummary.title)
    }

    // MARK: - Segments

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, segment in
                VStack(alignment: .leading, spacing: SLSpacing.sm) {
                    if viewModel.segments.count > 1 {
                        segmentHeader(index: index)
                    }

                    ComposerEditor(
                        text: Binding(
                            get: { viewModel.text(at: index) },
                            set: { viewModel.setText($0, at: index) }
                        ),
                        placeholder: placeholder(for: index),
                        isFocused: focusedSegment == segment.id
                    )
                    .focused($focusedSegment, equals: segment.id)
                    .onTapGesture { viewModel.focusedIndex = index }

                    HStack(spacing: SLSpacing.md) {
                        Spacer(minLength: 0)
                        ComposerCharacterRing(metrics: viewModel.metrics(at: index))
                    }

                    if focusedSegment == segment.id {
                        MentionSuggestionList(viewModel: viewModel)
                    }
                }
                // The thread line, so a multi-segment draft reads as a chain.
                .overlay(alignment: .topLeading) {
                    if viewModel.segments.count > 1, index < viewModel.segments.count - 1 {
                        Rectangle()
                            .fill(SLColor.stroke)
                            .frame(width: 2)
                            .padding(.top, 26)
                            .padding(.leading, 6)
                            .accessibilityHidden(true)
                    }
                }
            }

            if viewModel.allowsThread {
                addSegmentButton
            }
        }
    }

    private func segmentHeader(index: Int) -> some View {
        HStack(spacing: SLSpacing.sm) {
            Text(L10n.t(
                "composer.segment.position",
                SLFormat.number(index + 1),
                SLFormat.number(viewModel.segments.count)
            ))
            .font(SLFont.micro)
            .foregroundStyle(SLColor.textMuted)

            Spacer(minLength: 0)

            if viewModel.segments.count > 1 {
                Button {
                    viewModel.removeSegment(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("composer.segment.remove.a11yLabel", SLFormat.number(index + 1))))
                .accessibilityHint(Text(L10n.t("composer.segment.remove.a11yHint")))
            }
        }
    }

    private var addSegmentButton: some View {
        Button {
            viewModel.addSegment()
            focusedSegment = viewModel.segments.last?.id
        } label: {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                Text(L10n.t("composer.segment.add"))
                    .font(SLFont.caption)
            }
            .foregroundStyle(SLColor.primary)
            .padding(.vertical, SLSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.metrics(at: viewModel.segments.count - 1).canPost)
        .opacity(viewModel.metrics(at: viewModel.segments.count - 1).canPost ? 1 : 0.4)
        .accessibilityLabel(Text(L10n.t("composer.segment.add.a11yLabel")))
        .accessibilityHint(Text(L10n.t("composer.segment.add.a11yHint")))
    }

    private func placeholder(for index: Int) -> String {
        if index > 0 { return L10n.t("composer.placeholder.continueThread") }
        switch viewModel.context {
        case .newPost: return L10n.t("composer.placeholder.newPost")
        case let .reply(post): return L10n.t("composer.placeholder.replyTo", post.author.atHandle)
        case .quote: return L10n.t("composer.placeholder.quote")
        }
    }

    // MARK: - Quote

    private func quotedSection(_ post: Post) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("composer.quote.sectionHeader"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityHidden(true)

            QuotedPostCard(post: post, onTap: {})
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.t("composer.quote.a11yLabel", post.author.displayName)))
    }

    // MARK: - Partial failure

    private func partialFailureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: SLSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(SLColor.warning)
            Text(message)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SLRadius.md)
                .fill(SLColor.warning.opacity(0.1))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("composer.thread.partialBanner.a11yLabel", message)))
    }
}

// MARK: - Sheet host

/// Owns the composer's view model for as long as the sheet is on screen.
///
/// A `.sheet` content closure runs again on every re-render of its host, so
/// building the view model inside it would throw the user's half-typed draft
/// away whenever anything else on the screen changed. `@State` initialised once
/// is what makes the draft survive.
@MainActor
public struct ComposerSheetHost: View {

    @State private var viewModel: ComposerViewModel

    /// - Parameter makeViewModel: Called **once**, when the sheet first appears.
    public init(makeViewModel: () -> ComposerViewModel) {
        self._viewModel = State(initialValue: makeViewModel())
    }

    public var body: some View {
        ComposerSheetScreen(viewModel: viewModel)
    }
}

// MARK: - Editor

/// The text box itself.
///
/// `TextEditor` rather than a multi-line `TextField` so the caret stays put as
/// the draft grows past a few lines, with the system background stripped so the
/// composer's own surface shows through.
///
/// The editor follows **what is being typed**, not what the app is set to. An
/// Arabic sentence written on an English phone is right-aligned with its caret,
/// its placeholder and its full stop on the correct end from the first strong
/// character onward; an empty draft borrows the interface's direction until
/// there is something to read a direction from.
@MainActor
struct ComposerEditor: View {

    @Binding var text: String
    let placeholder: String
    let isFocused: Bool

    /// Recomputed on every keystroke, which is the point: the frame has to flip
    /// the moment the first Arabic — or first Latin — character lands.
    private var direction: TextDirection {
        TextDirection.resolve(languageCode: nil, text: text)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textMuted)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $text)
                .font(SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .accessibilityLabel(Text(L10n.t("composer.editor.a11yLabel")))
                .accessibilityHint(Text(L10n.plural("composer.editor.a11yHint", ComposerConstants.characterLimit)))
        }
        // Applied to the pair, so `.topLeading` puts the placeholder where the
        // caret actually is and the two never sit on opposite edges.
        .slContentDirection(direction)
        .padding(SLSpacing.sm)
        .background(SLColor.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.md)
                .strokeBorder(isFocused ? SLColor.primary : SLColor.stroke, lineWidth: isFocused ? 1.5 : 1)
        )
    }
}

// MARK: - Character ring

/// The 280-character budget as a ring that fills, warns, then goes red.
///
/// The number appears only inside the warning band; a permanent counter is
/// noise, and a silent one lets a user write straight past the limit.
@MainActor
struct ComposerCharacterRing: View {

    let metrics: ComposerTextMetrics

    var body: some View {
        HStack(spacing: SLSpacing.sm) {
            if let counter = metrics.counterText {
                Text(counter)
                    .font(SLFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    // A budget with a minus sign in front of it once it is
                    // breached: clock-style, left-to-right in both languages.
                    .slContentDirection(.leftToRight)
            }

            ZStack {
                Circle()
                    .stroke(SLColor.surface2, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: metrics.isOverLimit ? 1 : metrics.progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            .animation(.easeOut(duration: 0.15), value: metrics.progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("composer.counter.a11yLabel")))
        .accessibilityValue(Text(metrics.accessibilityValue))
    }

    private var tint: Color {
        if metrics.isOverLimit { return SLColor.danger }
        if metrics.isNearLimit { return SLColor.warning }
        return SLColor.primary
    }
}

// MARK: - Mention autocomplete

/// The `@mention` suggestion list, fed by `GET /search/users`.
@MainActor
struct MentionSuggestionList: View {

    let viewModel: ComposerViewModel

    var body: some View {
        if !viewModel.mentionSuggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(viewModel.mentionSuggestions) { user in
                    Button {
                        viewModel.insertMention(user)
                    } label: {
                        HStack(spacing: SLSpacing.md) {
                            SLAvatar(
                                url: user.avatarURL,
                                initials: user.initials,
                                size: .sm,
                                isVerified: user.isVerified,
                                displayName: user.displayName
                            )

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: SLSpacing.xs) {
                                    // Somebody's own name reads in its own
                                    // direction, whatever the app is set to.
                                    Text(user.displayName)
                                        .font(SLFont.caption)
                                        .foregroundStyle(SLColor.textPrimary)
                                        .lineLimit(1)
                                        .slContentDirection(
                                            TextDirection.resolve(languageCode: nil, text: user.displayName)
                                        )
                                    if user.isVerified {
                                        SLVerifiedBadge(size: 12, isPulsing: false)
                                    }
                                    SLCountryBadge(countryCode: user.countryCode)
                                }
                                Text(user.atHandle)
                                    .font(SLFont.micro)
                                    .foregroundStyle(SLColor.textMuted)
                                    .slContentDirection(.leftToRight)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SLSpacing.md)
                        .padding(.vertical, SLSpacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.t(
                        "composer.mention.row.a11yLabel",
                        user.displayName,
                        user.atHandle
                    )))
                    .accessibilityHint(Text(L10n.t("composer.mention.row.a11yHint")))

                    if user.id != viewModel.mentionSuggestions.last?.id {
                        SLDivider()
                    }
                }
            }
            .background(SLColor.surface1)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .strokeBorder(SLColor.stroke, lineWidth: 1)
            )
        }
    }
}

// MARK: - Previews

#Preview("Composer — verified with a country badge") {
    ComposerSheetScreen(
        viewModel: ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            composer: ComposerServiceMock(scenario: .success),
            search: SearchServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}

#Preview("Composer — no country badge") {
    ComposerSheetScreen(
        viewModel: ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(handle: "newcomer", countryCode: nil, isVerified: false),
            composer: ComposerServiceMock(scenario: .unverified),
            search: SearchServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}

#Preview("Composer — quote") {
    ComposerSheetScreen(
        viewModel: ComposerViewModel(
            context: .quote(FeedServiceMock.internationalRoot),
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            composer: ComposerServiceMock(scenario: .success),
            search: SearchServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}
