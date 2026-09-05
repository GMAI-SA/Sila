import SwiftUI

/// The conversation list: an inbox, and a request folder beside it.
///
/// The folders are a segmented control rather than a filter menu because the
/// distinction is the feature. A stranger's first message waits in Requests and
/// is counted apart from the inbox — unsolicited messages are the main
/// harassment vector on a platform where everybody is findable under their real
/// name, and a badge a stranger can raise is that vector with a number on it.
@MainActor
public struct ConversationsScreen: View {

    @Bindable private var viewModel: ConversationsViewModel
    private let onOpen: @MainActor (Conversation) -> Void
    private let onOpenProfile: @MainActor (String) -> Void

    public init(
        viewModel: ConversationsViewModel,
        onOpen: @escaping @MainActor (Conversation) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onOpenProfile = onOpenProfile
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLSegmentedControl(
                items: ConversationsViewModel.Folder.allCases,
                selection: $viewModel.folder,
                accessibilityHint: { $0.accessibilityHint },
                title: { folder in
                    // The requests folder carries its own count in its title:
                    // it is the one number that must not become a badge.
                    folder == .requests && viewModel.counts.requests > 0
                        ? "\(folder.title) (\(viewModel.counts.requests))"
                        : folder.title
                }
            )

            content
        }
        .navigationTitle(L10n.t("messages.title"))
        .tnScreenBackground()
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .tnToast($viewModel.toast)
        .accessibilityIdentifier("messages.screen")
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            VStack(spacing: SLSpacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    SLSkeletonRow(lineCount: 2)
                        .padding(.horizontal, SLSpacing.lg)
                }
                Spacer()
            }
            .padding(.top, SLSpacing.lg)
        } else if viewModel.visible.isEmpty {
            SLEmptyState(
                icon: viewModel.folder == .inbox ? "bubble.left.and.bubble.right" : "tray",
                title: viewModel.folder == .inbox
                    ? L10n.t("messages.empty.inbox.title")
                    : L10n.t("messages.empty.requests.title"),
                subtitle: viewModel.folder == .inbox
                    ? L10n.t("messages.empty.inbox.subtitle")
                    : L10n.t("messages.empty.requests.subtitle")
            )
            .padding(.top, SLSpacing.xxl)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.folder == .requests {
                        requestsNotice
                    }

                    ForEach(viewModel.visible) { conversation in
                        row(conversation)
                        SLDivider()
                    }
                }
            }
        }
    }

    /// Says plainly what the folder is, on the folder itself.
    private var requestsNotice: some View {
        Text(L10n.t("messages.requests.notice"))
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.md)
    }

    private func row(_ conversation: Conversation) -> some View {
        Button {
            onOpen(conversation)
        } label: {
            HStack(alignment: .top, spacing: SLSpacing.md) {
                // Its own button, like every other avatar in the app: tapping a
                // face opens that person.
                Button {
                    onOpenProfile(conversation.other.handle)
                } label: {
                    SLAvatar(
                        url: conversation.other.avatarURL,
                        initials: conversation.other.initials,
                        size: .md,
                        isVerified: conversation.other.isVerified,
                        displayName: conversation.other.displayName
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("messages.avatar.a11yLabel", conversation.other.displayName)))

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    HStack(spacing: SLSpacing.xs) {
                        Text(conversation.other.displayName)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)

                        if conversation.other.isVerified {
                            SLVerifiedBadge()
                        }
                        if let country = conversation.other.countryCode {
                            SLCountryBadge(countryCode: country)
                        }

                        Spacer(minLength: 0)

                        if let date = conversation.lastMessageAt {
                            Text(RelativeTime.short(date))
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textMuted)
                        }
                    }

                    Text(conversation.lastMessage ?? L10n.t("messages.preview.deleted"))
                        .font(SLFont.body)
                        .foregroundStyle(
                            conversation.lastMessage == nil ? SLColor.textMuted : SLColor.textSecondary
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        // A message's own direction, not the interface's: an
                        // Arabic preview must read right-to-left inside an
                        // English UI.
                        .environment(
                            \.layoutDirection,
                            TextDirection.resolve(
                                languageCode: nil,
                                text: conversation.lastMessage
                            ).layoutDirection
                        )

                    if conversation.isRequest {
                        SLButton(
                            L10n.t("messages.request.accept"),
                            variant: .secondary,
                            size: .compact,
                            accessibilityHint: L10n.t("messages.request.accept.hint"),
                            action: { Task { await viewModel.accept(conversation) } }
                        )
                        .padding(.top, SLSpacing.xs)
                    }
                }

                if conversation.unreadCount > 0 {
                    SLBadge(String(conversation.unreadCount), style: .verified)
                }
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("messages.row.\(conversation.other.handle)")
    }
}
