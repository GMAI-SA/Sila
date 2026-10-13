import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file in the composer, from the moment it is picked until the message
/// carrying it is sent.
public struct ChatDraftFile: Identifiable, Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        /// Bytes on their way, `0…1`.
        case uploading(Double)
        /// Kept by the server; its id goes into the message.
        case ready(ChatAttachment)
        /// Refused or interrupted. `retryable` decides whether tapping it
        /// tries again or the only way out is to remove it.
        case failed(message: String, retryable: Bool)
    }

    /// This phone's id for it — the server's arrives with ``Phase/ready(_:)``.
    public let id: UUID
    public let kind: ChatAttachmentKind
    public let filename: String
    public let contentType: String
    /// Exactly the bytes of ``fileURL``.
    public let sizeBytes: Int
    /// A private copy in the temporary directory, read for the upload.
    public let fileURL: URL
    public var phase: Phase

    public init(
        id: UUID = UUID(),
        kind: ChatAttachmentKind,
        filename: String,
        contentType: String,
        sizeBytes: Int,
        fileURL: URL,
        phase: Phase = .uploading(0)
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.fileURL = fileURL
        self.phase = phase
    }

    /// The server's id, once it has kept the file.
    public var attachmentId: UUID? {
        if case let .ready(attachment) = phase { return attachment.id }
        return nil
    }

    public var isReady: Bool { attachmentId != nil }

    public var isUploading: Bool {
        if case .uploading = phase { return true }
        return false
    }

    public var progress: Double? {
        if case let .uploading(fraction) = phase { return fraction }
        return nil
    }

    public var failure: (message: String, retryable: Bool)? {
        if case let .failed(message, retryable) = phase { return (message, retryable) }
        return nil
    }
}

/// The three steps of §3 for one file: ask, send the bytes, complete.
public enum ChatFileUpload {

    /// Sends `file` and answers the kept attachment.
    ///
    /// A `409 not_uploaded` on completing sends the bytes once more; a signed
    /// URL refused by storage (403 — run out, usually) starts again with a new
    /// `POST`, once. Everything else is thrown for ``failure(for:)`` to word.
    public static func perform(
        service: MessagesServiceProtocol,
        file: ChatDraftFile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ChatAttachment {
        var restarts = 0
        while true {
            try Task.checkCancellation()
            let start = try await service.startAttachment(
                ChatAttachmentRequest(
                    kind: file.kind,
                    filename: file.filename,
                    sizeBytes: file.sizeBytes,
                    contentType: file.contentType
                )
            )
            do {
                try await service.uploadAttachment(
                    start.upload, file: file.fileURL, sizeBytes: file.sizeBytes, progress: progress
                )
                do {
                    return try await service.completeAttachment(id: start.attachment.id)
                } catch let error where isNotUploaded(error) {
                    try await service.uploadAttachment(
                        start.upload, file: file.fileURL, sizeBytes: file.sizeBytes, progress: progress
                    )
                    return try await service.completeAttachment(id: start.attachment.id)
                }
            } catch let error where isStaleSignature(error) && restarts < 1 {
                restarts += 1
                try? await service.discardAttachment(id: start.attachment.id)
            }
        }
    }

    /// `409 attachment_invalid` is only ever `not_uploaded`.
    static func isNotUploaded(_ error: Error) -> Bool {
        if case let .api(code, _, status) = APIError.wrapping(error) {
            return code == .attachmentInvalid && status == 409
        }
        return false
    }

    /// Storage refused the signature: run out, or not what it signed.
    static func isStaleSignature(_ error: Error) -> Bool {
        if case let .http(status, _) = APIError.wrapping(error) { return status == 403 }
        return false
    }

    /// What the composer says about a file that did not make it, and whether
    /// trying again can help.
    public static func failure(for error: Error) -> (message: String, retryable: Bool) {
        let api = APIError.wrapping(error)
        switch api {
        case let .api(code, message, status):
            switch code {
            case .attachmentInvalid:
                // The server has deleted it. Only "it did not finish
                // uploading" is worth another go.
                let unfinished = status == 409 || message == ChatFileCopy.reason("size_mismatch")
                return (message.isEmpty ? ChatFileCopy.reason(nil) : message, unfinished)
            case .unverified, .selfVerificationRequired, .identityHold, .invalidKind, .invalidSize:
                return (api.userMessage, false)
            default:
                return (api.userMessage, true)
            }
        case .transport, .http, .decoding:
            return (ChatFileCopy.reason(nil), true)
        default:
            return (api.userMessage, true)
        }
    }
}

// MARK: - Pictures

/// Readies a picked picture for sending: HEIC, WebP and anything larger than
/// ``maximumEdge`` become an upright JPEG; a JPEG or PNG that already fits,
/// and any GIF (which must stay animated), go as they are. The server
/// re-encodes every picture again and strips what it carries, so this is
/// about sending fewer bytes, not about privacy.
public enum ChatImagePreparer {

    public static let maximumEdge = 4096

    public struct Prepared: Equatable, Sendable {
        public let data: Data
        public let contentType: String
        public let fileExtension: String
        public let width: Int
        public let height: Int
    }

    public static func prepare(_ data: Data, maximumEdge: Int = ChatImagePreparer.maximumEdge) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let type: UTType? = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let longEdge = max(width, height)

        if let type, type.conforms(to: .gif) {
            return Prepared(data: data, contentType: "image/gif", fileExtension: "gif", width: width, height: height)
        }
        if let type, longEdge > 0, longEdge <= maximumEdge, orientation == 1 {
            if type.conforms(to: .jpeg) {
                return Prepared(data: data, contentType: "image/jpeg", fileExtension: "jpg", width: width, height: height)
            }
            if type.conforms(to: .png) {
                return Prepared(data: data, contentType: "image/png", fileExtension: "png", width: width, height: height)
            }
        }

        let edge = longEdge > 0 ? min(maximumEdge, longEdge) : maximumEdge
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, quality as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Prepared(
            data: output as Data,
            contentType: "image/jpeg",
            fileExtension: "jpg",
            width: image.width,
            height: image.height
        )
    }

    /// A small upright picture of a file on disk, for the composer's tile.
    public static func thumbnail(of file: URL, maximumEdge: Int = 240) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - The phone's copies

/// Where picked files wait while they upload. In the temporary directory:
/// the system may clear it, and nothing here outlives the composer.
public enum ChatDraftStorage {

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChatUploads", isDirectory: true)
    }

    /// Writes prepared picture bytes to a new file.
    public static func write(_ data: Data, fileExtension: String) throws -> URL {
        let directory = folder
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Copies a picked document, keeping its name, and answers the copy and
    /// its exact size.
    public static func copyDocument(from source: URL) throws -> (url: URL, sizeBytes: Int) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(safeName(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return (destination, size)
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A file name that is a name and nothing else.
    public static func safeName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }
}
