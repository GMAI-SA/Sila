import PhotosUI
import QuickLook
import SwiftUI

/// One conversation.
///
/// Nothing here says "encrypted", and nothing implies it. The server can read
/// these messages — that is what lets a report about one be acted on — and a
/// lock icon over a channel that is not end-to-end encrypted is the most
/// consequential lie an interface can tell.
@MainActor
public struct ChatScreen: View {

    @Bindable private var viewModel: ChatViewModel
    private let onOpenProfile: @MainActor (String) -> Void
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?
    /// Reports one message sent to the viewer (contract v22).
    private let onReport: (@MainActor (ReportSubject) -> Void)?

    @FocusState private var isComposing: Bool
    @State private var isPickingPhotos = false
    @State private var isPickingDocuments = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    public init(
        viewModel: ChatViewModel,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)? = nil,
        onReport: (@MainActor (ReportSubject) -> Void)? = nil
    ) {
        self.onReport = onReport
        self.viewModel = viewModel
        self.onOpenProfile = onOpenProfile
        self.safetyMenu = safetyMenu
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .navigationTitle(viewModel.conversation.other.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let safetyMenu,
                   let actions = safetyMenu(SafetyTarget(user: viewModel.conversation.other)) {
                    // The button, not the bare menu items: a `Section` in a
                    // toolbar renders as nothing anybody can tap.
                    SafetyMenuButton(actions: actions)
                }
            }
        }
        .tnScreenBackground()
        .task { await viewModel.load() }
        // New messages, read receipts and deletions, the moment they happen
        // (contract v30). Ends with the screen.
        .task { await viewModel.listen() }
        .onAppear { Task { await viewModel.screenAppeared() } }
        .onDisappear { viewModel.screenDisappeared() }
        .onChange(of: viewModel.draft) { viewModel.draftDidChange() }
        .tnToast($viewModel.toast)
        // A container that keeps its children's own identifiers: without
        // this, "chat.screen" was stamped over the field and the send button.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.screen")
        .confirmationDialog(
            L10n.t("messages.delete.title"),
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("messages.delete.confirm"), role: .destructive) {
                Task { await viewModel.confirmDeletion() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                viewModel.keepMessage()
            }
        } message: {
            // Says what deletion actually does. The row survives with its text
            // blanked so a report keeps its evidence.
            Text(L10n.t("messages.delete.explanation"))
        }
        // Pictures and documents (contract v39).
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: max(1, viewModel.remainingFileSlots),
            matching: .images
        )
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                // One at a time, in the order picked, so each is checked
                // against the room left.
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await viewModel.addPicture(data)
                    } else {
                        viewModel.toast = .error(ChatFileProblem.unreadable.message)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingDocuments,
            allowedContentTypes: ChatFilePolicy.documentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result, !urls.isEmpty else { return }
            Task { await viewModel.addDocuments(urls) }
        }
        .fullScreenCover(item: $viewModel.viewing) { viewing in
            ChatPictureViewer(
                viewing: viewing,
                load: { attachment, thumbnail in try await viewModel.pictureData(attachment, thumbnail: thumbnail) },
                onClose: { viewModel.viewing = nil }
            )
        }
        .quickLookPreview($viewModel.previewURL)
        .sheet(item: $viewModel.sharing) { shared in
            ChatShareSheet(url: shared.url)
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SLSpacing.sm) {
                    if !viewModel.canSend {
                        requestBanner
                    }

                    ForEach(viewModel.messages) { message in
                        bubble(message)
                            .id(message.id)
                        if message.id == viewModel.readReceiptMessageId {
                            readReceipt
                        }
                    }

                    if viewModel.isOtherTyping {
                        typingIndicator
                            .id(Self.typingAnchor)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.md)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isOtherTyping)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) {
                // Newest message in view, the way every messaging app behaves.
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.isOtherTyping) { _, typing in
                if typing { withAnimation { proxy.scrollTo(Self.typingAnchor, anchor: .bottom) } }
            }
        }
    }

    private static let typingAnchor = "chat.typing"

    /// "typing…", where their next message will appear (contract v30 §3.4).
    private var typingIndicator: some View {
        HStack {
            HStack(spacing: SLSpacing.xs) {
                // Still, not animated: an endless animation keeps the screen
                // from ever settling, for VoiceOver and for the UI tests.
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                Text(L10n.t("messages.typing"))
                    .font(SLFont.caption)
                    .italic()
            }
            .foregroundStyle(SLColor.textSecondary)
            .padding(.horizontal, SLSpacing.md)
            .padding(.vertical, SLSpacing.sm)
            .background(SLColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))

            Spacer(minLength: SLSpacing.xxl)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("messages.typing.row", viewModel.conversation.other.displayName)))
        .accessibilityIdentifier("chat.typing")
    }

    /// "Read", under the viewer's latest message once the other person has
    /// read it. Never in a request: see ``ChatViewModel/readReceiptMessageId``.
    private var readReceipt: some View {
        Text(L10n.t("messages.bubble.read"))
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("chat.read")
    }

    /// Shown when the thread is a request the viewer has not accepted.
    ///
    /// Readable, not answerable: replying *is* accepting, and doing that
    /// silently would take the decision away from the person the folder exists
    /// to protect.
    private var requestBanner: some View {
        Text(L10n.t("messages.request.banner"))
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SLSpacing.md)
            .background(SLColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
            .padding(.bottom, SLSpacing.sm)
    }

    private func bubble(_ message: DirectMessage) -> some View {
        let mine = viewModel.isMine(message)
        return HStack {
            if mine { Spacer(minLength: SLSpacing.xxl) }

            VStack(alignment: mine ? .trailing : .leading, spacing: SLSpacing.xs) {
                if !message.attachments.isEmpty {
                    ChatMessageAttachmentsView(
                        message: message,
                        mine: mine,
                        openingDocumentId: viewModel.openingDocumentId,
                        load: { attachment, thumbnail in try await viewModel.pictureData(attachment, thumbnail: thumbnail) },
                        onOpenPicture: { index in viewModel.openPicture(in: message, at: index) },
                        onOpenDocument: { document in Task { await viewModel.openDocument(document) } }
                    )
                }

                if message.deleted || message.visibleText != nil || message.attachments.isEmpty {
                Text(message.text ?? L10n.t("messages.bubble.deleted"))
                    .font(SLFont.body)
                    .italic(message.deleted)
                    .foregroundStyle(
                        message.deleted
                            ? SLColor.textMuted
                            : (mine ? Color(tnHex: 0x02121C) : SLColor.textPrimary)
                    )
                    .multilineTextAlignment(mine ? .trailing : .leading)
                    // Each message keeps its own direction.
                    .environment(
                        \.layoutDirection,
                        TextDirection.resolve(languageCode: nil, text: message.text).layoutDirection
                    )
                }

                Text(RelativeTime.short(message.createdAt))
                    .font(SLFont.caption)
                    .foregroundStyle(mine ? Color(tnHex: 0x02121C).opacity(0.7) : SLColor.textMuted)
            }
            .padding(.horizontal, SLSpacing.md)
            .padding(.vertical, SLSpacing.sm)
            .background(mine ? SLColor.primary : SLColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))
            .contextMenu {
                // "Open" and "Download" for each document (contract v39 §8).
                ForEach(message.documents) { document in
                    Button {
                        Task { await viewModel.openDocument(document) }
                    } label: {
                        Label(Self.menuTitle(L10n.t("messages.files.open"), document), systemImage: "doc.viewfinder")
                    }
                    Button {
                        Task { await viewModel.downloadDocument(document) }
                    } label: {
                        Label(Self.menuTitle(L10n.t("messages.files.download"), document), systemImage: "arrow.down.circle")
                    }
                }
                if mine && !message.deleted {
                    Button(L10n.t("messages.delete.action"), role: .destructive) {
                        viewModel.requestDeletion(of: message)
                    }
                }
                if !mine, !message.deleted, let onReport {
                    Button(role: .destructive) {
                        onReport(.message(id: message.id, author: SafetyTarget(user: message.sender),
                                          excerpt: message.text ?? ""))
                    } label: {
                        Label(L10n.t("messages.report.action"), systemImage: "flag")
                    }
                }
            }

            if !mine { Spacer(minLength: SLSpacing.xxl) }
        }
        // With files, each picture and document stays its own control.
        .accessibilityElement(children: message.attachments.isEmpty ? .combine : .contain)
        .accessibilityLabel(
            Text(
                mine
                    ? L10n.t("messages.bubble.mine.a11yLabel", message.spokenText)
                    : L10n.t("messages.bubble.theirs.a11yLabel", viewModel.conversation.other.displayName, message.spokenText)
            )
        )
    }

    /// "Open · Lease.pdf" — which document a menu item is about.
    private static func menuTitle(_ action: String, _ document: ChatAttachment) -> String {
        document.filename.isEmpty ? action : "\(action) · \(document.filename)"
    }

    // MARK: - Composer

    /// "Attach": a picture from the library, or a document from Files.
    private var attachMenu: some View {
        Menu {
            Button {
                openPicker { isPickingPhotos = true }
            } label: {
                Label(L10n.t("messages.files.photos"), systemImage: "photo.on.rectangle")
            }
            Button {
                openPicker { isPickingDocuments = true }
            } label: {
                Label(L10n.t("messages.files.document"), systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 22))
                .foregroundStyle(SLColor.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(L10n.t("messages.files.attach")))
        .accessibilityIdentifier("chat.attach")
    }

    /// Opens a picker while the message has room for another file; says the
    /// limit otherwise.
    private func openPicker(_ open: () -> Void) {
        guard viewModel.remainingFileSlots > 0 else {
            viewModel.toast = .warning(ChatFileCopy.tooMany(viewModel.filesConfig.maxPerMessage))
            return
        }
        isComposing = false
        open()
    }

    @ViewBuilder
    private var composer: some View {
        if viewModel.canSend {
            VStack(spacing: 0) {
                SLDivider()

                if !viewModel.files.isEmpty {
                    ChatComposerFilesTray(
                        files: viewModel.files,
                        onRetry: { id in viewModel.retryFile(id) },
                        onRemove: { id in viewModel.removeFile(id) }
                    )
                }

                HStack(alignment: .bottom, spacing: SLSpacing.sm) {
                    if viewModel.canAttach {
                        attachMenu
                    }

                    TextField(
                        L10n.t("messages.composer.placeholder"),
                        text: $viewModel.draft,
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(SLFont.body)
                    .focused($isComposing)
                    .accessibilityIdentifier("chat.input")

                    if viewModel.isOverLimit {
                        Text(String(viewModel.remaining))
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .accessibilityLabel(Text(L10n.t("messages.composer.overLimit")))
                    }

                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                viewModel.isSendable ? SLColor.primary : SLColor.textMuted
                            )
                    }
                    .disabled(!viewModel.isSendable)
                    .accessibilityIdentifier("chat.send")
                    .accessibilityLabel(Text(L10n.t("messages.composer.send")))
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.sm)
            }
            .background(SLColor.surface1)
        }
    }
}
