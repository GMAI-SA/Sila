import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Sila

/// Pictures and documents in private messages (contract v39): what the wire
/// says, the client's own checks, the three-step upload and the composer.
@MainActor
final class ChatAttachmentTests: XCTestCase {

    private let decoder = JSONCoding.decoder

    // MARK: - Decoding

    func testAMessageCarriesItsFilesInOrder() throws {
        let json = """
        {
          "id": "6f1d3c9e-1b2a-4c55-9a0e-2a7e5b9f0d11",
          "conversation_id": "0c7b1c55-7d54-4c51-b4e3-5f0a7b0e2a10",
          "sender": \(Self.senderJSON),
          "text": "",
          "deleted": false,
          "read": false,
          "created_at": "2026-10-13T12:00:00+00:00",
          "attachments": [
            {"id": "11111111-1111-4111-8111-111111111111", "kind": "image", "status": "sent",
             "filename": "IMG_0042.jpg", "content_type": "image/jpeg", "size_bytes": 812345,
             "width": 2048, "height": 1536, "url": "https://bucket.example/chat/f/1.jpg?sig=a",
             "thumb_url": "https://bucket.example/chat/t/1.jpg?sig=b",
             "url_expires_at": "2026-10-13T12:40:00+00:00"},
            {"id": "22222222-2222-4222-8222-222222222222", "kind": "document", "status": "sent",
             "filename": "Lease.pdf", "content_type": "application/pdf", "size_bytes": 1000,
             "url": "/api/v1/files/signed?k=x", "thumb_url": null, "url_expires_at": null}
          ]
        }
        """
        let message = try decoder.decode(DirectMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.attachments.map(\.kind), [.image, .document])
        XCTAssertNil(message.visibleText, "A message of files only has no words to show.")
        XCTAssertEqual(message.kind, .image)
        let picture = try XCTUnwrap(message.pictures.first)
        XCTAssertEqual(picture.sizeBytes, 812_345)
        XCTAssertEqual(picture.width, 2048)
        XCTAssertEqual(picture.thumbUrl, "https://bucket.example/chat/t/1.jpg?sig=b")
        XCTAssertNotNil(picture.urlExpiresAt)
        XCTAssertEqual(picture.aspectRatio ?? 0, 2048.0 / 1536.0, accuracy: 0.001)
        let document = try XCTUnwrap(message.documents.first)
        XCTAssertEqual(document.filename, "Lease.pdf")
        XCTAssertEqual(document.fileExtension, "pdf")
        XCTAssertNil(document.thumbUrl)
    }

    func testAnOlderServerAndAMalformedFileCostNothingButThatFile() throws {
        let older = try decoder.decode(DirectMessage.self, from: Data(Self.message(attachments: nil).utf8))
        XCTAssertEqual(older.attachments, [])
        XCTAssertEqual(older.kind, .text)

        let null = try decoder.decode(DirectMessage.self, from: Data(Self.message(attachments: "null").utf8))
        XCTAssertEqual(null.attachments, [])

        let mixed = try decoder.decode(DirectMessage.self, from: Data(Self.message(attachments: """
        [ {"kind": "image"}, 42, "x",
          {"id": "33333333-3333-4333-8333-333333333333", "kind": "spreadsheet", "filename": "a.xlsx",
           "size_bytes": "big", "url_expires_at": "not a date"} ]
        """).utf8))
        XCTAssertEqual(mixed.attachments.count, 1, "Only the entry with an id survives.")
        XCTAssertEqual(mixed.attachments.first?.kind, .document, "An unknown kind is shown as a document.")
        XCTAssertEqual(mixed.attachments.first?.sizeBytes, 0)
        XCTAssertNil(mixed.attachments.first?.urlExpiresAt)
    }

    func testADeletedMessageNeverShowsFiles() throws {
        let json = Self.message(text: "null", deleted: true, attachments: """
        [{"id": "44444444-4444-4444-8444-444444444444", "kind": "image"}]
        """)
        let message = try decoder.decode(DirectMessage.self, from: Data(json.utf8))
        XCTAssertTrue(message.deleted)
        XCTAssertEqual(message.attachments, [])
        XCTAssertNil(message.kind)
    }

