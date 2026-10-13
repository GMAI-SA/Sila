import Foundation
import UniformTypeIdentifiers

// MARK: - Pictures and documents in private messages (contract v39)

/// What a file in a message is.
public enum ChatAttachmentKind: String, Sendable, Hashable, Codable {
    case image
    case document
}

/// What the newest message of a thread was (`ConversationOut.last_message_kind`).
public enum MessageKind: String, Sendable, Hashable {
    case text
    case image
    case document
}

/// One file in a message, or on its way into one (`AttachmentOut`, §4).
///
/// Its URLs are signed and short-lived: pictures are cached by ``id``, never
/// by URL, and a URL past ``urlExpiresAt`` (or answering 403) is replaced by
/// asking `GET /messages/attachments/{id}` again.
public struct ChatAttachment: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let kind: ChatAttachmentKind
    /// `pending`, `ready` or `sent`.
    public let status: String
    /// A HEIC's name becomes `….jpg` once the server has kept it.
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int
    /// Pictures only.
    public let width: Int?
    public let height: Int?
    /// The full picture or the document; `nil` while pending. Absolute in
    /// production, root-relative on staging.
    public let url: String?
    /// Pictures only: a 512 px JPEG.
    public let thumbUrl: String?
    public let urlExpiresAt: Date?

    public init(
        id: UUID,
        kind: ChatAttachmentKind,
        status: String = "sent",
        filename: String,
        contentType: String,
        sizeBytes: Int,
        width: Int? = nil,
        height: Int? = nil,
        url: String? = nil,
        thumbUrl: String? = nil,
        urlExpiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.url = url
        self.thumbUrl = thumbUrl
        self.urlExpiresAt = urlExpiresAt
    }

    /// The URLs have run out, or are about to: ask for fresh ones first.
    public func needsFreshURL(now: Date = Date()) -> Bool {
        if url == nil { return true }
        guard let urlExpiresAt else { return false }
        return urlExpiresAt.timeIntervalSince(now) < 30
    }

    /// The file's extension, lower case — `pdf`, `docx`, `jpg`.
    public var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }

    /// Width over height, for laying a picture out before it has arrived.
    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

extension ChatAttachment: Decodable {

    private enum CodingKeys: String, CodingKey {
        case id, kind, status, filename, contentType, sizeBytes, width, height, url, thumbUrl, urlExpiresAt
    }

    /// Only the id is required. A kind this client does not know is shown as
    /// a document — a row with a name, which is never wrong — and a malformed
    /// expiry is treated as unknown rather than costing the message.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let rawKind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = rawKind.flatMap(ChatAttachmentKind.init(rawValue:)) ?? .document
        status = ((try? container.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? "sent"
        filename = ((try? container.decodeIfPresent(String.self, forKey: .filename)) ?? nil) ?? ""
        contentType = ((try? container.decodeIfPresent(String.self, forKey: .contentType)) ?? nil) ?? ""
        sizeBytes = ((try? container.decodeIfPresent(Int.self, forKey: .sizeBytes)) ?? nil) ?? 0
        width = (try? container.decodeIfPresent(Int.self, forKey: .width)) ?? nil
        height = (try? container.decodeIfPresent(Int.self, forKey: .height)) ?? nil
        url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil
        thumbUrl = (try? container.decodeIfPresent(String.self, forKey: .thumbUrl)) ?? nil
        urlExpiresAt = (try? container.decodeIfPresent(Date.self, forKey: .urlExpiresAt)) ?? nil
    }
}

/// A list of attachments in which one malformed entry costs that entry, never
/// the message carrying it.
struct LenientAttachmentList: Decodable {
    let attachments: [ChatAttachment]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var rows: [ChatAttachment] = []
        while !container.isAtEnd {
            if let row = try? container.decode(ChatAttachment.self) {
                rows.append(row)
            } else {
                // Step past the entry that would not decode.
                _ = try? container.decode(Skipped.self)
            }
        }
        attachments = rows
    }

