import Foundation
import Observation

/// One open thread.
@MainActor
@Observable
public final class ChatViewModel {

    public private(set) var messages: [DirectMessage] = []
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public var draft = ""
    public var toast: SLToastMessage?
    /// Set when the person deleting one of their own messages needs to confirm.
    public var pendingDeletion: DirectMessage?

    // MARK: Files (contract v39)

    /// Pictures and documents waiting in the composer, in the order they
    /// will be shown.
    public private(set) var files: [ChatDraftFile] = []
    /// The server's rules for files; ``ChatFilesConfig/off`` until read.
    public private(set) var filesConfig: ChatFilesConfig = .off
    /// The pictures open full screen.
    public var viewing: ChatPictureViewing?
    /// The document open in Quick Look.
    public var previewURL: URL?
    /// The document handed to the share sheet ("Download").
    public var sharing: ChatSharedFile?
    /// The document being fetched before it opens.
    public private(set) var openingDocumentId: UUID?
    /// Whether this account may send files (`features.chat_files`), read
    /// when asked so a change to the account shows at once.
    private let filesAllowed: @MainActor () -> Bool
    private var filesConfigLoaded = false
    private var uploads: [UUID: Task<Void, Never>] = [:]

    public private(set) var conversation: Conversation
    private let viewerId: UUID?
    private let service: MessagesServiceProtocol
    /// The socket (contract v30), when there is one: new messages, read
    /// receipts and deletions arrive through it, and the viewer's typing goes
    /// out on it. `nil` — and a socket that is down — leaves the thread
    /// exactly as it was before real time: read on opening, on sending, and
    /// on the next ``load()``.
    private let realtime: RealtimeMessaging?
    /// Who is typing where, fed by the socket.
    private let typing: TypingBoard?
    private let now: () -> Date
    /// When the viewer's own typing is said.
    private var throttle = TypingThrottle()
    /// The server refused a typing frame for this thread (a vouched account,
    /// an identity hold, a thread that is not open to typing): stop saying it.
    private var typingRefused = false
    /// Whether the thread is on screen — what makes an arriving message read.
    public private(set) var isVisible = false
    /// A message from the other person arrived while the thread was not on
    /// screen; it is marked read when the thread comes back.
    private var unreadWhileAway = false

    public init(
        conversation: Conversation,
        viewerId: UUID?,
        service: MessagesServiceProtocol,
        realtime: RealtimeMessaging? = nil,
        typing: TypingBoard? = nil,
        filesAllowed: @escaping @MainActor () -> Bool = { false },
        now: @escaping () -> Date = { Date() }
    ) {
        self.filesAllowed = filesAllowed
        self.conversation = conversation
        self.viewerId = viewerId
        self.service = service
        self.realtime = realtime
        self.typing = typing
        self.now = now
    }

    /// "typing…" — the other person, in this thread, now.
    public var isOtherTyping: Bool {
        typing?.isTyping(in: conversation.id, by: conversation.other.id) ?? false
    }

    /// The message "Read" is shown under: the viewer's latest, once the other
    /// person has read it.
    ///
    /// Only in an accepted thread. A request is somebody deciding whether to
    /// let a stranger in, and the requests folder promises them that the
    /// sender cannot see whether they have read it.
    public var readReceiptMessageId: UUID? {
        guard conversation.accepted, !conversation.isDraft else { return nil }
        guard let latest = messages.last(where: { isMine($0) && !$0.deleted }), latest.read else { return nil }
        return latest.id
    }

    /// Whether the composer is usable.
    ///
    /// A request the viewer has not accepted is readable but not answerable:
    /// replying **is** accepting, and doing that silently would take the
    /// decision away from the person the folder exists to protect.
    public var canSend: Bool {
        conversation.accepted || !conversation.isRequest
    }

    public var isOverLimit: Bool {
        draft.count > MessageConstants.maximumLength
    }

