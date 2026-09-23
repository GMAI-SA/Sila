import SwiftUI

/// The home feed: four independent feeds behind one segmented control.
///
/// Each tab keeps its own posts and cursor, so switching back to a feed the
/// user has already read shows it instantly and issues no request.
@MainActor
public struct HomeScreen: View {

    @Bindable private var viewModel: HomeViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    /// The viewer's verified country, which names the country tab.
    private let countryCode: String?
    private let onOpenProfile: @MainActor (String) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    /// Opens a hashtag's page. A tapped `#tag` in any card leads here.
    private let onOpenHashtag: (@MainActor (String) -> Void)?
    /// Opens a room from a card on a post. `nil` leaves the card inert.
    private let onOpenRoom: (@MainActor (RoomCard) -> Void)?
    private let onOpenPreferences: (@MainActor () -> Void)?
    private let safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    /// Builds the author's own menu for a card — Delete, on your posts only.
    private let ownPost: (@MainActor (Post) -> OwnPostActions?)?
    /// Rooms live right now, drawn as a rail at the top of For You. Empty
    /// draws nothing.
    private let liveRooms: [VoiceRoom]
    private let onOpenLiveRoom: (@MainActor (VoiceRoom) -> Void)?
    /// The question of the week, shown at the top of For You while live.
    private let prompt: WeeklyPrompt?
    private let onAnswerPrompt: (@MainActor (WeeklyPrompt) -> Void)?

    @State private var isShowingOrder = false

