import SwiftUI

/// Search and discovery.
///
/// Replaces the Phase-3 placeholder, which said out loud that no search
/// endpoint existed. Contract v3 shipped three (`/search/posts`,
/// `/search/users`, `/explore/trending`), so the screen now shows real results —
/// and still shows nothing at all when there is nothing, rather than filling
/// the space with invented "suggested" content.
@MainActor
public struct ExploreScreen: View {

    @Bindable private var viewModel: ExploreViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    /// Builds the author's own menu for a card — Delete, on your posts only.
    private let ownPost: (@MainActor (Post) -> OwnPostActions?)?

    @FocusState private var isFieldFocused: Bool

    /// - Parameters:
    ///   - viewModel: Owns the query and both result lists.
    ///   - onOpenPost: Pushes the detail screen for a post result.
    ///   - onOpenProfile: Pushes an account's profile. A People result, a
    ///     tapped author and an `@mention` all lead here.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the composer for a quote. `nil` falls back to the stub.
    public init(
        viewModel: ExploreViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onCompose = onCompose
        self.safetyMenu = safetyMenu
        self.ownPost = ownPost
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField

            if !viewModel.isShowingTrending {
                SLSegmentedControl(
                    items: ExploreViewModel.ResultTab.allCases,
                    selection: Binding(
                        get: { viewModel.tab },
                        set: { viewModel.select($0) }
                    ),
                    accessibilityHint: { $0.accessibilityHint },
                    title: { $0.title }
                )
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .task { await viewModel.loadTrending() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SLColor.textMuted)
                .accessibilityHidden(true)

            TextField(
                L10n.t("search.field.placeholder"),
                text: Binding(
                    get: { viewModel.query },
                    set: { viewModel.updateQuery($0) }
                )
            )
            .font(SLFont.body)
            .foregroundStyle(SLColor.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isFieldFocused)
            // A query is content: typing عبدالعزيز on an English phone has to
            // right-align, caret and all, from the first letter.
            .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.query))
            .onSubmit { viewModel.updateQuery(viewModel.query, immediately: true) }
            .accessibilityLabel(Text(L10n.t("search.field.a11yLabel")))
            .accessibilityHint(Text(L10n.t("search.field.a11yHint")))

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("search.field.clear.a11yLabel")))
                .accessibilityHint(Text(L10n.t("search.field.clear.a11yHint")))
            }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(SLColor.primary)
                    .accessibilityLabel(Text(L10n.t("search.status.searching")))
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: SLRadius.lg)
                .fill(SLColor.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: SLRadius.lg)
                        .strokeBorder(isFieldFocused ? SLColor.primary : SLColor.stroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isShowingTrending {
            trendingList
        } else if viewModel.isSearching && !viewModel.hasResults {
            searchSkeleton
        } else if viewModel.hasResults {
            resultsList
        } else {
            ScrollView {
                emptyState
                    .padding(.top, SLSpacing.xxl * 2)
                    .padding(.horizontal, SLSpacing.lg)
            }
        }
    }

    // MARK: - Trending

    private var trendingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SLSpacing.sm) {
                    Text(L10n.t("search.trending.sectionHeader"))
                        .font(SLFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(SLColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.bottom, SLSpacing.sm)
                .accessibilityLabel(Text(L10n.t("search.trending.section.a11yLabel")))

                if viewModel.isLoadingTrending {
                    VStack(spacing: SLSpacing.lg) {
                        ForEach(0..<5, id: \.self) { _ in
                            SLSkeletonRow(lineCount: 1)
                                .padding(.horizontal, SLSpacing.lg)
                        }
                    }
                    .padding(.top, SLSpacing.sm)
                    .accessibilityLabel(Text(L10n.t("search.trending.loading.a11yLabel")))

                } else if let error = viewModel.trendingError {
                    SLEmptyState(
                        icon: "wifi.exclamationmark",
                        title: L10n.t("search.trending.failed.title"),
                        subtitle: error,
                        tint: SLColor.danger
                    )
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.top, SLSpacing.xxl)

                } else if viewModel.trending.isEmpty {
                    SLEmptyState(
                        icon: "number",
                        title: L10n.t("search.trending.empty.title"),
                        subtitle: L10n.t("search.trending.empty.subtitle"),
                        tint: SLColor.textSecondary
                    )
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.top, SLSpacing.xxl)

                } else {
                    ForEach(Array(viewModel.trending.enumerated()), id: \.element.id) { index, tag in
                        trendingRow(tag, rank: index + 1)
                        SLDivider()
                    }

                    Text(L10n.t("search.trending.footnote"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .padding(SLSpacing.lg)
                }
            }
            .padding(.top, SLSpacing.sm)
        }
    }

    private func trendingRow(_ tag: TrendingTag, rank: Int) -> some View {
        Button {
            viewModel.select(tag)
            isFieldFocused = false
        } label: {
            HStack(spacing: SLSpacing.md) {
                // A rank is a position, not a quantity: left-to-right in both
                // languages, like a chart placing.
                Text(SLFormat.number(rank))
                    .font(SLFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(SLColor.textMuted)
                    .frame(width: 20, alignment: .leading)
                    .slContentDirection(.leftToRight)

                VStack(alignment: .leading, spacing: 2) {
                    // A hashtag is written by whoever coined it — #الرياض and
                    // #riyadh sit in the same list and read opposite ways.
                    Text(tag.hashtag)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                        .slContentDirection(
                            TextDirection.resolve(languageCode: nil, text: tag.hashtag)
                        )

                    Text(L10n.plural("search.trending.postCount", tag.postCount))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textSecondary)
                }

                Spacer(minLength: 0)

                // `.forward`, not `.right`: the disclosure has to point at the
                // edge the row opens toward, which flips in Arabic.
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SLColor.textMuted)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t(
            "search.trending.row.a11yLabel",
            tag.hashtag,
            L10n.plural("search.trending.row.a11yPostCount", tag.postCount),
            SLFormat.number(rank)
        )))
        .accessibilityHint(Text(L10n.t("search.trending.row.a11yHint")))
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        switch viewModel.tab {
        case .posts:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.posts) { post in
                        PostCardView(post: post, actions: actions(for: post))
                            .task { await viewModel.loadMoreIfNeeded(currentPost: post) }

                        SLDivider()
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(SLColor.primary)
                            .padding(SLSpacing.xl)
                            .accessibilityLabel(Text(L10n.t("search.results.loadingMore.a11yLabel")))
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)

        case .people:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.people) { user in
                        PersonResultRow(user: user, onTap: { onOpenProfile(user.handle) })
                        SLDivider()
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.emptyKind {
        case .queryTooShort:
            SLEmptyState(
                icon: "character.cursor.ibeam",
                title: L10n.t("search.empty.tooShort.title"),
                subtitle: L10n.plural("search.empty.tooShort.subtitle", SearchConstants.minimumQueryLength),
                tint: SLColor.textSecondary
            )

        case let .failed(message):
            SLEmptyState(
                icon: "wifi.exclamationmark",
                title: L10n.t("search.empty.failed.title"),
                subtitle: message,
                tint: SLColor.danger,
                actionTitle: L10n.t("search.empty.failed.action"),
                action: { viewModel.updateQuery(viewModel.query, immediately: true) }
            )

        case .noResults, .idle:
            SLEmptyState(
                icon: "magnifyingglass",
                title: L10n.t("search.empty.noResults.title"),
                subtitle: noResultsSubtitle,
                tint: SLColor.textSecondary
            )
        }
    }

    /// The query is quoted back at the user inside a sentence — the one place
    /// on this screen where their own text lands in the middle of ours, so it
    /// goes through `String(format:)` and gets isolated rather than dragging
    /// the closing quote mark to the wrong end.
    private var noResultsSubtitle: String {
        switch viewModel.tab {
        case .posts:
            return L10n.t("search.empty.noResults.posts", viewModel.query)
        case .people:
            return L10n.t("search.empty.noResults.people", viewModel.query)
        }
    }

    private var searchSkeleton: some View {
        ScrollView {
            VStack(spacing: SLSpacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    SLSkeletonRow(lineCount: 2)
                        .padding(.horizontal, SLSpacing.lg)
                }
            }
            .padding(.top, SLSpacing.lg)
        }
        .accessibilityLabel(Text(L10n.t("search.status.searching")))
    }

    // MARK: - Card wiring

    private func actions(for post: Post) -> PostCardActions {
        PostCardActions(
            onOpen: onOpenPost,
            onLike: { post in Task { await viewModel.toggleLike(post) } },
            onRepost: { post in Task { await viewModel.toggleRepost(post) } },
            onBookmark: { post in Task { await viewModel.toggleBookmark(post) } },
            // Replying happens on the detail screen, where the whole thread and
            // the reply bar are.
            onReply: onOpenPost,
            onReplyBlocked: { post in viewModel.replyBlocked(post) },
            onQuote: { post in
                guard let onCompose else {
                    onStub(MainTabView.StubFeature.quotePosts)
                    return
                }
                onCompose(.quote(post))
            },
            // A tapped `@mention` opens the person, not a search for their
            // name — the same thing it does in every other post on the app.
            // `#hashtags` still search, because a tag is a query and nothing else.
            onMention: { handle in onOpenProfile(handle) },
            onHashtag: { tag in viewModel.updateQuery("#\(tag)", immediately: true) },
            onOpenQuoted: onOpenPost,
            onOpenAuthor: { author in onOpenProfile(author.handle) },
            onStub: onStub,
            safetyMenu: safetyMenu,
            ownPost: ownPost
        )
    }
}

