import Foundation

/// A post waiting for its video: everything the composer had, so the post
/// can be written once the upload completes — after a relaunch too.
public struct PendingVideoPost: Codable, Equatable, Sendable {
    public var text: String
    public var scope: String
    public var scopeCountry: String?
    public var scopeRegion: String?
    public var quotedPostId: UUID?
    public var communityId: UUID?
    public var sensitive: String?
    public var sensitiveNote: String?

    public init(
        text: String,
        scope: ComposeScope,
        quotedPostId: UUID? = nil,
        communityId: UUID? = nil,
        sensitive: SensitiveKind? = nil,
        sensitiveNote: String = ""
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope.wireValue
        self.scopeCountry = scope.scopeCountry
        self.scopeRegion = scope.scopeRegion
        self.quotedPostId = quotedPostId
        self.communityId = communityId
        self.sensitive = sensitive?.wireValue
        self.sensitiveNote = sensitive == nil ? nil : sensitiveNote
    }

    /// The audience, read back. Anything this build cannot read is the
    /// widest scope, which the server narrows if it must.
    public var composeScope: ComposeScope {
        switch scope {
        case "country":
            if let code = scopeCountry { return .country(code) }
        case "region":
            if let region = GeoRegion.parse(scopeRegion) { return .region(region) }
        default:
            break
        }
        return .international
    }

    /// The draft `POST /posts` takes, with the video it waited for.
    public func draft(videoId: UUID) -> PostDraft {
        PostDraft(
            text: text,
            scope: composeScope,
            quotedPostId: quotedPostId,
            sensitive: sensitive.flatMap(SensitiveKind.init(rawValue:)),
            sensitiveNote: sensitiveNote ?? "",
            communityId: communityId,
            videoId: videoId
        )
    }
}

/// A video on its way from the composer to a post, as it is kept on disk.
public struct VideoUploadJob: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Whose it is. A job of another account is never resumed.
    public let accountId: UUID
    /// The picked file, until it has been prepared.
    public var sourceFileName: String?
    /// The prepared file, from then until the post is written.
    public var fileName: String?
    public var thumbnailFileName: String?
    public var sizeBytes: Int
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    /// The plan, while the upload is open.
    public var checkpoint: VideoUploadCheckpoint?
    /// The video, once the upload has completed.
    public var uploadedVideoId: UUID?
    /// The post to write once the video is uploaded, when the person pressed
    /// Post before it was.
    public var pendingPost: PendingVideoPost?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        sourceFileName: String?,
        fileName: String? = nil,
        thumbnailFileName: String? = nil,
        sizeBytes: Int,
        durationSeconds: Double,
        width: Int,
        height: Int,
        checkpoint: VideoUploadCheckpoint? = nil,
        uploadedVideoId: UUID? = nil,
        pendingPost: PendingVideoPost? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.sourceFileName = sourceFileName
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.checkpoint = checkpoint
        self.uploadedVideoId = uploadedVideoId
        self.pendingPost = pendingPost
        self.createdAt = createdAt
    }

    /// Every file of this job, for deleting them together.
    var fileNames: [String] {
        [sourceFileName, fileName, thumbnailFileName].compactMap { $0 }
    }
}

/// Keeps upload jobs and their files in one directory.
///
/// Application Support, not the backup, and readable once the phone has been
/// unlocked since it started — a background upload reads its pieces while
/// the phone is locked in a pocket. Nothing here outlives the session:
/// sign-out empties it.
public final class VideoUploadStore: @unchecked Sendable {

    public let directory: URL
    private let lock = NSLock()

    /// - Parameter directory: Defaults to `Application Support/VideoUploads`.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("VideoUploads", isDirectory: true)
        }
    }

    private var jobsFile: URL { directory.appendingPathComponent("jobs.json") }

    /// The directory, made if it is not there yet.
    @discardableResult
    public func prepareDirectory() -> URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return directory
    }

    /// A file in the store.
    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func load() -> [VideoUploadJob] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: jobsFile) else { return [] }
        return (try? JSONCoding.decoder.decode([VideoUploadJob].self, from: data)) ?? []
    }

    public func save(_ jobs: [VideoUploadJob]) {
        lock.lock()
        defer { lock.unlock() }
        prepareDirectory()
        guard let data = try? JSONCoding.encoder.encode(jobs) else { return }
        try? data.write(to: jobsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Moves a picked file into the store under `name`.
    public func adopt(_ source: URL, as name: String) throws -> URL {
        prepareDirectory()
        let destination = url(for: name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // A file the picker still holds on to is copied instead.
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }

    public func write(_ data: Data, as name: String) {
        prepareDirectory()
        try? data.write(to: url(for: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func remove(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    /// Everything, jobs and files: sign-out.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }
}
