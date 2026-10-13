import Foundation

/// The production ``MessagesServiceProtocol``.
public final class MessagesService: MessagesServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient
    /// Carries a file's bytes for its PUT (contract v39 §3.2): from a file,
    /// so the body has a known length and is never sent chunked.
    private let transport: VideoUploadTransport
    /// Reads pictures and documents from their signed URLs, which need no
    /// header at all.
    private let session: URLSession
    /// The API base the staging root-relative URLs belong to.
    private let baseURL: URL

    public init(
        network: NetworkClient,
        tokens: AccessTokenProviding,
        analytics: AnalyticsClient,
        transport: VideoUploadTransport = ForegroundVideoUploadTransport(),
        session: URLSession = .shared,
        baseURL: URL = AppConfig.apiBaseURL
    ) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
        self.transport = transport
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - Reading

    public func fetchConversations() async throws -> [Conversation] {
        try await conversations(requests: false)
    }

    public func fetchRequests() async throws -> [Conversation] {
        try await conversations(requests: true)
    }

    private func conversations(requests: Bool) async throws -> [Conversation] {
        let token = try await tokens.accessToken()
        // Only sent when it is doing something: `requests=false` is the
        // server's default, and a URL that states its defaults is a URL whose
        // logs cannot be read at a glance.
        let query = requests ? [URLQueryItem(name: "requests", value: "true")] : []
        // The server wraps the list: `{"conversations": [...]}`. Decoding a bare
        // array here was why the Messages tab said it could not read the
        // response — the request itself was answering 200 all along.
        return try await network.send(
            APIRequest(path: "/conversations", accessToken: token, query: query),
            as: ConversationsEnvelope.self
        ).conversations
    }

    public func fetchCounts() async throws -> MessageCounts {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/conversations/unread-count", accessToken: token),
            as: MessageCounts.self
        )
    }

    public func fetchMessages(conversationId: UUID) async throws -> [DirectMessage] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/messages",
                accessToken: token
            ),
            as: MessagesEnvelope.self
        ).messages
    }

    // MARK: - Writing

    @discardableResult
    public func send(to handle: String, text: String) async throws -> UUID {
        try await send(to: handle, text: text, attachmentIds: [])
    }

    @discardableResult
    public func send(to handle: String, text: String, attachmentIds: [UUID]) async throws -> UUID {
        let token = try await tokens.accessToken()
        // Words alone keep the body every server has always read.
        let body: Data
        if attachmentIds.isEmpty {
            body = try JSONEncoder().encode(["text": text])
        } else {
            body = try JSONEncoder().encode(
                SendWithFiles(text: text, attachmentIds: attachmentIds.map { $0.uuidString.lowercased() })
            )
        }
        let response = try await network.send(
            APIRequest(
                path: "/conversations/\(handle)/messages",
                method: .post,
                body: body,
                accessToken: token
            ),
            as: SendResponse.self
        )
        analytics.track(.messageSent, properties: [:])
        return response.conversationId
    }

    public func accept(conversationId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/accept",
                method: .post,
                accessToken: token
            )
        )
        analytics.track(.messageRequestAccepted, properties: [:])
    }

    public func markRead(conversationId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/read",
                method: .post,
                accessToken: token
            )
        )
    }

    public func deleteMessage(id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest(
                path: "/messages/\(id.uuidString.lowercased())",
                method: .delete,
                accessToken: token
            )
        )
    }

    public func fetchTyping(conversationId: UUID) async throws -> TypingStatus {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(
                path: "/conversations/\(conversationId.uuidString.lowercased())/typing",
                accessToken: token
            ),
            as: TypingStatus.self
        )
    }

    /// `POST /conversations/{handle}/messages` answers with the thread the
    /// message landed in — which the caller may not have known existed.
    private struct SendResponse: Decodable {
        let conversationId: UUID
    }

    /// `{"text": "…", "attachment_ids": [...]}`, spelled out: the plain
    /// encoder here does not convert keys.
    private struct SendWithFiles: Encodable {
        let text: String
        let attachmentIds: [String]

        private enum CodingKeys: String, CodingKey {
            case text
            case attachmentIds = "attachment_ids"
        }
    }

    // MARK: - Pictures and documents (contract v39)

    public func fetchChatFilesConfig() async throws -> ChatFilesConfig {
        let envelope = try await network.send(APIRequest(path: "/config"), as: ChatFilesConfigEnvelope.self)
        return envelope.chatFiles ?? .off
    }

    public func startAttachment(_ request: ChatAttachmentRequest) async throws -> ChatAttachmentStart {
        let token = try await tokens.accessToken()
        return try await network.send(
            try APIRequest.json("/messages/attachments", body: request, accessToken: token),
            as: ChatAttachmentStart.self
        )
    }

    public func uploadAttachment(
        _ upload: ChatAttachmentUpload,
        file: URL,
        sizeBytes: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = ChatFileURL.resolve(upload.url, base: baseURL) else {
            throw APIError.transport("The upload address is not one this app can use.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = upload.method.isEmpty ? "PUT" : upload.method.uppercased()
        // Exactly the headers given. Storage's signature covers them, and an
        // Authorization header there would be refused.
        for (name, value) in upload.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if upload.auth {
            // Staging: the API's own path, with the usual bearer.
            let token = try await tokens.accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = VideoUploadTiming.pieceTimeout
        let total = Double(max(1, sizeBytes))
        let (body, response) = try await transport.upload(request, fromFile: file) { sent in
            progress(min(1, Double(sent) / total))
        }
        guard (200..<300).contains(response.statusCode) else {
            if upload.auth {
                throw URLSessionNetworkClient.makeError(status: response.statusCode, data: body)
            }
            // Storage's own answer. A 403 is a signature that has run out
            // (or a size that is not the signed one): start again.
            throw APIError.http(status: response.statusCode, message: String(decoding: body.prefix(200), as: UTF8.self))
        }
        progress(1)
    }

    public func completeAttachment(id: UUID) async throws -> ChatAttachment {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "\(attachmentPath(id))/complete", method: .post, accessToken: token),
            as: ChatAttachmentEnvelope.self
        ).attachment
    }

    public func discardAttachment(id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: attachmentPath(id), method: .delete, accessToken: token))
    }

    public func fetchAttachment(id: UUID) async throws -> ChatAttachment {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: attachmentPath(id), accessToken: token),
            as: ChatAttachmentEnvelope.self
        ).attachment
    }

    public func attachmentData(_ attachment: ChatAttachment, thumbnail: Bool) async throws -> Data {
        try await withFreshURL(attachment, thumbnail: thumbnail) { [session] url in
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func downloadAttachment(_ attachment: ChatAttachment) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatFiles", isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString.lowercased(), isDirectory: true)
        let name = ChatDraftStorage.safeName(attachment.filename.isEmpty ? "document" : attachment.filename)
        let destination = folder.appendingPathComponent(name)
        // Downloaded once already in this run: the same file.
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        return try await withFreshURL(attachment, thumbnail: false) { [session] url in
            let (temporary, response) = try await session.download(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                try? FileManager.default.removeItem(at: temporary)
                return (destination, status)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return (destination, status)
        }
    }

    /// Reads a file's URL, asking for fresh ones first when they have run out
    /// and once more when storage refuses them (403/404 — an expired or
    /// replaced signature).
    private func withFreshURL<T>(
        _ attachment: ChatAttachment,
        thumbnail: Bool,
        read: (URL) async throws -> (T, Int)
    ) async throws -> T {
        var current = attachment
        if current.needsFreshURL() {
            current = try await fetchAttachment(id: current.id)
        }
        for attempt in 0..<2 {
            let raw = thumbnail ? (current.thumbUrl ?? current.url) : current.url
            if let url = ChatFileURL.resolve(raw, base: baseURL) {
                let result: (T, Int)
                do {
                    result = try await read(url)
                } catch {
                    throw APIError.wrapping(error)
                }
                if (200..<300).contains(result.1) { return result.0 }
                guard attempt == 0, [401, 403, 404, 410].contains(result.1) else {
                    throw APIError.http(status: result.1, message: "")
                }
            } else if attempt > 0 {
                throw APIError.decoding("The file has no address.")
            }
            current = try await fetchAttachment(id: current.id)
        }
        throw APIError.decoding("The file has no address.")
    }

    private func attachmentPath(_ id: UUID) -> String {
        "/messages/attachments/\(id.uuidString.lowercased())"
    }
}

/// `GET /conversations` answers `{"conversations": [...]}`.
struct ConversationsEnvelope: Decodable {
    let conversations: [Conversation]

    init(from decoder: Decoder) throws {
        // Tolerate a bare array too, so a server that drops the wrapper does
        // not put the tab back into the state this type exists to fix.
        if let container = try? decoder.singleValueContainer(), let rows = try? container.decode([Conversation].self) {
            conversations = rows
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try container.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
    }

    private enum CodingKeys: String, CodingKey { case conversations }
}

/// `GET /conversations/{id}/messages` answers `{"messages": [...]}`.
struct MessagesEnvelope: Decodable {
    let messages: [DirectMessage]

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let rows = try? container.decode([DirectMessage].self) {
            messages = rows
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([DirectMessage].self, forKey: .messages) ?? []
    }

    private enum CodingKeys: String, CodingKey { case messages }
}