    /// - Parameters:
    ///   - viewModel: Owned by ``MainTabView`` so tab state survives navigation.
    ///   - onOpenPost: Pushes the detail screen.
    ///   - onOpenProfile: Pushes an account's profile — a tapped author or an
    ///     `@mention`. `nil` is not offered: the default does nothing, which is
    ///     what every existing caller already had.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the Phase-4 composer. `nil` — the Phase-3 behaviour —
    ///     falls back to the stub toast, which is what
    ///     ``FeatureFlags/composer`` switches off to.
    ///   - onOpenPreferences: Opens the feed-preferences screen. `nil` — the
    ///     default — renders nothing at all, so every existing caller keeps the
    ///     screen it already had.
    ///   - safetyMenu: Builds each card's block / mute / report menu. `nil`
    ///     leaves the card exactly as it was before the safety surface existed.
    public init(
        viewModel: HomeViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        onOpenHashtag: (@MainActor (String) -> Void)? = nil,
        onOpenRoom: (@MainActor (RoomCard) -> Void)? = nil,
        onOpenPreferences: (@MainActor () -> Void)? = nil,
        safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil,
        countryCode: String? = nil,
        liveRooms: [VoiceRoom] = [],
        onOpenLiveRoom: (@MainActor (VoiceRoom) -> Void)? = nil,
        prompt: WeeklyPrompt? = nil,
        onAnswerPrompt: (@MainActor (WeeklyPrompt) -> Void)? = nil
    ) {
        self.prompt = prompt
        self.onAnswerPrompt = onAnswerPrompt
        self.liveRooms = liveRooms
        self.onOpenLiveRoom = onOpenLiveRoom
        self.countryCode = countryCode
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onCompose = onCompose
        self.onOpenHashtag = onOpenHashtag
        self.onOpenRoom = onOpenRoom
        self.onOpenPreferences = onOpenPreferences
        self.safetyMenu = safetyMenu
        self.ownPost = ownPost
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLSegmentedControl(
                items: FeedTab.allCases,
                selection: Binding(
                    get: { viewModel.selectedTab },
                    set: { tab in Task { await viewModel.select(tab) } }
                ),
                accessibilityHint: { $0.accessibilityHint },
                title: { $0.title(countryCode: countryCode) }
            )

            subjectStrip

            TabView(
                selection: Binding(
                    get: { viewModel.selectedTab },
                    set: { tab in Task { await viewModel.select(tab) } }
                )
            ) {
                ForEach(FeedTab.allCases) { tab in
                    feedList(for: tab)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .tnScreenBackground()
        .task { await viewModel.loadIfNeeded(viewModel.selectedTab) }
        .task { await viewModel.loadSubjectsIfNeeded() }
        .tnToast($viewModel.toast)
        .sheet(isPresented: $isShowingOrder) {
            NavigationStack {
                FeedOrderSheet(
                    order: viewModel.forYouOrder,
                    onChoose: { order in
                        isShowingOrder = false
                        Task { await viewModel.setForYouOrder(order) }
                    },
                    onClose: { isShowingOrder = false }
                )
            }
            .presentationDetents([.medium, .large])
            .tint(SLColor.primary)
        }
    }

    /// The top of For You: what is live, and how the list below is ordered —
    /// said plainly, with the other order one tap away.
    @ViewBuilder
    private var forYouHeader: some View {
        if let prompt, let onAnswerPrompt {
            PromptCard(
                prompt: prompt,
                onAnswer: { onAnswerPrompt(prompt) },
                onOpenTag: { onOpenHashtag?(prompt.hashtag) }
            )
        }
        if let onOpenLiveRoom {
            LiveNowRail(rooms: liveRooms, onOpen: onOpenLiveRoom)
        }
        Button {
            isShowingOrder = true
        } label: {
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: viewModel.forYouOrder == .ranked ? "sparkles" : "clock")
                    .accessibilityHidden(true)
                Text(viewModel.forYouOrder.title)
                Image(systemName: "info.circle").accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textSecondary)
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t("feed.order.a11yLabel", viewModel.forYouOrder.title)))
        .accessibilityHint(Text(L10n.t("feed.order.a11yHint")))
        .accessibilityIdentifier("feed.order")
    }

    // MARK: - Subjects

    /// The subject strip, directly under the tabs.
    ///
    /// It sits here rather than behind a settings screen because choosing what
    /// you are reading is part of reading, not a thing you configure once. It
    /// is the same choice on all four tabs: a subject is a statement about
    /// what you want to see, not about which tab you are standing on.
    @ViewBuilder
    private var subjectStrip: some View {
        if !viewModel.subjects.isEmpty {
            SubjectStrip(
                subjects: viewModel.subjects,
                pinned: viewModel.pinnedSubjects,
                onOpenPreferences: onOpenPreferences,
                onSelect: { subject in Task { await viewModel.pin(subject) } }
            )
        }
    }

    // MARK: - One feed

    @ViewBuilder
    private func feedList(for tab: FeedTab) -> some View {
        let state = viewModel.state(for: tab)

        ScrollView {
            if tab == .forYou {
                forYouHeader
            }
            if state.isLoading && !state.isPopulated {
                skeleton
            } else if let empty = state.emptyKind, !state.isPopulated {
                emptyState(empty, tab: tab)
                    .padding(.top, SLSpacing.xxl)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.posts) { post in
                        PostCardView(post: post, actions: actions(for: post))
                            .task { await viewModel.loadMoreIfNeeded(currentPost: post, tab: tab) }

                        SLDivider()
                    }

                    if state.isLoadingMore {
                        ProgressView()
                            .tint(SLColor.primary)
                            .padding(SLSpacing.xl)
                            .accessibilityLabel(Text(L10n.t("feed.loadingMore")))
                    } else if !state.hasMore && state.isPopulated {
                        Text(L10n.t("feed.endOfFeed"))
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textMuted)
                            .padding(SLSpacing.xl)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.refresh(tab) }
    }

    private var skeleton: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SLSkeletonRow(lineCount: 3)
                    .padding(.horizontal, SLSpacing.lg)
            }
        }
        .padding(.top, SLSpacing.lg)
        .accessibilityLabel(Text(L10n.t("feed.loading")))
    }

    @ViewBuilder
    private func emptyState(_ kind: FeedEmptyKind, tab: FeedTab) -> some View {
        switch kind {
        case .noCountry:
            // The 409 the contract documents. It is an explainer, not a failure:
            // the flag comes from verified identity, so there is nothing to
            // retry until verification completes.
            SLEmptyState(
                icon: "flag.slash",
                title: L10n.t("feed.noCountry.title"),
                subtitle: L10n.t("feed.noCountry.subtitle"),
                tint: SLColor.secondary,
                actionTitle: L10n.t("feed.noCountry.action"),
                action: { onStub(MainTabView.StubFeature.identityVerification) }
            )
            .padding(.horizontal, SLSpacing.lg)

        case .noPosts:
            if let subject = viewModel.pinnedSubjectLabel {
                // Not "this timeline is empty" — the timeline is fine, it is
                // the subject that has nothing in it, and the way out is one
                // tap away in the strip they can still see.
                SLEmptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: L10n.t("feed.subject.empty.title", subject),
                    subtitle: L10n.t("feed.subject.empty.subtitle"),
                    tint: SLColor.textSecondary,
                    actionTitle: L10n.t("feed.subject.empty.action"),
                    action: { Task { await viewModel.pin(nil) } }
                )
                .padding(.horizontal, SLSpacing.lg)
            } else {
                SLEmptyState(
                    icon: emptyIcon(for: tab),
                    title: emptyTitle(for: tab),
                    subtitle: emptySubtitle(for: tab),
                    tint: SLColor.textSecondary
                )
                .padding(.horizontal, SLSpacing.lg)
            }

        case let .failed(message):
            SLEmptyState(
                icon: "wifi.exclamationmark",
                title: L10n.t("feed.error.title"),
                subtitle: message,
                tint: SLColor.danger,
                actionTitle: L10n.t("feed.error.retry"),
                action: { Task { await viewModel.refresh(tab) } }
            )
            .padding(.horizontal, SLSpacing.lg)
        }
    }

    private func emptyIcon(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "person.2"
        case .myCountry: return "flag"
        case .international: return "globe"
        case .forYou: return "sparkles"
        }
    }

    private func emptyTitle(for tab: FeedTab) -> String {
        switch tab {
        case .following: return L10n.t("feed.empty.following.title")
        case .myCountry: return L10n.t("feed.empty.myCountry.title")
        case .international: return L10n.t("feed.empty.international.title")
        case .forYou: return L10n.t("feed.empty.forYou.title")
        }
    }

    private func emptySubtitle(for tab: FeedTab) -> String {
        switch tab {
        case .following: return L10n.t("feed.empty.following.subtitle")
        case .myCountry: return L10n.t("feed.empty.myCountry.subtitle")
        case .international: return L10n.t("feed.empty.international.subtitle")
        case .forYou: return L10n.t("feed.empty.forYou.subtitle")
        }
    }

    // MARK: - Card wiring

    /// Opens the composer, or says the feature is not on.
    private func compose(_ context: ComposerContext, fallback: String) {
        guard let onCompose else {
            onStub(fallback)
            return
        }
        onCompose(context)
    }

    private func actions(for post: Post) -> PostCardActions {
        PostCardActions(
            onOpen: onOpenPost,
            onLike: { post in Task { await viewModel.toggleLike(post) } },
            onRepost: { post in Task { await viewModel.toggleRepost(post) } },
            onBookmark: { post in Task { await viewModel.toggleBookmark(post) } },
            onReply: { post in compose(.reply(to: post), fallback: MainTabView.StubFeature.replying) },
            onReplyBlocked: { post in viewModel.replyBlocked(post) },
            onQuote: { post in compose(.quote(post), fallback: MainTabView.StubFeature.quotePosts) },
            onMention: { handle in onOpenProfile(handle) },
            onHashtag: { tag in onOpenHashtag?(tag) },
            onOpenRoom: onOpenRoom,
            onOpenQuoted: onOpenPost,
            onOpenAuthor: { author in onOpenProfile(author.handle) },
            onStub: onStub,
            safetyMenu: safetyMenu,
            ownPost: ownPost
        )
    }
}