    /// Accepts anything, so the list moves past it whatever its shape.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// `{ "attachment": AttachmentOut }` — complete, and the fresh-URL read.
struct ChatAttachmentEnvelope: Decodable {
    let attachment: ChatAttachment
}

// MARK: - Discovery

/// `GET /config` → `chat_files` (§2).
public struct ChatFilesConfig: Equatable, Sendable {
    public var enabled: Bool
    public var maxPerMessage: Int
    public var imageMaxBytes: Int
    public var documentMaxBytes: Int
    public var documentExtensions: [String]
    /// Whether files may go into a conversation that is still a request.
    public var inRequests: Bool

    public init(
        enabled: Bool,
        maxPerMessage: Int = ChatFilesConfig.defaultMaxPerMessage,
        imageMaxBytes: Int = 15_728_640,
        documentMaxBytes: Int = 26_214_400,
        documentExtensions: [String] = ChatFilesConfig.defaultDocumentExtensions,
        inRequests: Bool = false
    ) {
        self.enabled = enabled
        self.maxPerMessage = maxPerMessage
        self.imageMaxBytes = imageMaxBytes
        self.documentMaxBytes = documentMaxBytes
        self.documentExtensions = documentExtensions
        self.inRequests = inRequests
    }

    public static let defaultMaxPerMessage = 10
    public static let defaultDocumentExtensions = ["pdf", "docx", "xlsx", "pptx", "txt", "csv"]
    /// No server said files are open: no attach button.
    public static let off = ChatFilesConfig(enabled: false)
}

extension ChatFilesConfig: Decodable {

    private enum CodingKeys: String, CodingKey {
        case enabled, maxPerMessage, imageMaxBytes, documentMaxBytes, documentExtensions, inRequests
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        let limit = ((try? c.decodeIfPresent(Int.self, forKey: .maxPerMessage)) ?? nil) ?? Self.defaultMaxPerMessage
        maxPerMessage = limit > 0 ? limit : Self.defaultMaxPerMessage
        imageMaxBytes = ((try? c.decodeIfPresent(Int.self, forKey: .imageMaxBytes)) ?? nil) ?? 15_728_640
        documentMaxBytes = ((try? c.decodeIfPresent(Int.self, forKey: .documentMaxBytes)) ?? nil) ?? 26_214_400
        let extensions = ((try? c.decodeIfPresent([String].self, forKey: .documentExtensions)) ?? nil) ?? []
        documentExtensions = extensions.isEmpty ? Self.defaultDocumentExtensions : extensions.map { $0.lowercased() }
        inRequests = ((try? c.decodeIfPresent(Bool.self, forKey: .inRequests)) ?? nil) ?? false
    }
}

/// `GET /config`, read for its `chat_files` block only.
struct ChatFilesConfigEnvelope: Decodable {
    let chatFiles: ChatFilesConfig?

    private enum CodingKeys: String, CodingKey { case chatFiles }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatFiles = (try? c.decodeIfPresent(ChatFilesConfig.self, forKey: .chatFiles)) ?? nil
    }
}

// MARK: - Sending (§3)

/// `POST /messages/attachments`.
public struct ChatAttachmentRequest: Encodable, Equatable, Sendable {
    public let kind: ChatAttachmentKind
    public let filename: String
    /// Exactly the bytes that will be uploaded.
    public let sizeBytes: Int
    public let contentType: String

    public init(kind: ChatAttachmentKind, filename: String, sizeBytes: Int, contentType: String) {
        self.kind = kind
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.contentType = contentType
    }
}

/// Where the bytes go.
public struct ChatAttachmentUpload: Equatable, Sendable {
    public let method: String
    /// A signed storage URL (`auth: false`) or the API's own root-relative
    /// path (`auth: true`).
    public let url: String
    /// Sent exactly, and nothing else that is not listed.
    public let headers: [String: String]
    public let expiresAt: Date?
    /// `true`: the API's own path, with the bearer. `false`: storage, with no
    /// Authorization header at all.
    public let auth: Bool

    public init(method: String = "PUT", url: String, headers: [String: String] = [:], expiresAt: Date? = nil, auth: Bool) {
        self.method = method
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
        self.auth = auth
    }
}

