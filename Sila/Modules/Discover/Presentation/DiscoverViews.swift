import SwiftUI

// MARK: - Live now rail

/// Rooms that are live right now, as a horizontal rail. Draws nothing at all
/// when nothing is live — an empty rail is a shelf with a sign saying "empty".
@MainActor
public struct LiveNowRail: View {

    private let rooms: [VoiceRoom]
    private let onOpen: @MainActor (VoiceRoom) -> Void

    public init(rooms: [VoiceRoom], onOpen: @escaping @MainActor (VoiceRoom) -> Void) {
        self.rooms = rooms
        self.onOpen = onOpen
    }

    public var body: some View {
        if !rooms.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HubHeader(title: L10n.t("discover.live.title"), icon: "dot.radiowaves.left.and.right")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SLSpacing.md) {
                        ForEach(rooms) { room in
                            Button { onOpen(room) } label: { tile(room) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("discover.live.room")
                        }
                    }
                    .padding(.horizontal, SLSpacing.lg)
                }
            }
            .padding(.vertical, SLSpacing.sm)
        }
    }

    private func tile(_ room: VoiceRoom) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            HStack(spacing: SLSpacing.xs) {
                Circle().fill(SLColor.danger).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(L10n.t("discover.live.badge"))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.danger)
            }
            Text(room.title)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: room.title))
            Spacer(minLength: 0)
            HStack(spacing: SLSpacing.xs) {
                SLAvatar(url: room.host.avatarURL, initials: room.host.initials, size: .sm,
                         isVerified: room.host.isVerified, displayName: room.host.displayName)
                Text(L10n.plural("discover.live.listeners", room.listenerCount + room.speakerCount))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(SLSpacing.md)
        .frame(width: 200, height: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous).fill(SLColor.surface1))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous).strokeBorder(SLColor.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(L10n.t("discover.live.hint")))
    }
}

/// A section title on the hub.
struct HubHeader: View {
    let title: String
    let icon: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SLColor.primary)
                .accessibilityHidden(true)
            Text(title)
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.primary)
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - The hub

/// The Explore idle screen's sections, in the plan's order: Live now →
/// Subjects → Trending in your subjects → Needs a reply → People to follow.
/// Each draws from its own ``HubSection`` and hides itself when it failed or
/// is empty.
@MainActor
public struct DiscoverHubSections: View {

    @Bindable private var viewModel: DiscoverHubViewModel
    private let onOpenRoom: @MainActor (VoiceRoom) -> Void
    private let onPinSubject: (@MainActor (String) -> Void)?
    private let onOpenNeedsReply: @MainActor () -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let postActions: @MainActor (Post) -> PostCardActions

    public init(
        viewModel: DiscoverHubViewModel,
        onOpenRoom: @escaping @MainActor (VoiceRoom) -> Void,
        onPinSubject: (@MainActor (String) -> Void)?,
        onOpenNeedsReply: @escaping @MainActor () -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void,
        postActions: @escaping @MainActor (Post) -> PostCardActions
    ) {
        self.viewModel = viewModel
        self.onOpenRoom = onOpenRoom
        self.onPinSubject = onPinSubject
        self.onOpenNeedsReply = onOpenNeedsReply
        self.onOpenProfile = onOpenProfile
        self.postActions = postActions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            LiveNowRail(rooms: viewModel.liveRooms, onOpen: onOpenRoom)
            subjectsSection
            trendingSection
            needsReplySection
            peopleSection
        }
        .task { await viewModel.loadIfNeeded() }
    }

    // MARK: Subjects

    @ViewBuilder
    private var subjectsSection: some View {
        if let onPinSubject, let topics = viewModel.subjects.value, !topics.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HubHeader(title: L10n.t("discover.subjects.title"), icon: "square.grid.2x2")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SLSpacing.sm) {
                        ForEach(topics) { topic in
                            Button {
                                viewModel.track(section: "subject")
                                onPinSubject(topic.id)
                            } label: {
                                Label(topic.label, systemImage: TopicIcon.symbol(for: topic.id))
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.textPrimary)
                                    .padding(.horizontal, SLSpacing.md)
                                    .padding(.vertical, SLSpacing.sm)
                                    .background(Capsule().fill(SLColor.surface1))
                                    .overlay(Capsule().strokeBorder(SLColor.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text(L10n.t("discover.subjects.hint")))
                        }
                    }
                    .padding(.horizontal, SLSpacing.lg)
                }
            }
        }
    }

    // MARK: Trending in your subjects

    @ViewBuilder
    private var trendingSection: some View {
        if let sections = viewModel.trending.value, !sections.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HubHeader(title: L10n.t("discover.trending.title"), icon: "flame")
                ForEach(sections) { section in
                    Text(section.title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .padding(.horizontal, SLSpacing.lg)
                    ForEach(section.posts.prefix(3)) { post in
                        PostCardView(post: post, actions: postActions(post))
                        SLDivider()
                    }
                }
            }
        }
    }

    // MARK: Needs a reply

    @ViewBuilder
    private var needsReplySection: some View {
        if let posts = viewModel.needsReply.value, !posts.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HubHeader(
                    title: L10n.t("discover.needsReply.title"),
                    icon: "bubble.left.and.exclamationmark.bubble.right",
                    actionTitle: L10n.t("discover.seeAll"),
                    action: {
                        viewModel.track(section: "needs_reply")
                        onOpenNeedsReply()
                    }
                )
                ForEach(posts.prefix(DiscoverHubViewModel.needsReplyPreview)) { post in
                    NeedsReplyCard(post: post, actions: postActions(post))
                    SLDivider()
                }
            }
        }
    }

    // MARK: People to follow

    @ViewBuilder
    private var peopleSection: some View {
        if let people = viewModel.people.value, !people.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HubHeader(title: L10n.t("discover.people.title"), icon: "person.2")
                ForEach(people) { person in
                    PersonSuggestionRow(
                        person: person,
                        isFollowed: viewModel.followed.contains(person.id),
                        isBusy: viewModel.following.contains(person.id),
                        onOpen: { onOpenProfile(person.user.handle) },
                        onFollow: { Task { await viewModel.follow(person) } }
                    )
                }
            }
        }
    }
}

