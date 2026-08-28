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
    private let onStub: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?

    @FocusState private var isFieldFocused: Bool

    /// - Parameters:
    ///   - viewModel: Owns the query and both result lists.
    ///   - onOpenPost: Pushes the detail screen for a post result.
    ///   - onStub: Announces a feature that belongs to a later phase — tapping a
    ///     person still has nowhere to go until profiles ship.
    ///   - onCompose: Opens the composer for a quote. `nil` falls back to the stub.
    public init(
        viewModel: ExploreViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void,
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onStub = onStub
        self.onCompose = onCompose
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField

            if !viewModel.isShowingTrending {
                TNSegmentedControl(
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
        HStack(spacing: TNSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TNColor.textMuted)
                .accessibilityHidden(true)

            TextField(
                "Search TrustNet",
                text: Binding(
                    get: { viewModel.query },
                    set: { viewModel.updateQuery($0) }
                )
            )
            .font(TNFont.body)
            .foregroundStyle(TNColor.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isFieldFocused)
            .onSubmit { viewModel.updateQuery(viewModel.query, immediately: true) }
            .accessibilityLabel(Text("Search TrustNet"))
            .accessibilityHint(Text("Searches posts and people. Type at least two characters"))

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TNColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
                .accessibilityHint(Text("Empties the search field and shows trending tags"))
            }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(TNColor.primary)
                    .accessibilityLabel(Text("Searching"))
            }
        }
        .padding(.horizontal, TNSpacing.lg)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: TNRadius.lg)
                .fill(TNColor.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: TNRadius.lg)
                        .strokeBorder(isFieldFocused ? TNColor.primary : TNColor.stroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, TNSpacing.lg)
        .padding(.vertical, TNSpacing.md)
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
                    .padding(.top, TNSpacing.xxl * 2)
                    .padding(.horizontal, TNSpacing.lg)
            }
        }
    }

    // MARK: - Trending

    private var trendingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: TNSpacing.sm) {
                    Text("TRENDING NOW")
                        .font(TNFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(TNColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, TNSpacing.lg)
                .padding(.bottom, TNSpacing.sm)
                .accessibilityLabel(Text("Trending now, counted across recent posts"))

                if viewModel.isLoadingTrending {
                    VStack(spacing: TNSpacing.lg) {
                        ForEach(0..<5, id: \.self) { _ in
                            TNSkeletonRow(lineCount: 1)
                                .padding(.horizontal, TNSpacing.lg)
                        }
                    }
                    .padding(.top, TNSpacing.sm)
                    .accessibilityLabel(Text("Loading trending tags"))

                } else if let error = viewModel.trendingError {
                    TNEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "Couldn't load trending",
                        subtitle: error,
                        tint: TNColor.danger
                    )
                    .padding(.horizontal, TNSpacing.lg)
                    .padding(.top, TNSpacing.xxl)

                } else if viewModel.trending.isEmpty {
                    TNEmptyState(
                        icon: "number",
                        title: "Nothing trending yet",
                        subtitle: "Tags are counted across the most recent posts. As people start using hashtags, they show up here.",
                        tint: TNColor.textSecondary
                    )
                    .padding(.horizontal, TNSpacing.lg)
                    .padding(.top, TNSpacing.xxl)

                } else {
                    ForEach(Array(viewModel.trending.enumerated()), id: \.element.id) { index, tag in
                        trendingRow(tag, rank: index + 1)
                        TNDivider()
                    }

                    Text("Counted across the most recent posts — not an all-time ranking.")
                        .font(TNFont.micro)
                        .foregroundStyle(TNColor.textMuted)
                        .padding(TNSpacing.lg)
                }
            }
            .padding(.top, TNSpacing.sm)
        }
    }

    private func trendingRow(_ tag: TrendingTag, rank: Int) -> some View {
        Button {
            viewModel.select(tag)
            isFieldFocused = false
        } label: {
            HStack(spacing: TNSpacing.md) {
                Text("\(rank)")
                    .font(TNFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(TNColor.textMuted)
                    .frame(width: 20, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tag.hashtag)
                        .font(TNFont.bodyEmphasis)
                        .foregroundStyle(TNColor.textPrimary)
                        .lineLimit(1)

                    Text("\(tag.postCount) \(tag.postCount == 1 ? "post" : "posts")")
                        .font(TNFont.micro)
                        .foregroundStyle(TNColor.textSecondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TNColor.textMuted)
            }
            .padding(.horizontal, TNSpacing.lg)
            .padding(.vertical, TNSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(tag.hashtag), \(tag.postCount) recent posts, number \(rank)"))
        .accessibilityHint(Text("Searches for this tag"))
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

                        TNDivider()
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(TNColor.primary)
                            .padding(TNSpacing.xl)
                            .accessibilityLabel(Text("Loading more results"))
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)

        case .people:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.people) { user in
                        PersonResultRow(user: user, onTap: { onStub("Profiles") })
                        TNDivider()
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
            TNEmptyState(
                icon: "character.cursor.ibeam",
                title: "Keep typing",
                subtitle: "Search needs at least \(SearchConstants.minimumQueryLength) characters.",
                tint: TNColor.textSecondary
            )

        case let .failed(message):
            TNEmptyState(
                icon: "wifi.exclamationmark",
                title: "Search failed",
                subtitle: message,
                tint: TNColor.danger,
                actionTitle: "Try again",
                action: { viewModel.updateQuery(viewModel.query, immediately: true) }
            )

        case .noResults, .idle:
            TNEmptyState(
                icon: "magnifyingglass",
                title: "No results",
                subtitle: noResultsSubtitle,
                tint: TNColor.textSecondary
            )
        }
    }

    private var noResultsSubtitle: String {
        switch viewModel.tab {
        case .posts:
            return "No post contains “\(viewModel.query)”. Search matches the words in a post, not their meaning."
        case .people:
            return "No handle or display name matches “\(viewModel.query)”."
        }
    }

    private var searchSkeleton: some View {
        ScrollView {
            VStack(spacing: TNSpacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    TNSkeletonRow(lineCount: 2)
                        .padding(.horizontal, TNSpacing.lg)
                }
            }
            .padding(.top, TNSpacing.lg)
        }
        .accessibilityLabel(Text("Searching"))
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
                    onStub("Quote posts")
                    return
                }
                onCompose(.quote(post))
            },
            onMention: { handle in viewModel.updateQuery("@\(handle)", immediately: true) },
            onHashtag: { tag in viewModel.updateQuery("#\(tag)", immediately: true) },
            onOpenQuoted: onOpenPost,
            onStub: onStub
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
            HStack(spacing: TNSpacing.md) {
                TNAvatar(
                    url: user.avatarURL,
                    initials: user.initials,
                    size: .md,
                    isVerified: user.isVerified,
                    displayName: user.displayName
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: TNSpacing.xs) {
                        Text(user.displayName)
                            .font(TNFont.bodyEmphasis)
                            .foregroundStyle(TNColor.textPrimary)
                            .lineLimit(1)

                        if user.isVerified {
                            TNVerifiedBadge(size: 14, isPulsing: false)
                        }

                        TNCountryBadge(countryCode: user.countryCode)
                    }

                    Text(user.atHandle)
                        .font(TNFont.caption)
                        .foregroundStyle(TNColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, TNSpacing.lg)
            .padding(.vertical, TNSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Profiles arrive in a later release"))
    }

    private var accessibilityLabel: String {
        var parts = [user.displayName]
        if user.isVerified { parts.append("verified") }
        if let country = CountryCode.accessibilityLabel(user.countryCode) { parts.append(country) }
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