    public var remaining: Int {
        MessageConstants.maximumLength - draft.count
    }

    public var isSendable: Bool {
        let hasWords = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Words are optional with files; every file must be kept first.
        return (hasWords || !files.isEmpty)
            && files.allSatisfy(\.isReady)
            && !isOverLimit
            && !isSending
            && canSend
    }

    // MARK: - Files

    /// The attach button: the account may send files, the server has them
    /// on, and — in a conversation that is still a request, or one that does
    /// not exist yet and may become one — the server lets requests carry them.
    public var canAttach: Bool {
        guard canSend, filesAllowed(), filesConfig.enabled else { return false }
        let mayBeRequest = conversation.isDraft || !conversation.accepted || conversation.isRequest
        return !mayBeRequest || filesConfig.inRequests
    }

    /// How many more files this message can carry.
    public var remainingFileSlots: Int {
        max(0, filesConfig.maxPerMessage - files.count)
    }

    /// Some file is still on its way.
    public var isUploadingFiles: Bool {
        files.contains(where: \.isUploading)
    }

    /// Reads the server's rules for files once, when this account may send them.
    public func loadFilesConfig() async {
        guard !filesConfigLoaded, filesAllowed() else { return }
        filesConfigLoaded = true
        if let config = try? await service.fetchChatFilesConfig() {
            filesConfig = config
        } else {
            filesConfigLoaded = false
        }
    }

    /// A picture from the library: readied (HEIC → JPEG, at most 4096 px),
    /// checked, and on its way.
    public func addPicture(_ data: Data) async {
        guard canAttach else { return }
        guard remainingFileSlots > 0 else {
            toast = .warning(ChatFileCopy.tooMany(filesConfig.maxPerMessage))
            return
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            ChatImagePreparer.prepare(data)
        }.value
        guard let prepared else {
            toast = .error(ChatFileProblem.unreadable.message)
            return
        }
        if let problem = ChatFilePolicy.check(
            kind: .image, sizeBytes: prepared.data.count, fileExtension: prepared.fileExtension, config: filesConfig
        ) {
            toast = .error(problem.message)
            return
        }
        guard remainingFileSlots > 0 else { return }
        guard let url = try? ChatDraftStorage.write(prepared.data, fileExtension: prepared.fileExtension) else {
            toast = .error(ChatFileProblem.unreadable.message)
            return
        }
        let stamp = Int(now().timeIntervalSince1970)
        let file = ChatDraftFile(
            kind: .image,
            filename: "IMG_\(stamp)_\(files.count + 1).\(prepared.fileExtension)",
            contentType: prepared.contentType,
            sizeBytes: prepared.data.count,
            fileURL: url
        )
        files.append(file)
        startUpload(file.id)
    }

    /// Documents from the Files picker, each checked before it goes.
    public func addDocuments(_ urls: [URL]) async {
        guard canAttach else { return }
        for source in urls {
            guard remainingFileSlots > 0 else {
                toast = .warning(ChatFileCopy.tooMany(filesConfig.maxPerMessage))
                return
            }
            let ext = source.pathExtension.lowercased()
            if let problem = ChatFilePolicy.check(kind: .document, sizeBytes: 1, fileExtension: ext, config: filesConfig) {
                toast = .error(problem.message)
                continue
            }
            let copied = await Task.detached(priority: .userInitiated) {
                try? ChatDraftStorage.copyDocument(from: source)
            }.value
            guard let copied else {
                toast = .error(ChatFileProblem.unreadable.message)
                continue
            }
            if let problem = ChatFilePolicy.check(
                kind: .document, sizeBytes: copied.sizeBytes, fileExtension: ext, config: filesConfig
            ) {
                ChatDraftStorage.remove(copied.url)
                toast = .error(problem.message)
                continue
            }
            let file = ChatDraftFile(
                kind: .document,
                filename: copied.url.lastPathComponent,
                contentType: ChatFilePolicy.contentType(forExtension: ext) ?? "application/octet-stream",
                sizeBytes: copied.sizeBytes,
                fileURL: copied.url
            )
            files.append(file)
            startUpload(file.id)
        }
    }

