import Foundation

/// Everything the video surfaces ask of the server (contract v28).
///
/// Uploading and posting are two steps, as with pictures and voice: ask for
/// a plan, send the file as the plan says (resuming after anything), call
/// complete, then post with the video's id — see ``VideoUploader``.
public protocol VideoServiceProtocol: Sendable {

    /// `GET /config` — public. What the server offers and its limits.
    func fetchConfig() async throws -> VideoConfig

    /// `POST /videos/uploads` — an upload plan for a file of exactly
    /// `sizeBytes`, `durationSeconds` long as the phone measured it.
    /// - Throws: `video_too_long`, `video_too_large`, `video_rate_limited`,
    ///   `video_not_allowed`, `identity_hold`, `self_verification_required`,
    ///   `unverified`, `video_upload_unavailable`.
    func startUpload(sizeBytes: Int, durationSeconds: Double, contentType: String) async throws -> VideoUploadStart

    /// `GET {status_url}` — where the upload stands, with every gap.
    func uploadStatus(_ plan: VideoUploadPlan) async throws -> VideoUploadStatus

    /// `PUT {url}` — chunk `number` (from 1) of a `chunked` plan, read from
    /// `file`, which holds exactly that chunk's bytes. `progress` is told the
    /// bytes sent so far.
    func sendChunk(
        _ plan: VideoUploadPlan,
        number: Int,
        file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// `POST {parts_url}` — signed targets for parts of a `parts` plan, each
    /// good for fifteen minutes and for exactly that part and size.
    func partTargets(_ plan: VideoUploadPlan, numbers: [Int]) async throws -> [VideoPartTarget]

    /// `PUT` a part straight to storage, with the target's headers and no
    /// Authorization.
    func sendPart(
        _ target: VideoPartTarget,
        file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// `POST {complete_url}` — safe to call again; answers where the video
    /// now is.
    /// - Throws: `409 upload_incomplete`, `410 upload_expired`.
    func complete(_ plan: VideoUploadPlan) async throws -> PostVideo

    /// `GET /videos/{id}` — the owner's video, for watching it become ready.
    func fetchVideo(_ id: UUID) async throws -> PostVideo

    /// `DELETE /videos/{id}` — a cancelled upload or an abandoned draft.
    func discard(_ id: UUID) async throws
}

/// The one request an upload sends many of: a file as the body.
///
/// A seam of its own because in the app it is a **background** `URLSession`
/// (``BackgroundVideoUploadTransport``) — chunks keep going while the app is
/// suspended — and in tests it is anything at all.
public protocol VideoUploadTransport: Sendable {
    /// Sends `file` as the body of `request`. `progress` is told the bytes
    /// sent so far. Answers the body and the response, whatever the status:
    /// the caller decides what a status means.
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse)

    /// Stops every upload in flight — sign-out, or the person gave up.
    func cancelAll() async
}

/// What the phone knows about a picked video before doing anything with it.
public struct VideoSourceInfo: Equatable, Sendable {
    public let durationSeconds: Double
    public let sizeBytes: Int
    /// As displayed: a portrait video is taller than wide.
    public let width: Int
    public let height: Int
    /// Bits per second, video and sound together, as the file was written.
    public let estimatedBitRate: Double

    public init(durationSeconds: Double, sizeBytes: Int, width: Int, height: Int, estimatedBitRate: Double) {
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.estimatedBitRate = estimatedBitRate
    }

    /// Longer than three minutes and the server's five seconds of grace.
    public var isTooLong: Bool { durationSeconds > VideoLimits.maximumDuration }
}

/// A video ready to upload: compressed on the phone, measured, on disk.
public struct PreparedVideo: Equatable, Sendable {
    public let file: URL
    public let sizeBytes: Int
    public let durationSeconds: Double
    public let width: Int
    public let height: Int

    public init(file: URL, sizeBytes: Int, durationSeconds: Double, width: Int, height: Int) {
        self.file = file
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
    }
}

/// Measuring, compressing and trimming on the phone, so a three-minute
/// video goes up as about 70 MB of 720p rather than a gigabyte of 4K.
public protocol VideoPreparing: Sendable {
    /// Reads a picked file's length, size and shape.
    func inspect(_ source: URL) async throws -> VideoSourceInfo
    /// Writes an upload-ready `.mp4` to `destination`: H.264 at about 720p,
    /// HDR mapped to ordinary colour. `progress` runs 0…1.
    func prepare(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedVideo
    /// The first `seconds` of `source`, for a video over three minutes when
    /// the system's trimming screen is not available.
    func trim(_ source: URL, to destination: URL, seconds: TimeInterval) async throws -> URL
    /// A still from the start, JPEG, for the composer's thumbnail.
    func thumbnail(_ source: URL) async -> Data?
}

/// Why preparing a video on the phone failed.
public enum VideoPreparationError: Error, Equatable {
    /// The file is not a video the phone can read.
    case unreadable
    /// Even the smallest size the phone can make is over the server's limit.
    case tooLarge
    /// Something other than the person stopped the export half way: the app
    /// went to the background and iOS took back the time it had lent, or the
    /// phone's media services restarted. Nothing is wrong with the file, so
    /// it is compressed again once the app is back on screen.
    case interrupted
}