#Preview("HomeScreen — populated") {
    HomeScreen(
        viewModel: HomeViewModel(
            service: FeedServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        ),
        onOpenPost: { _ in },
        onStub: { _ in }
    )
    .preferredColorScheme(.dark)
}

#Preview("HomeScreen — no country") {
    HomeScreen(
        viewModel: HomeViewModel(
            service: FeedServiceMock(scenario: .unverifiedNoCountry),
            analytics: RecordingAnalyticsClient(),
            initialTab: .myCountry
        ),
        onOpenPost: { _ in },
        onStub: { _ in }
    )
    .preferredColorScheme(.dark)
}

/// "How this feed is ordered" — the truth, in both languages, and the choice.
///
/// For You used to say it was ranked by engagement and that it learned what
/// you read. Neither was true. What is true: newest first, lifted for the
/// subjects you chose and for posts people are replying to — and nothing else.
@MainActor
struct FeedOrderSheet: View {
    let order: FeedOrder
    let onChoose: @MainActor (FeedOrder) -> Void
    let onClose: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                Text(L10n.t("feed.order.explainer"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(FeedOrder.allCases) { option in
                    Button {
                        onChoose(option)
                    } label: {
                        HStack(alignment: .top, spacing: SLSpacing.md) {
                            Image(systemName: option == order ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(SLColor.primary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(SLFont.bodyEmphasis)
                                    .foregroundStyle(SLColor.textPrimary)
                                Text(L10n.t(option == .ranked ? "feed.order.ranked.detail" : "feed.order.newest.detail"))
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == order ? .isSelected : [])
                    .accessibilityIdentifier("feed.order.\(option.rawValue)")
                }
                Text(L10n.t("feed.order.never"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SLSpacing.lg)
        }
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("feed.order.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("common.done")) { onClose() }
            }
        }
    }
}
