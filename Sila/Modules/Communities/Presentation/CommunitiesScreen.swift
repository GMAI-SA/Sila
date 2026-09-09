import SwiftUI

/// Communities to join, and the ones you are in.
@MainActor
public struct CommunitiesScreen: View {

    @Bindable private var viewModel: CommunitiesViewModel
    private let onOpen: @MainActor (Community) -> Void
    private let onCreate: (@MainActor () -> Void)?

    public init(
        viewModel: CommunitiesViewModel,
        onOpen: @escaping @MainActor (Community) -> Void,
        onCreate: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onCreate = onCreate
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLSegmentedControl(
                items: CommunitiesViewModel.Folder.allCases,
                selection: $viewModel.folder,
                title: { $0.title }
            )
            .padding(.horizontal, SLSpacing.lg)
            .padding(.bottom, SLSpacing.sm)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: CommunityCopy.title)
        .toolbar {
            if let onCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCreate) {
                        Image(systemName: "plus").foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("communities.create")))
                    .accessibilityIdentifier("communities.create")
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load(isRefresh: true) }
        .tnToast($viewModel.toast)
    }

    /// Nothing to show, and the way out of that when there is one.
    @ViewBuilder
    private var emptyState: some View {
        let mine = viewModel.folder == .mine
        let title = mine ? L10n.t("communities.empty.mine.title") : L10n.t("communities.empty.forYou.title")
        let message = mine ? L10n.t("communities.empty.mine.message") : L10n.t("communities.empty.forYou.message")
        if let onCreate {
            SLEmptyState(
                icon: "person.3",
                title: title,
                subtitle: message,
                tint: SLColor.textSecondary,
                actionTitle: L10n.t("communities.create"),
                action: onCreate
            )
        } else {
            SLEmptyState(icon: "person.3", title: title, subtitle: message, tint: SLColor.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            VStack(spacing: SLSpacing.lg) {
                ForEach(0..<3, id: \.self) { _ in
                    SLSkeletonRow(lineCount: 3).padding(.horizontal, SLSpacing.lg)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, SLSpacing.lg)
        } else if let error = viewModel.loadError {
            SLEmptyState(
                icon: "exclamationmark.triangle",
                title: error,
                subtitle: L10n.t("feed.error.pullToRefresh"),
                tint: SLColor.textSecondary,
                actionTitle: L10n.t("feed.error.retry"),
                action: { Task { await viewModel.load(isRefresh: true) } }
            )
            .padding(SLSpacing.lg)
        } else if viewModel.isEmpty {
            emptyState
                .padding(SLSpacing.lg)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.md) {
                    ForEach(viewModel.communities) { community in
                        CommunityCardView(community: community, onTap: { onOpen(community) })
                            .padding(.horizontal, SLSpacing.lg)
                    }
                }
                .padding(.vertical, SLSpacing.md)
            }
        }
    }
}

/// One community in a list.
@MainActor
struct CommunityCardView: View {

    let community: Community
    let onTap: () -> Void

    var body: some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack(spacing: SLSpacing.md) {
                    SLAvatar(
                        url: community.avatarURL,
                        initials: String(community.name.prefix(2)).uppercased(),
                        size: .md,
                        isVerified: false,
                        displayName: community.name
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(community.name)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                            .slContentDirection(TextDirection.resolve(languageCode: nil, text: community.name))
                        Text(community.summary)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if community.isMember {
                        SLBadge(L10n.t("communities.badge.member"), style: .verified)
                    } else if community.isPending {
                        SLBadge(CommunityCopy.requested, style: .neutral)
                    }
                }

                if let about = community.description {
                    Text(about)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: about))
                }

                HStack(spacing: SLSpacing.sm) {
                    SLChip(community.scopePresentation.label, icon: community.scopePresentation.icon)
                    if community.visibility == .private {
                        SLChip(CommunityCopy.privateBadge, icon: "lock.fill")
                    }
                    Spacer(minLength: 0)
                }

                if !community.canJoin, !community.isMember, let why = community.joinRefusal {
                    Label(why, systemImage: "lock.fill")
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("\(community.name). \(community.summary)"))
    }
}