extension ChatAttachmentUpload: Decodable {
    private enum CodingKeys: String, CodingKey { case method, url, headers, expiresAt, auth }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = ((try? c.decodeIfPresent(String.self, forKey: .method)) ?? nil) ?? "PUT"
        url = try c.decode(String.self, forKey: .url)
        headers = ((try? c.decodeIfPresent([String: String].self, forKey: .headers)) ?? nil) ?? [:]
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
        auth = ((try? c.decodeIfPresent(Bool.self, forKey: .auth)) ?? nil) ?? false
    }
}

/// `201` from `POST /messages/attachments`.
public struct ChatAttachmentStart: Decodable, Equatable, Sendable {
    public let attachment: ChatAttachment
    public let upload: ChatAttachmentUpload

    public init(attachment: ChatAttachment, upload: ChatAttachmentUpload) {
        self.attachment = attachment
        self.upload = upload
    }
}

// MARK: - Client checks

/// Why a file was not taken before anything went to the server.
public enum ChatFileProblem: Equatable, Sendable {
    case tooLarge
    case typeNotAllowed
    case tooMany
    case unreadable

    public var message: String {
        switch self {
        case .tooLarge: return ChatFileCopy.reason("too_large")
        case .typeNotAllowed: return ChatFileCopy.reason("type_not_allowed")
        case .unreadable: return ChatFileCopy.reason("unreadable")
        case .tooMany: return ChatFileCopy.tooMany(ChatFilesConfig.defaultMaxPerMessage)
        }
    }
}

/// The contract's rules, checked on the phone first so a person hears "too
/// large" before waiting for an upload to be refused.
public enum ChatFilePolicy {

    /// What the document picker offers.
    public static var documentTypes: [UTType] {
        let named = ["docx", "xlsx", "pptx"].compactMap { UTType(filenameExtension: $0) }
        return [.pdf, .plainText, .commaSeparatedText] + named
    }

    /// The MIME type sent as a hint for a document, by its extension.
    public static func contentType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        default: return nil
        }
    }

    /// `nil` when the file may go.
    public static func check(
        kind: ChatAttachmentKind,
        sizeBytes: Int,
        fileExtension: String,
        config: ChatFilesConfig
    ) -> ChatFileProblem? {
        switch kind {
        case .image:
            guard sizeBytes > 0 else { return .unreadable }
            return sizeBytes > config.imageMaxBytes ? .tooLarge : nil
        case .document:
            let ext = fileExtension.lowercased()
            guard config.documentExtensions.contains(ext), contentType(forExtension: ext) != nil else {
                return .typeNotAllowed
            }
            guard sizeBytes > 0 else { return .unreadable }
            return sizeBytes > config.documentMaxBytes ? .tooLarge : nil
        }
    }
}

// MARK: - Words (§8)

public enum ChatFileCopy {

    /// The sentence for a refusal's `detail.reason`.
    public static func reason(_ reason: String?) -> String {
        switch reason ?? "" {
        case "too_large": return L10n.t("messages.files.reason.tooLarge")
        case "type_not_allowed": return L10n.t("messages.files.reason.typeNotAllowed")
        case "type_mismatch": return L10n.t("messages.files.reason.typeMismatch")
        case "unreadable": return L10n.t("messages.files.reason.unreadable")
        case "macros": return L10n.t("messages.files.reason.macros")
        case "encrypted": return L10n.t("messages.files.reason.encrypted")
        case "size_mismatch", "not_uploaded": return L10n.t("messages.files.reason.notUploaded")
        default: return L10n.t("messages.files.failed")
        }
    }

    /// "You can send up to 10 files at a time".
    public static func tooMany(_ limit: Int) -> String {
        L10n.t("messages.files.tooMany", SLFormat.number(limit))
    }

    /// "Photo" or "Document", where a message of files has no words.
    public static func label(for kind: ChatAttachmentKind) -> String {
        switch kind {
        case .image: return L10n.t("messages.preview.photo")
        case .document: return L10n.t("messages.preview.document")
        }
    }
}

// MARK: - Addresses

public enum ChatFileURL {

    /// A root-relative path (staging) against the API's origin; an absolute
    /// URL as it is.
    public static func resolve(_ raw: String?, base: URL = AppConfig.apiBaseURL) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return nil }
        return URL(string: raw, relativeTo: origin)?.absoluteURL
    }
}
