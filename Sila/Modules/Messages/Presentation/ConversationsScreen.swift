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
    /// Where "New message" gets its people.
    private let people: PeopleDirectory?
    private let viewerHandle: String
    @State private var isPicking = false

    public init(
        viewModel: ConversationsViewModel,
        onOpen: @escaping @MainActor (Conversation) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        people: PeopleDirectory? = nil,
        viewerHandle: String = ""
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onOpenProfile = onOpenProfile
        self.people = people
        self.viewerHandle = viewerHandle
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
        .toolbar {
            if people != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPicking = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("messages.new")))
                    .accessibilityHint(Text(L10n.t("messages.new.a11yHint")))
                    .accessibilityIdentifier("messages.new")
                }
            }
        }
        .sheet(isPresented: $isPicking) {
            if let directory = people {
                PeoplePickerSheet(
                    viewModel: PeoplePickerViewModel(directory: directory, viewerHandle: viewerHandle),
                    onPick: { chosen in
                        // One thread at a time: a message goes to a person,
                        // not to a list. The first tick is the one that counts.
                        guard let person = chosen.first else { return }
                        onOpen(Conversation.draft(with: person))
                    },
                    onClose: { isPicking = false }
                )
            }
        }
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
                    : L10n.t("messages.empty.requests.subtitle"),
                actionTitle: viewModel.folder == .inbox && people != nil ? L10n.t("messages.new") : nil,
                action: viewModel.folder == .inbox && people != nil ? { isPicking = true } : nil
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
            HStack(alignment: .center, spacing: SLSpacing.md) {
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

                        Text(conversation.other.atHandle)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .lineLimit(1)
                            .layoutPriority(-1)

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
                    // Beside the name, not above it: a count floating at the
                    // top of a two-line row reads as belonging to nothing.
                    SLBadge(SLFormat.number(conversation.unreadCount), style: .verified)
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SLColor.textMuted)
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
