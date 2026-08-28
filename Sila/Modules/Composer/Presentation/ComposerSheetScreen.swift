import SwiftUI

/// The composer, presented as a sheet from the tab bar's centre `[+]`.
///
/// Three surfaces in one: a root post (scope picker + thread), a quote (scope
/// picker + the quoted card beneath the editor) and — through
/// ``ReplyComposerBar`` — a reply.
///
/// > Note: The Phase-4 spec's toolbar listed Photo, Video, Poll and Schedule.
/// > Contract v3 has no upload, poll or scheduling endpoint, so those buttons
/// > are absent rather than present-and-dead. The **scope picker** takes the
/// > centre of the screen instead, because on Sila the audience is the
/// > product, not a setting.
@MainActor
public struct ComposerSheetScreen: View {

    @Bindable private var viewModel: ComposerViewModel
    @FocusState private var focusedSegment: UUID?

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
                "Discard this draft?",
                isPresented: Binding(
                    get: { viewModel.isConfirmingDiscard },
                    set: { if !$0 { viewModel.cancelDiscard() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { viewModel.confirmDiscard() }
                Button("Keep writing", role: .cancel) { viewModel.cancelDiscard() }
            } message: {
                Text("Your text will not be saved.")
            }
        }
        .tint(SLColor.primary)
        .interactiveDismissDisabled(viewModel.hasContent)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { viewModel.requestDismiss() }
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityLabel(Text("Cancel"))
                .accessibilityHint(Text(
                    viewModel.hasContent
                        ? "Asks whether to discard this draft"
                        : "Closes the composer"
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
            return "Posts \(viewModel.segments.count) linked posts, one after another"
        }
        return "Publishes this post to \(viewModel.scopeSummary.title)"
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
            Text("\(index + 1) of \(viewModel.segments.count)")
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
                .accessibilityLabel(Text("Remove post \(index + 1)"))
                .accessibilityHint(Text("Deletes this post from the thread"))
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
                Text("Add another post")
                    .font(SLFont.caption)
            }
            .foregroundStyle(SLColor.primary)
            .padding(.vertical, SLSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.metrics(at: viewModel.segments.count - 1).canPost)
        .opacity(viewModel.metrics(at: viewModel.segments.count - 1).canPost ? 1 : 0.4)
        .accessibilityLabel(Text("Add another post to the thread"))
        .accessibilityHint(Text("Each post is published in order, replying to the one before it"))
    }

    private func placeholder(for index: Int) -> String {
        if index > 0 { return "Continue the thread…" }
        switch viewModel.context {
        case .newPost: return "What's happening?"
        case let .reply(post): return "Reply to \(post.author.atHandle)"
        case .quote: return "Add your thoughts"
        }
    }

    // MARK: - Quote

    private func quotedSection(_ post: Post) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text("QUOTING")
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityHidden(true)

            QuotedPostCard(post: post, onTap: {})
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Quoting \(post.author.displayName)"))
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
        .accessibilityLabel(Text("Thread partly posted. \(message)"))
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
@MainActor
struct ComposerEditor: View {

    @Binding var text: String
    let placeholder: String
    let isFocused: Bool

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
                .accessibilityLabel(Text("Post text"))
                .accessibilityHint(Text("Write your post. \(ComposerConstants.characterLimit) characters maximum"))
        }
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
        .accessibilityLabel(Text("Character count"))
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
                                    Text(user.displayName)
                                        .font(SLFont.caption)
                                        .foregroundStyle(SLColor.textPrimary)
                                        .lineLimit(1)
                                    if user.isVerified {
                                        SLVerifiedBadge(size: 12, isPulsing: false)
                                    }
                                    SLCountryBadge(countryCode: user.countryCode)
                                }
                                Text(user.atHandle)
                                    .font(SLFont.micro)
                                    .foregroundStyle(SLColor.textMuted)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SLSpacing.md)
                        .padding(.vertical, SLSpacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Mention \(user.displayName), \(user.atHandle)"))
                    .accessibilityHint(Text("Inserts this handle into your post"))

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