// MARK: - Person row

/// One account in the People results.
///
/// Shows the verified checkmark and the country flag exactly as a post header
/// does — and shows neither when the account has not earned them.
@MainActor
struct PersonResultRow: View {

    let user: UserSummary
    let onTap: @MainActor () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: SLSpacing.md) {
                SLAvatar(
                    url: user.avatarURL,
                    initials: user.initials,
                    size: .md,
                    isVerified: user.isVerified,
                    displayName: user.displayName
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SLSpacing.xs) {
                        // Somebody's display name is theirs, not ours: an
                        // Arabic name in an English result list and a Latin
                        // name in an Arabic one each read their own way.
                        Text(user.displayName)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                            .slContentDirection(
                                TextDirection.resolve(languageCode: nil, text: user.displayName)
                            )

                        if user.isVerified {
                            SLVerifiedBadge(size: 14, isPulsing: false)
                        }

                        SLCountryBadge(countryCode: user.countryCode)
                    }

                    // Handles are always Latin; pinning the direction keeps the
                    // "@" attached to the front of the name in an Arabic row.
                    Text(user.atHandle)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(1)
                        .slContentDirection(.leftToRight)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(L10n.t("search.person.row.a11yHint")))
    }

    private var accessibilityLabel: String {
        var parts = [user.displayName]
        if user.isVerified { parts.append(L10n.t("search.person.row.a11yVerified")) }
        if let country = CountryCode.accessibilityLabel(user.countryCode, locale: L10n.locale) {
            parts.append(country)
        }
        parts.append(user.atHandle)
        return parts.joined(separator: ". ")
    }
}

#Preview("Explore — trending") {
    ExploreScreen(
        viewModel: ExploreViewModel(
            search: SearchServiceMock(scenario: .populated),
            feed: FeedServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        ),
        onOpenPost: { _ in },
        onStub: { _ in }
    )
    .preferredColorScheme(.dark)
}

#Preview("Explore — nothing indexed") {
    ExploreScreen(
        viewModel: ExploreViewModel(
            search: SearchServiceMock(scenario: .empty),
            feed: FeedServiceMock(scenario: .empty),
            analytics: RecordingAnalyticsClient()
        ),
        onOpenPost: { _ in },
        onStub: { _ in }
    )
    .preferredColorScheme(.dark)
}