/// A post with the line that makes it an invitation.
struct NeedsReplyCard: View {
    let post: Post
    let actions: PostCardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostCardView(post: post, actions: actions)
            Label(L10n.t("discover.needsReply.cta"), systemImage: "arrowshape.turn.up.left")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.primary)
                .padding(.leading, SLSpacing.lg + 56)
                .padding(.bottom, SLSpacing.sm)
                .accessibilityHidden(true)
        }
    }
}

/// One suggested person: who, why, and a Follow button.
struct PersonSuggestionRow: View {
    let person: SuggestedPerson
    let isFollowed: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onFollow: () -> Void

    var body: some View {
        HStack(spacing: SLSpacing.md) {
            Button(action: onOpen) {
                HStack(spacing: SLSpacing.md) {
                    SLAvatar(url: person.user.avatarURL, initials: person.user.initials, size: .md,
                             isVerified: person.user.isVerified, displayName: person.user.displayName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.user.displayName)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                        Text(person.reason.label)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button(action: onFollow) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.t(isFollowed ? "discover.people.following" : "discover.people.follow"))
                    }
                }
                .font(SLFont.caption)
                .foregroundStyle(isFollowed ? SLColor.textSecondary : SLColor.primary)
                .padding(.horizontal, SLSpacing.md)
                .frame(height: 32)
                .overlay(Capsule().strokeBorder(isFollowed ? SLColor.stroke : SLColor.primary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isFollowed || isBusy)
            .accessibilityIdentifier("discover.people.follow")
        }
        .padding(.horizontal, SLSpacing.lg)
    }
}

// MARK: - Needs a reply, the full list

/// Pages through `GET /discover/needs-reply`.
@MainActor
@Observable
public final class NeedsReplyViewModel {
    public private(set) var posts: [Post] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: String?
    private var cursor: String?
    private var hasMore = true
    private let service: DiscoverServiceProtocol

    public init(service: DiscoverServiceProtocol) {
        self.service = service
    }

    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    public func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await service.fetchNeedsReply(cursor: nil)
            posts = page.posts
            cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            hasLoaded = true
        } catch {
            let wrapped = APIError.wrapping(error)
            if !wrapped.isCancellation {
                self.error = wrapped.userMessage
                hasLoaded = true
            }
        }
    }

    public func loadMoreIfNeeded(current post: Post) async {
        guard hasMore, !isLoading, let cursor, post.id == posts.last?.id else { return }
        isLoading = true
        defer { isLoading = false }
        if let page = try? await service.fetchNeedsReply(cursor: cursor) {
            let known = Set(posts.map(\.id))
            posts += page.posts.filter { !known.contains($0.id) }
            self.cursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
        }
    }

    public func remove(postId: UUID) {
        posts.removeAll { $0.id == postId }
    }
}

/// "Needs a reply": open doors, each of which closes when somebody answers.
@MainActor
public struct NeedsReplyScreen: View {
    @Bindable private var viewModel: NeedsReplyViewModel
    private let actions: @MainActor (Post) -> PostCardActions

    public init(viewModel: NeedsReplyViewModel, actions: @escaping @MainActor (Post) -> PostCardActions) {
        self.viewModel = viewModel
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.posts.isEmpty {
                VStack(spacing: SLSpacing.lg) {
                    ForEach(0..<4, id: \.self) { _ in SLSkeletonRow(lineCount: 3).padding(.horizontal, SLSpacing.lg) }
                }
                .padding(.top, SLSpacing.lg)
            } else if let error = viewModel.error, viewModel.posts.isEmpty {
                SLEmptyState(
                    icon: "wifi.exclamationmark",
                    title: L10n.t("discover.needsReply.error"),
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: L10n.t("feed.error.retry"),
                    action: { Task { await viewModel.reload() } }
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl)
            } else if viewModel.hasLoaded && viewModel.posts.isEmpty {
                SLEmptyState(
                    icon: "checkmark.bubble",
                    title: L10n.t("discover.needsReply.empty.title"),
                    subtitle: L10n.t("discover.needsReply.empty.subtitle"),
                    tint: SLColor.textSecondary
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl)
            } else {
                LazyVStack(spacing: 0) {
                    Text(L10n.t("discover.needsReply.explainer"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .padding(SLSpacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(viewModel.posts) { post in
                        NeedsReplyCard(post: post, actions: actions(post))
                            .task { await viewModel.loadMoreIfNeeded(current: post) }
                        SLDivider()
                    }
                }
            }
        }
        .refreshable { await viewModel.reload() }
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("discover.needsReply.title"))
        .task { await viewModel.load() }
    }
}