    /// Adds a file already on disk — what the pickers end in, and what the
    /// tests drive directly.
    func addPrepared(_ file: ChatDraftFile) {
        files.append(file)
        startUpload(file.id)
    }

    /// Tries a failed file again, from the start.
    public func retryFile(_ id: UUID) {
        guard let file = files.first(where: { $0.id == id }), file.failure?.retryable == true else { return }
        startUpload(id)
    }

    /// Takes a file out of the message. One the server kept is dropped there
    /// too, rather than left for the 24-hour sweep.
    public func removeFile(_ id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let file = files.remove(at: index)
        uploads[id]?.cancel()
        uploads[id] = nil
        ChatDraftStorage.remove(file.fileURL)
        if let attachmentId = file.attachmentId {
            Task { [service] in try? await service.discardAttachment(id: attachmentId) }
        }
    }

    /// Waits for every upload that is running — for the tests.
    func waitForUploads() async {
        for task in Array(uploads.values) { await task.value }
    }

    private func startUpload(_ id: UUID) {
        guard let file = files.first(where: { $0.id == id }) else { return }
        uploads[id]?.cancel()
        update(id) { $0.phase = .uploading(0) }
        let service = self.service
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.uploadProgressed(id, fraction) }
        }
        uploads[id] = Task { [weak self] in
            do {
                let attachment = try await ChatFileUpload.perform(service: service, file: file, progress: report)
                guard !Task.isCancelled else { return }
                self?.update(id) { $0.phase = .ready(attachment) }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let failure = ChatFileUpload.failure(for: error)
                self?.update(id) { $0.phase = .failed(message: failure.message, retryable: failure.retryable) }
            }
            self?.uploads[id] = nil
        }
    }

    private func uploadProgressed(_ id: UUID, _ fraction: Double) {
        update(id) { file in
            // Never backwards, and never once it is kept or has failed.
            if case let .uploading(current) = file.phase {
                file.phase = .uploading(max(current, min(fraction, 0.99)))
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout ChatDraftFile) -> Void) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        change(&files[index])
    }

    /// Clears the composer's files after they went out in a message.
    private func clearSentFiles() {
        for file in files { ChatDraftStorage.remove(file.fileURL) }
        files = []
    }

    // MARK: - Opening files

    /// A picture (or the one at `index` among the message's pictures) full screen.
    public func openPicture(in message: DirectMessage, at index: Int) {
        let pictures = message.pictures
        guard pictures.indices.contains(index) else { return }
        viewing = ChatPictureViewing(id: message.id, pictures: pictures, startIndex: index)
    }

    /// A picture's bytes, through the service's fresh-URL handling.
    public func pictureData(_ attachment: ChatAttachment, thumbnail: Bool) async throws -> Data {
        try await service.attachmentData(attachment, thumbnail: thumbnail)
    }

    /// Downloads a document and opens it in Quick Look.
    public func openDocument(_ attachment: ChatAttachment) async {
        guard let url = await fetchDocument(attachment) else { return }
        previewURL = url
    }

    /// Downloads a document and offers it to the share sheet, where it can be
    /// saved to Files.
    public func downloadDocument(_ attachment: ChatAttachment) async {
        guard let url = await fetchDocument(attachment) else { return }
        sharing = ChatSharedFile(url: url)
    }

    private func fetchDocument(_ attachment: ChatAttachment) async -> URL? {
        guard openingDocumentId == nil else { return nil }
        openingDocumentId = attachment.id
        defer { openingDocumentId = nil }
        do {
            return try await service.downloadAttachment(attachment)
        } catch {
            if !APIError.wrapping(error).isCancellation {
                toast = .error(L10n.t("messages.files.openFailed"))
            }
            return nil
        }
    }

    public func isMine(_ message: DirectMessage) -> Bool {
        message.isMine(viewerId: viewerId)
    }

    public func load() async {
        await loadFilesConfig()
        // Nothing to read yet: this thread starts when the first message is
        // sent, and asking the server for an id it never minted would 404.
        guard !conversation.isDraft else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await service.fetchMessages(conversationId: conversation.id)
            try? await service.markRead(conversationId: conversation.id)
        } catch {
            toast = .error(for: error)
        }
        await readTyping()
    }

    // MARK: - Real time

    /// Applies the socket's events until the screen goes.
    public func listen() async {
        guard let realtime else { return }
        for await event in realtime.events() {
            await apply(event)
        }
    }

    /// One event from the socket. Everything not about this thread is ignored.
    public func apply(_ event: RealtimeEvent) async {
        switch event {
        case .ready, .unavailable:
            // Nothing is replayed: whatever arrived while the socket was
            // down is only in the thread itself.
            await refreshQuietly()
        case let .messageNew(new):
            guard new.conversationId == conversation.id, !conversation.isDraft else { return }
            conversation = conversation.with(accepted: new.conversation.accepted, isRequest: new.conversation.isRequest)
            if insert(new.message), !isMine(new.message) {
                if isVisible {
                    try? await service.markRead(conversationId: conversation.id)
                } else {
                    unreadWhileAway = true
                }
            }
        case let .messageRead(read):
            // The other person read up to a moment: every message of the
            // viewer's sent by then is read. The viewer reading on another
            // device changes nothing here — the inbox clears its count.
            guard read.conversationId == conversation.id, read.readerId == conversation.other.id else { return }
            messages = messages.map { message in
                isMine(message) && !message.read && message.createdAt <= read.readAt ? message.markedRead() : message
            }
        case let .messageDeleted(deleted):
            guard deleted.conversationId == conversation.id else { return }
            messages = messages.map { $0.id == deleted.messageId ? $0.markedDeleted() : $0 }
        case let .typingRefused(_, conversationId):
            guard conversationId == nil || conversationId == conversation.id else { return }
            typingRefused = true
            throttle.reset()
        case .typing, .notificationNew, .accountStatus, .disconnected:
            break
        }
    }

    /// The message in its place, once: the viewer's own copy from another
    /// device, or the one this screen just sent, is matched on its id.
    /// - Returns: `true` when it was not on screen yet.
    @discardableResult
    private func insert(_ message: DirectMessage) -> Bool {
        // Already on screen — dropped, as the contract says: the copy here may
        // know more (a read receipt that overtook it) than the one arriving.
        guard !messages.contains(where: { $0.id == message.id }) else { return false }
        let position = messages.lastIndex(where: { $0.createdAt <= message.createdAt }).map { $0 + 1 } ?? 0
        messages.insert(message, at: position)
        return true
    }

    /// Re-reads the thread without a spinner or an error: the socket came
    /// back, and the screen already shows what it had.
    private func refreshQuietly() async {
        guard !conversation.isDraft, !isLoading else { return }
        guard let fresh = try? await service.fetchMessages(conversationId: conversation.id) else { return }
        messages = fresh
        if isVisible, fresh.contains(where: { !isMine($0) && !$0.read }) {
            try? await service.markRead(conversationId: conversation.id)
        }
        await readTyping()
    }

    /// Whether the other person is typing now — a thread just opened, or a
    /// socket just back, has not heard their last `typing`.
    private func readTyping() async {
        // Only with a socket up: without one nothing would keep the answer
        // current, and the server says "no" whenever real time is down.
        guard let typing, realtime?.isLive == true, conversation.accepted, !conversation.isDraft else { return }
        guard let status = try? await service.fetchTyping(conversationId: conversation.id) else { return }
        typing.seed(conversationId: conversation.id, userId: conversation.other.id, status: status)
    }

    /// The thread is on screen: anything that arrived while it was not is
    /// read now.
    public func screenAppeared() async {
        isVisible = true
        guard unreadWhileAway, !conversation.isDraft else { return }
        unreadWhileAway = false
        try? await service.markRead(conversationId: conversation.id)
    }

    /// The thread left the screen: the viewer is no longer typing in it.
    public func screenDisappeared() {
        isVisible = false
        guard throttle.isAnnounced else { return }
        throttle.reset()
        realtime?.sendTyping(conversationId: conversation.id, active: false)
    }

    /// The composer changed: "typing" at most every two seconds, "stopped"
    /// once when it is cleared (contract v30 §2.1).
    public func draftDidChange() {
        guard let realtime, canAnnounceTyping else { return }
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch throttle.draftChanged(isEmpty: isEmpty, at: now()) {
        case true?:
            if realtime.sendTyping(conversationId: conversation.id, active: true) {
                throttle.announced(at: now())
            }
        case false?:
            realtime.sendTyping(conversationId: conversation.id, active: false)
        case nil:
            break
        }
    }

    /// Only somebody who may send in this thread may say they are typing,
    /// and only in an accepted thread: a request stays quiet.
    private var canAnnounceTyping: Bool {
        !conversation.isDraft && conversation.accepted && canSend && !typingRefused
    }

    /// Finds the thread the server made for the first message, so the screen
    /// stops being a draft and can read itself.
    private func adoptRealConversation() async {
        let handle = Handle.normalised(conversation.other.handle)
        for list in [try? await service.fetchConversations(), try? await service.fetchRequests()] {
            if let found = list?.first(where: { Handle.normalised($0.other.handle) == handle }) {
                conversation = found
                return
            }
        }
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSendable else { return }

        isSending = true
        defer { isSending = false }
        do {
            // Addressed by handle: the server owns the one-thread-per-pair rule.
            let attachmentIds = files.compactMap(\.attachmentId)
            try await service.send(to: conversation.other.handle, text: text, attachmentIds: attachmentIds)
            clearSentFiles()
            // Sending ends the typing on the server by itself (contract v30
            // §2.1); clearing the field must not say it again.
            throttle.reset()
            // Cleared only after the server accepted it. Clearing first would
            // lose somebody's words to a dropped connection.
            draft = ""
            if conversation.isDraft { await adoptRealConversation() }
            await load()
        } catch {
            toast = .error(for: error)
        }
    }

    /// Asks before deleting, because there is no undo.
    /// What ``confirmDeletion()`` deletes. Separate from ``pendingDeletion``:
    /// tapping Delete makes SwiftUI dismiss the dialog, which sets the
    /// presentation binding to false and cleared `pendingDeletion` — before
    /// the button's async action ran. What is armed stays armed until it is
    /// deleted or explicitly kept.
    private var armedDeletion: DirectMessage?

    public func requestDeletion(of message: DirectMessage) {
        guard isMine(message), !message.deleted else { return }
        pendingDeletion = message
        armedDeletion = message
    }

    /// The person chose to keep the message.
    public func keepMessage() {
        pendingDeletion = nil
        armedDeletion = nil
    }

    public func confirmDeletion() async {
        guard let message = armedDeletion else { return }
        pendingDeletion = nil
        armedDeletion = nil
        do {
            try await service.deleteMessage(id: message.id)
            await load()
            // "Removed", not "erased": the server keeps the row with its text
            // blanked so a report about it still has its evidence, and telling
            // somebody otherwise would be a promise this platform cannot keep.
            toast = .success(L10n.t("messages.deleted"))
        } catch {
            toast = .error(for: error)
        }
    }
}

/// The pictures of one message, open full screen.
public struct ChatPictureViewing: Identifiable, Equatable, Sendable {
    /// The message's id.
    public let id: UUID
    public let pictures: [ChatAttachment]
    public let startIndex: Int
}

/// A downloaded document on its way to the share sheet.
public struct ChatSharedFile: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
}
