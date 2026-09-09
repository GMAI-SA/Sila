import SwiftUI

/// One community: who it is, the door, and what is inside.
@MainActor
public struct CommunityScreen: View {

    @State private var viewModel: CommunityViewModel
    @State private var isInviting = false
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onOpenRoom: (@MainActor (VoiceRoom) -> Void)?
    private let onCompose: (@MainActor (Community) -> Void)?
    private let postActions: (@MainActor (Post) -> PostCardActions)?
    private let people: PeopleDirectory?
    private let viewerHandle: String

    public init(
        viewModel: CommunityViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onOpenRoom: (@MainActor (VoiceRoom) -> Void)? = nil,
        onCompose: (@MainActor (Community) -> Void)? = nil,
        postActions: (@MainActor (Post) -> PostCardActions)? = nil,
        people: PeopleDirectory? = nil,
        viewerHandle: String = ""
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onOpenRoom = onOpenRoom
        self.onCompose = onCompose
        self.postActions = postActions
        self.people = people
        self.viewerHandle = viewerHandle
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let community = viewModel.community {
                    header(community)
                    if community.canView {
                        SLSegmentedControl(
                            items: CommunityViewModel.Tab.allCases,
                            selection: $viewModel.tab,
                            title: { $0.title }
                        )
                        .padding(.horizontal, SLSpacing.lg)
                        .padding(.bottom, SLSpacing.md)
                        contents(community)
                    } else {
                        SLEmptyState(
                            icon: "lock.fill",
                            title: L10n.t("communities.private.title"),
                            subtitle: L10n.t("communities.private.message"),
                            tint: SLColor.textSecondary
                        )
                        .padding(SLSpacing.lg)
                    }
                } else if let error = viewModel.loadError {
                    SLEmptyState(
                        icon: "exclamationmark.triangle",
                        title: error,
                        subtitle: L10n.t("feed.error.pullToRefresh"),
                        tint: SLColor.textSecondary,
                        actionTitle: L10n.t("feed.error.retry"),
                        action: { Task { await viewModel.load() } }
                    )
                    .padding(SLSpacing.lg)
                } else {
                    SLSkeletonRow(lineCount: 4).padding(SLSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: viewModel.community?.name ?? CommunityCopy.title)
        .toolbar {
            if viewModel.community?.isAdmin == true, people != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isInviting = true
                    } label: {
                        Image(systemName: "person.badge.plus").foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("communities.invite")))
                }
            }
        }
        .sheet(isPresented: $isInviting) {
            if let directory = people {
                PeoplePickerSheet(
                    viewModel: PeoplePickerViewModel(directory: directory, viewerHandle: viewerHandle),
                    onPick: { chosen in Task { await viewModel.invite(chosen) } },
                    onClose: { isInviting = false }
                )
            }
        }
        .task { await viewModel.load() }
        .task(id: viewModel.tab) { await viewModel.loadTabContents() }
        .refreshable { await viewModel.load() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Header

    private func header(_ community: Community) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.md) {
                SLAvatar(
                    url: community.avatarURL,
                    initials: String(community.name.prefix(2)).uppercased(),
                    size: .lg,
                    isVerified: false,
                    displayName: community.name
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(community.name)
                        .font(SLFont.displayM)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: community.name))
                    Text(community.address)
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(1)
                    Text(community.summary)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
                Spacer(minLength: 0)
            }

            if let about = community.description {
                Text(about)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: about))
            }

            HStack(spacing: SLSpacing.sm) {
                SLChip(community.scopePresentation.label, icon: community.scopePresentation.icon)
                if community.visibility == .private {
                    SLChip(CommunityCopy.privateBadge, icon: "lock.fill")
                }
                if community.verifiedOnly {
                    SLChip(L10n.t("communities.badge.verifiedOnly"), icon: "checkmark.seal.fill")
                }
                Spacer(minLength: 0)
            }

            door(community)

            if community.isMember, !community.canPost, let why = community.postRefusal {
                // Inside, but not writing here: said plainly rather than left
                // to a composer that refuses at the end.
                Label(why, systemImage: "info.circle")
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SLSpacing.lg)
    }

    @ViewBuilder
    private func door(_ community: Community) -> some View {
        HStack(spacing: SLSpacing.md) {
            if let title = viewModel.doorTitle {
                SLButton(
                    title,
                    variant: community.isMember ? .secondary : .primary,
                    size: .compact,
                    icon: community.isMember ? "checkmark" : (community.isPending ? "clock" : "plus"),
                    isLoading: viewModel.isJoining,
                    isEnabled: !community.isPending,
                    asyncAction: { await viewModel.toggleMembership() }
                )
            } else if let why = community.joinRefusal {
                Label(why, systemImage: "lock.fill")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if community.canPost, let onCompose {
                SLButton(
                    L10n.t("communities.post"),
                    variant: .primary,
                    size: .compact,
                    icon: "square.and.pencil",
                    action: { onCompose(community) }
                )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private func contents(_ community: Community) -> some View {
        switch viewModel.tab {
        case .posts:
            if viewModel.posts.isEmpty {
                SLEmptyState(
                    icon: "text.bubble",
                    title: L10n.t("communities.posts.empty.title"),
                    subtitle: L10n.t("communities.posts.empty.message"),
                    tint: SLColor.textSecondary
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.xl)
            } else {
                ForEach(viewModel.posts) { post in
                    PostCardView(post: post, actions: actions(for: post))
                        .task { await viewModel.loadMoreIfNeeded(currentPost: post) }
                    SLDivider()
                }
            }

        case .rooms:
            if viewModel.rooms.isEmpty {
                SLEmptyState(
                    icon: "mic",
                    title: L10n.t("communities.rooms.empty.title"),
                    subtitle: L10n.t("communities.rooms.empty.message"),
                    tint: SLColor.textSecondary
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.xl)
            } else {
                ForEach(viewModel.rooms) { room in
                    RoomCardView(room: room, onTap: { onOpenRoom?(room) })
                        .padding(.horizontal, SLSpacing.lg)
                        .padding(.bottom, SLSpacing.md)
                }
            }

        case .members:
            if !viewModel.pending.isEmpty {
                sectionHeader(L10n.t("communities.members.waiting"), count: viewModel.pending.count)
                ForEach(viewModel.pending) { member in
                    memberRow(member, waiting: true)
                }
            }
            sectionHeader(L10n.t("communities.tab.members"), count: viewModel.members.count)
            ForEach(viewModel.members) { member in
                memberRow(member, waiting: false)
            }

        case .about:
            VStack(alignment: .leading, spacing: SLSpacing.md) {
                if !community.rules.isEmpty {
                    Text(L10n.t("communities.rules.heading").uppercased())
                        .font(SLFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(SLColor.textSecondary)
                    ForEach(Array(community.rules.enumerated()), id: \.offset) { index, rule in
                        HStack(alignment: .top, spacing: SLSpacing.sm) {
                            Text(SLFormat.number(index + 1))
                                .font(SLFont.mono)
                                .foregroundStyle(SLColor.textMuted)
                            Text(rule)
                                .font(SLFont.body)
                                .foregroundStyle(SLColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(L10n.t("communities.about.opened", RelativeTime.accessible(community.createdAt)))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)

                Button {
                    onOpenProfile(community.owner.handle)
                } label: {
                    HStack(spacing: SLSpacing.sm) {
                        SLAvatar(
                            url: community.owner.avatarURL,
                            initials: community.owner.initials,
                            size: .sm,
                            isVerified: community.owner.isVerified,
                            displayName: community.owner.displayName
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.t("communities.about.runBy"))
                                .font(SLFont.micro)
                                .foregroundStyle(SLColor.textMuted)
                            Text(community.owner.displayName)
                                .font(SLFont.bodyEmphasis)
                                .foregroundStyle(SLColor.textPrimary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.bottom, SLSpacing.xl)
        }
    }

    /// A card's actions, or the bare open when none were supplied.
    private func actions(for post: Post) -> PostCardActions {
        if let postActions { return postActions(post) }
        return PostCardActions(onOpen: onOpenPost)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            Text(SLFormat.number(count))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.sm)
        .accessibilityAddTraits(.isHeader)
    }

    private func memberRow(_ member: CommunityMember, waiting: Bool) -> some View {
        HStack(spacing: SLSpacing.md) {
            Button {
                onOpenProfile(member.user.handle)
            } label: {
                HStack(spacing: SLSpacing.md) {
                    SLAvatar(
                        url: member.user.avatarURL,
                        initials: member.user.initials,
                        size: .md,
                        isVerified: member.user.isVerified,
                        displayName: member.user.displayName
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(member.user.displayName)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: SLSpacing.xs) {
                            Text(member.user.atHandle)
                                .font(SLFont.micro)
                                .foregroundStyle(SLColor.textMuted)
                                .lineLimit(1)
                            if member.role.isAdmin {
                                SLBadge(member.role.title, style: .neutral)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if waiting {
                SLButton(
                    L10n.t("communities.members.approve"),
                    variant: .primary,
                    size: .compact,
                    asyncAction: { await viewModel.approve(member) }
                )
                Button {
                    Task { await viewModel.decline(member) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SLColor.textSecondary)
                        .frame(width: 36, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(L10n.t("communities.members.decline")))
            } else if viewModel.canManage(member) {
                Menu {
                    if viewModel.canSetRole(for: member), member.role == .member {
                        Button {
                            Task { await viewModel.setRole(.admin, for: member) }
                        } label: {
                            Label(L10n.t("communities.members.makeAdmin"), systemImage: "star")
                        }
                    } else if viewModel.canSetRole(for: member) {
                        Button {
                            Task { await viewModel.setRole(.member, for: member) }
                        } label: {
                            Label(L10n.t("communities.members.removeAdmin"), systemImage: "star.slash")
                        }
                    }
                    Button(role: .destructive) {
                        Task { await viewModel.remove(member) }
                    } label: {
                        Label(L10n.t("communities.members.remove"), systemImage: "person.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SLColor.textSecondary)
                        .frame(width: 36, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(L10n.t("communities.members.manage.a11yLabel", member.user.displayName)))
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.sm)
    }
}