    func testTheInboxSaysPhotoOrDocument() throws {
        func row(_ last: String, _ kind: String) throws -> Conversation {
            let json = """
            {"id": "0c7b1c55-7d54-4c51-b4e3-5f0a7b0e2a10", "other": \(Self.senderJSON),
             "accepted": true, "is_request": false, "unread_count": 0,
             "last_message_at": "2026-10-13T12:00:00Z", "last_message": \(last), "last_message_kind": \(kind)}
            """
            return try decoder.decode(Conversation.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try row("\"\"", "\"image\"").previewText, L10n.t("messages.preview.photo"))
        XCTAssertEqual(try row("\"\"", "\"document\"").previewText, L10n.t("messages.preview.document"))
        XCTAssertEqual(try row("\"hello\"", "\"text\"").previewText, "hello")
        XCTAssertEqual(try row("\"hello\"", "\"image\"").previewText, "hello", "Words win when there are some.")
        XCTAssertNil(try row("null", "null").previewText, "A deleted newest message stays the deleted line.")
        XCTAssertEqual(try row("\"hi\"", "\"sticker\"").lastMessageKind, nil)
    }

    func testTheConfigBlockAndItsDefaults() throws {
        let json = """
        {"video": {"enabled": true}, "chat_files": {"enabled": true, "max_per_message": 10,
          "image_max_bytes": 15728640, "document_max_bytes": 26214400,
          "image_types": ["image/jpeg"], "document_types": ["application/pdf"],
          "document_extensions": ["PDF", "docx", "xlsx", "pptx", "txt", "csv"], "in_requests": false}}
        """
        let config = try XCTUnwrap(decoder.decode(ChatFilesConfigEnvelope.self, from: Data(json.utf8)).chatFiles)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.maxPerMessage, 10)
        XCTAssertEqual(config.documentMaxBytes, 26_214_400)
        XCTAssertTrue(config.documentExtensions.contains("pdf"), "Extensions are compared in lower case.")
        XCTAssertFalse(config.inRequests)

        let none = try decoder.decode(ChatFilesConfigEnvelope.self, from: Data(#"{"video": null}"#.utf8))
        XCTAssertNil(none.chatFiles)
        let broken = try decoder.decode(ChatFilesConfig.self, from: Data(#"{"max_per_message": 0}"#.utf8))
        XCTAssertFalse(broken.enabled)
        XCTAssertEqual(broken.maxPerMessage, 10)
    }

    func testTheUploadPlanKeepsItsHeadersExactly() throws {
        let json = """
        {"attachment": {"id": "55555555-5555-4555-8555-555555555555", "kind": "image", "status": "pending",
                        "filename": "IMG.HEIC", "content_type": "image/heic", "size_bytes": 2483312, "url": null},
         "upload": {"method": "PUT", "url": "https://bucket.example/chat/up/abc?X-Amz-Signature=1",
                    "headers": {"content-length": "2483312"}, "expires_at": "2026-10-13T12:15:00+00:00",
                    "auth": false}}
        """
        let start = try decoder.decode(ChatAttachmentStart.self, from: Data(json.utf8))
        XCTAssertEqual(start.upload.headers, ["content-length": "2483312"])
        XCTAssertFalse(start.upload.auth)
        XCTAssertEqual(start.attachment.status, "pending")
        XCTAssertNil(start.attachment.url)
        XCTAssertTrue(start.attachment.needsFreshURL())
    }

    func testTheStartRequestIsSnakeCase() throws {
        let request = try APIRequest.json(
            "/messages/attachments",
            body: ChatAttachmentRequest(kind: .document, filename: "Lease.pdf", sizeBytes: 812, contentType: "application/pdf")
        )
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "document")
        XCTAssertEqual(object["size_bytes"] as? Int, 812)
        XCTAssertEqual(object["content_type"] as? String, "application/pdf")
        XCTAssertEqual(object["filename"] as? String, "Lease.pdf")
    }

    func testARefusalCarriesItsReasonsWords() {
        let body = Data(#"{"detail": {"code": "attachment_invalid", "message": "x", "reason": "macros"}}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 400, data: body)
        XCTAssertEqual(error.code, .attachmentInvalid)
        XCTAssertEqual(error.userMessage, L10n.t("messages.files.reason.macros"))

        let need = URLSessionNetworkClient.makeError(
            status: 403, data: Data(#"{"detail": {"code": "attachments_need_accepted", "message": ""}}"#.utf8)
        )
        XCTAssertEqual(need.userMessage, L10n.t("messages.files.needAccepted"))
    }

    func testEveryReasonHasItsOwnSentence() {
        let reasons = ["too_large", "type_not_allowed", "type_mismatch", "unreadable", "macros", "encrypted", "not_uploaded"]
        let sentences = Set(reasons.map(ChatFileCopy.reason))
        XCTAssertEqual(sentences.count, reasons.count)
        XCTAssertEqual(ChatFileCopy.reason("size_mismatch"), ChatFileCopy.reason("not_uploaded"))
        XCTAssertEqual(ChatFileCopy.reason("something_new"), L10n.t("messages.files.failed"))
    }

    // MARK: - Addresses and checks

    func testRootRelativeURLsBelongToTheAPIOrigin() {
        let base = URL(string: "https://staging.example.sa/api/v1")!
        XCTAssertEqual(
            ChatFileURL.resolve("/api/v1/files/signed?k=1", base: base)?.absoluteString,
            "https://staging.example.sa/api/v1/files/signed?k=1"
        )
        XCTAssertEqual(
            ChatFileURL.resolve("https://bucket.example/a?b=c", base: base)?.absoluteString,
            "https://bucket.example/a?b=c"
        )
        XCTAssertNil(ChatFileURL.resolve(nil, base: base))
        XCTAssertNil(ChatFileURL.resolve("", base: base))
    }

    func testTheClientsOwnChecks() {
        let config = ChatFilesConfig(enabled: true, imageMaxBytes: 100, documentMaxBytes: 200)
        XCTAssertNil(ChatFilePolicy.check(kind: .image, sizeBytes: 100, fileExtension: "jpg", config: config))
        XCTAssertEqual(ChatFilePolicy.check(kind: .image, sizeBytes: 101, fileExtension: "jpg", config: config), .tooLarge)
        XCTAssertNil(ChatFilePolicy.check(kind: .document, sizeBytes: 200, fileExtension: "PDF", config: config))
        XCTAssertEqual(ChatFilePolicy.check(kind: .document, sizeBytes: 201, fileExtension: "pdf", config: config), .tooLarge)
        for refused in ["zip", "exe", "docm", "doc", "html", "svg", ""] {
            XCTAssertEqual(
                ChatFilePolicy.check(kind: .document, sizeBytes: 10, fileExtension: refused, config: config),
                .typeNotAllowed, refused
            )
        }
        XCTAssertEqual(ChatFilePolicy.contentType(forExtension: "csv"), "text/csv")
        XCTAssertFalse(ChatFilePolicy.documentTypes.isEmpty)
        XCTAssertEqual(ChatDraftStorage.safeName("../a/b:c.pdf"), ".._a_b_c.pdf")
        XCTAssertEqual(ChatDraftStorage.safeName("  "), "file")
    }

    // MARK: - Pictures

    func testALargePictureBecomesAJPEGWithinTheLimit() throws {
        let png = try Self.png(width: 5000, height: 20)
        let prepared = try XCTUnwrap(ChatImagePreparer.prepare(png))
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpg")
        XCTAssertEqual(max(prepared.width, prepared.height), 4096)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source).map { $0 as String }, UTType.jpeg.identifier)
    }

    func testASmallPNGGoesAsItIs() throws {
        let png = try Self.png(width: 40, height: 30)
        let prepared = try XCTUnwrap(ChatImagePreparer.prepare(png))
        XCTAssertEqual(prepared.contentType, "image/png")
        XCTAssertEqual(prepared.data, png)
        XCTAssertEqual(prepared.width, 40)
        XCTAssertNil(ChatImagePreparer.prepare(Data("not a picture".utf8)))
    }

    // MARK: - The three steps

    func testTheUploadAsksSendsAndCompletes() async throws {
        let service = FilesService()
        let progress = ProgressLog()
        let attachment = try await ChatFileUpload.perform(service: service, file: Self.draft()) { fraction in
            progress.append(fraction)
        }
        XCTAssertEqual(attachment.status, "ready")
        let starts = await service.starts
        XCTAssertEqual(starts.map(\.sizeBytes), [1234], "The exact size of what is uploaded.")
        let uploads = await service.uploads
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(progress.values.last, 1)
    }

    func testNothingArrivedSendsTheBytesAgain() async throws {
        let service = FilesService()
        await service.script(complete: [APIError.api(code: .attachmentInvalid, message: "", status: 409)])
        _ = try await ChatFileUpload.perform(service: service, file: Self.draft()) { _ in }
        let uploads = await service.uploads
        let starts = await service.starts
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(starts.count, 1)
    }

    func testAnExpiredSignatureStartsAgainOnce() async throws {
        let service = FilesService()
        await service.script(upload: [APIError.http(status: 403, message: "expired")])
        _ = try await ChatFileUpload.perform(service: service, file: Self.draft()) { _ in }
        let starts = await service.starts
        let discarded = await service.discarded
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(discarded.count, 1, "The first, unfinished upload is dropped.")

        let stubborn = FilesService()
        await stubborn.script(upload: [APIError.http(status: 403, message: ""), APIError.http(status: 403, message: "")])
        do {
            _ = try await ChatFileUpload.perform(service: stubborn, file: Self.draft()) { _ in }
            XCTFail("A second refusal is reported, not retried for ever.")
        } catch {
            XCTAssertTrue(ChatFileUpload.failure(for: error).retryable)
        }
    }

    func testWhatAFailureSaysAndWhetherRetryHelps() {
        let macros = ChatFileUpload.failure(for: APIError.api(
            code: .attachmentInvalid, message: ChatFileCopy.reason("macros"), status: 400
        ))
        XCTAssertEqual(macros.message, L10n.t("messages.files.reason.macros"))
        XCTAssertFalse(macros.retryable, "The server deleted it; only removing helps.")

        let mismatch = ChatFileUpload.failure(for: APIError.api(
            code: .attachmentInvalid, message: ChatFileCopy.reason("size_mismatch"), status: 400
        ))
        XCTAssertTrue(mismatch.retryable)

        let offline = ChatFileUpload.failure(for: APIError.transport("offline"))
        XCTAssertEqual(offline.message, L10n.t("messages.files.failed"))
        XCTAssertTrue(offline.retryable)

        XCTAssertFalse(ChatFileUpload.failure(for: APIError.api(code: .identityHold, message: "", status: 403)).retryable)
    }

    // MARK: - The composer

    func testTheAttachButtonFollowsTheAccountTheServerAndTheThread() async {
        let service = FilesService()

        let off = ChatViewModel(conversation: thread, viewerId: viewer.id, service: service, filesAllowed: { false })
        await off.loadFilesConfig()
        XCTAssertFalse(off.canAttach, "features.chat_files is false.")

        let on = ChatViewModel(conversation: thread, viewerId: viewer.id, service: service, filesAllowed: { true })
        XCTAssertFalse(on.canAttach, "Nothing before the server's rules are read.")
        await on.loadFilesConfig()
        XCTAssertTrue(on.canAttach)

        let sent = ChatViewModel(conversation: sentRequest, viewerId: viewer.id, service: service, filesAllowed: { true })
        await sent.loadFilesConfig()
        XCTAssertTrue(sent.canSend)
        XCTAssertFalse(sent.canAttach, "A request is words only while in_requests is false.")

        let draft = ChatViewModel(
            conversation: .draft(with: thread.other), viewerId: viewer.id, service: service, filesAllowed: { true }
        )
        await draft.loadFilesConfig()
        XCTAssertFalse(draft.canAttach, "A first message may become a request.")

        await service.script(config: ChatFilesConfig(enabled: true, inRequests: true))
        let open = ChatViewModel(conversation: sentRequest, viewerId: viewer.id, service: service, filesAllowed: { true })
        await open.loadFilesConfig()
        XCTAssertTrue(open.canAttach)

        await service.script(config: .off)
        let serverOff = ChatViewModel(conversation: thread, viewerId: viewer.id, service: service, filesAllowed: { true })
        await serverOff.loadFilesConfig()
        XCTAssertFalse(serverOff.canAttach)
    }

    func testFilesWithoutWordsSendInOrderOnceReady() async throws {
        let service = FilesService()
        let model = ChatViewModel(conversation: thread, viewerId: viewer.id, service: service, filesAllowed: { true })
        await model.loadFilesConfig()

        let first = Self.draft(name: "a.pdf")
        let second = Self.draft(name: "b.pdf")
        model.addPrepared(first)
        model.addPrepared(second)
        XCTAssertFalse(model.isSendable, "Not while the files are on their way.")
        XCTAssertTrue(model.isUploadingFiles)

        await model.waitForUploads()
        XCTAssertTrue(model.files.allSatisfy(\.isReady))
        XCTAssertTrue(model.isSendable, "Words are optional with files.")

        let ids = model.files.compactMap(\.attachmentId)
        await model.send()
        let sends = await service.sends
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.ids, ids)
        XCTAssertEqual(sends.first?.text, "")
        XCTAssertTrue(model.files.isEmpty, "The composer is cleared once the server took the message.")
    }

    func testAFailedFileIsRetriedOrRemoved() async throws {
        let service = FilesService()
        await service.script(upload: [APIError.transport("offline")])
        let model = ChatViewModel(conversation: thread, viewerId: viewer.id, service: service, filesAllowed: { true })
        await model.loadFilesConfig()
        let file = Self.draft()
        model.addPrepared(file)
        await model.waitForUploads()

        let failure = try XCTUnwrap(model.files.first?.failure)
        XCTAssertTrue(failure.retryable)
        XCTAssertFalse(model.isSendable, "A failed file holds the message back until it is retried or removed.")

        model.retryFile(file.id)
        await model.waitForUploads()
        XCTAssertTrue(model.files.first?.isReady == true)

        let kept = try XCTUnwrap(model.files.first?.attachmentId)
        model.removeFile(file.id)
        XCTAssertTrue(model.files.isEmpty)
        // The discard goes on its own; give it a moment.
        for _ in 0..<50 {
            let gone = await service.discarded
            if !gone.isEmpty { break }
            await Task.yield()
        }
        let discarded = await service.discarded
        XCTAssertEqual(discarded, [kept])
    }

    func testTheLimitIsTheServers() async {
        let service = FilesService()
        await service.script(config: ChatFilesConfig(enabled: true, maxPerMessage: 2))
        let model = ChatViewModel(conversation: thread, viewerId: viewer.id, service: service, filesAllowed: { true })
        await model.loadFilesConfig()
        model.addPrepared(Self.draft())
        model.addPrepared(Self.draft())
        XCTAssertEqual(model.remainingFileSlots, 0)

        await model.addDocuments([URL(fileURLWithPath: "/tmp/never-read.pdf")])
        XCTAssertEqual(model.files.count, 2)
        XCTAssertEqual(model.toast?.text, ChatFileCopy.tooMany(2))
        await model.waitForUploads()
    }

    func testAPictureOpensAtItsPlaceAmongTheMessagesPictures() {
        let model = ChatViewModel(conversation: thread, viewerId: viewer.id, service: FilesService())
        let pictures = (0..<3).map { _ in
            ChatAttachment(id: UUID(), kind: .image, filename: "p.jpg", contentType: "image/jpeg", sizeBytes: 1)
        }
        let document = ChatAttachment(id: UUID(), kind: .document, filename: "d.pdf", contentType: "application/pdf", sizeBytes: 1)
        let message = DirectMessage(
            id: UUID(), conversationId: thread.id, sender: thread.other, text: "", deleted: false,
            read: true, createdAt: Date(), attachments: [pictures[0], document, pictures[1], pictures[2]]
        )
        model.openPicture(in: message, at: 2)
        XCTAssertEqual(model.viewing?.pictures.map(\.id), pictures.map(\.id))
        XCTAssertEqual(model.viewing?.startIndex, 2)
        XCTAssertEqual(message.spokenText, L10n.t("messages.preview.photo"))
    }

    // MARK: - Fixtures

    private let viewer = UserSummary.mockViewer
    private var thread: Conversation { Conversation.mockThreads[0] }

    /// A request the viewer sent: theirs to accept, so not accepted, and not
    /// in the viewer's requests folder.
    private var sentRequest: Conversation {
        Conversation(
            id: UUID(), other: thread.other, accepted: false, isRequest: false,
            unreadCount: 0, lastMessageAt: nil, lastMessage: nil
        )
    }

    private static func draft(name: String = "IMG_1.jpg") -> ChatDraftFile {
        ChatDraftFile(
            kind: name.hasSuffix(".pdf") ? .document : .image,
            filename: name,
            contentType: name.hasSuffix(".pdf") ? "application/pdf" : "image/jpeg",
            sizeBytes: 1234,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("chat-test-\(UUID().uuidString)")
        )
    }

    private static let senderJSON = """
    {"id": "9b2f7d10-3c4e-4b5a-8d6f-1a2b3c4d5e6f", "handle": "noura", "display_name": "Noura",
     "is_verified": true, "country_code": "SA"}
    """

    private static func message(text: String = "\"hello\"", deleted: Bool = false, attachments: String?) -> String {
        let files = attachments.map { ", \"attachments\": \($0)" } ?? ""
        return """
        {"id": "6f1d3c9e-1b2a-4c55-9a0e-2a7e5b9f0d11", "conversation_id": "0c7b1c55-7d54-4c51-b4e3-5f0a7b0e2a10",
         "sender": \(senderJSON), "text": \(text), "deleted": \(deleted), "read": false,
         "created_at": "2026-10-13T12:00:00Z"\(files)}
        """
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// Fractions as reported, from whichever thread reports them.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// A server for files: answers every step, failing where a test scripts it.
private actor FilesService: MessagesServiceProtocol {

    struct Sent: Equatable {
        let handle: String
        let text: String
        let ids: [UUID]
    }

    private(set) var starts: [ChatAttachmentRequest] = []
    private(set) var uploads = 0
    private(set) var discarded: [UUID] = []
    private(set) var sends: [Sent] = []
    private var config = ChatFilesConfig(enabled: true)
    private var uploadFailures: [Error] = []
    private var completeFailures: [Error] = []

    func script(config: ChatFilesConfig? = nil, upload: [Error] = [], complete: [Error] = []) {
        if let config { self.config = config }
        uploadFailures = upload
        completeFailures = complete
    }

    func fetchConversations() async throws -> [Conversation] { [] }
    func fetchRequests() async throws -> [Conversation] { [] }
    func fetchCounts() async throws -> MessageCounts { .none }
    func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] { [] }
    @discardableResult
    func send(to handle: String, text: String) async throws -> UUID {
        try await send(to: handle, text: text, attachmentIds: [])
    }
    func accept(conversationId: UUID) async throws {}
    func markRead(conversationId: UUID) async throws {}
    func deleteMessage(id: UUID) async throws {}

    func fetchChatFilesConfig() async throws -> ChatFilesConfig { config }

    @discardableResult
    func send(to handle: String, text: String, attachmentIds: [UUID]) async throws -> UUID {
        sends.append(Sent(handle: handle, text: text, ids: attachmentIds))
        return UUID()
    }

    func startAttachment(_ request: ChatAttachmentRequest) async throws -> ChatAttachmentStart {
        starts.append(request)
        return ChatAttachmentStart(
            attachment: ChatAttachment(
                id: UUID(), kind: request.kind, status: "pending", filename: request.filename,
                contentType: request.contentType, sizeBytes: request.sizeBytes
            ),
            upload: ChatAttachmentUpload(url: "https://bucket.example/chat/up/x?sig=1",
                                         headers: ["content-length": String(request.sizeBytes)], auth: false)
        )
    }

    func uploadAttachment(
        _ upload: ChatAttachmentUpload,
        file: URL,
        sizeBytes: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        uploads += 1
        if !uploadFailures.isEmpty { throw uploadFailures.removeFirst() }
        progress(0.5)
        progress(1)
    }

    func completeAttachment(id: UUID) async throws -> ChatAttachment {
        if !completeFailures.isEmpty { throw completeFailures.removeFirst() }
        return ChatAttachment(
            id: id, kind: .image, status: "ready", filename: "IMG_1.jpg", contentType: "image/jpeg",
            sizeBytes: 1234, url: "https://bucket.example/chat/f/x.jpg?sig=2"
        )
    }

    func discardAttachment(id: UUID) async throws {
        discarded.append(id)
    }
}
