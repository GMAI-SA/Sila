import CoreGraphics
import Foundation

// MARK: - Contract v28: video posts

/// Where a video stands (contract v28 §2).
///
/// `uploading → processing → ready`, or `held` for a moderator, or `failed`,
/// or `removed`. Only `ready` has files anybody can load.
public enum VideoStatus: String, Sendable, Hashable, Codable {
    case uploading, processing, held, ready, failed, removed

    /// A status this build does not know is read as `processing`: nothing to
    /// play and nothing claimed about why. Reading it as `ready` would draw a
    /// player for a file that may not exist.
    public init(wire: String?) {
        self = VideoStatus(rawValue: wire ?? "") ?? .processing
    }

    /// Whether the status can still change without anybody acting on it.
    /// `held` waits for a person, so it is watched more slowly but not settled.
    public var isSettled: Bool {
        self == .ready || self == .failed || self == .removed
    }
}

/// One caption track: WebVTT, machine-made, in one language.
public struct VideoCaptionTrack: Hashable, Sendable {
    /// `"ar"` or `"en"`.
    public let language: String
    public let url: URL

    public init(language: String, url: URL) {
        self.language = language
        self.url = url
    }

    /// "Arabic (automatic)" — captions are always labelled as the machine's.
    public var label: String { VideoCopy.captionLabel(language) }
}

/// Why a video cannot be used, for its owner only.
public struct VideoFailure: Hashable, Sendable, Codable {
    /// `video_too_long`, `video_unreadable`, `video_processing_failed` or
    /// `upload_expired`.
    public let code: String
    /// The server's English, for logs. The screen uses ``VideoCopy``.
    public let message: String

    public init(code: String, message: String = "") {
        self.code = code
        self.message = message
    }
}

/// A video, as a post carries it and as its owner reads it (`VideoOut`).
///
/// `posterURL`, `hlsURL` and `captions` exist only once the video is `ready`:
/// nothing else has a public file. The last four fields are the owner's
/// alone; to everybody else a video is always `ready`.
public struct PostVideo: Identifiable, Hashable, Sendable, Decodable {

    public let id: UUID
    public var status: VideoStatus
    public var posterURL: URL?
    /// The HLS master playlist — the one file a player opens.
    public var hlsURL: URL?
    /// The declared length until the file is measured, then the measured one.
    public var durationSeconds: Double?
    /// The best rendition's size as displayed: a portrait video is taller
    /// than wide.
    public var width: Int?
    public var height: Int?
    public var captions: [VideoCaptionTrack]
    public var postId: UUID?
    public var failure: VideoFailure?
    public var removedByModerator: Bool
    public var createdAt: Date?

    public init(
        id: UUID,
        status: VideoStatus,
        posterURL: URL? = nil,
        hlsURL: URL? = nil,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        captions: [VideoCaptionTrack] = [],
        postId: UUID? = nil,
        failure: VideoFailure? = nil,
        removedByModerator: Bool = false,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.posterURL = posterURL
        self.hlsURL = hlsURL
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.captions = captions
        self.postId = postId
        self.failure = failure
        self.removedByModerator = removedByModerator
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, posterUrl, hlsUrl, durationS, width, height, captions
        case postId, failure, removedByModerator, createdAt
    }

    private struct CaptionWire: Decodable {
        let lang: String?
        let url: String?
    }

    /// Tolerant, like the rest of a post: a malformed field costs that field,
    /// and a video whose status is not `ready` never keeps a file URL, whatever
    /// the wire says.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? c.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? c.decode(String.self, forKey: .id)) ?? ""
            guard let uuid = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A video needs an id")
            }
            id = uuid
        }
        status = VideoStatus(wire: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil)
        let ready = status == .ready
        // Root-relative, like every media path: resolved against the API
        // host, or it is a URL no player can load.
        posterURL = ready ? AppConfig.mediaURL((try? c.decodeIfPresent(String.self, forKey: .posterUrl)) ?? nil) : nil
        hlsURL = ready ? AppConfig.mediaURL((try? c.decodeIfPresent(String.self, forKey: .hlsUrl)) ?? nil) : nil
        durationSeconds = (try? c.decodeIfPresent(Double.self, forKey: .durationS)) ?? nil
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? nil
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? nil
        let wire = (try? c.decodeIfPresent([CaptionWire].self, forKey: .captions)) ?? nil
        captions = ready ? (wire ?? []).compactMap { track in
            guard let lang = track.lang?.lowercased(), !lang.isEmpty,
                  let url = AppConfig.mediaURL(track.url) else { return nil }
            return VideoCaptionTrack(language: lang, url: url)
        } : []
        postId = (try? c.decodeIfPresent(UUID.self, forKey: .postId)) ?? nil
        failure = (try? c.decodeIfPresent(VideoFailure.self, forKey: .failure)) ?? nil
        removedByModerator = ((try? c.decodeIfPresent(Bool.self, forKey: .removedByModerator)) ?? nil) ?? false
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
    }

    /// Whether there is something to play.
    public var isPlayable: Bool { status == .ready && hlsURL != nil }

    /// Width over height, held between a tall phone video and a wide one, so
    /// a strange size never makes a card a sliver or a wall. 16:9 until the
    /// file is measured.
    public var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 16.0 / 9.0 }
        return min(max(CGFloat(width) / CGFloat(height), 9.0 / 16.0), 16.0 / 9.0)
    }

    /// The caption track in a language, if the video has one.
    public func captions(in language: String) -> VideoCaptionTrack? {
        captions.first { $0.language == language }
    }
}

// MARK: - Uploading

/// How the file is sent (contract v28 §3). Which one a plan is depends on
/// where the server keeps media, never on the client, and a client supports
/// both.
public enum VideoUploadKind: String, Codable, Sendable, Hashable {
    /// 5 MiB chunks to the API, with `Content-Range`. Local storage.
    case chunked
    /// 8 MiB parts straight to object storage on signed URLs.
    case parts
}

/// An upload plan (`UploadPlanOut`). Kept on the device until the upload
/// completes, so a killed app resumes rather than starting again.
///
/// Property names are the snake-case wire names in camel case, so the same
/// synthesised coding reads the API (through ``JSONCoding``) and writes the
/// plan to disk (through the same coders).
public struct VideoUploadPlan: Codable, Equatable, Sendable {
    public let type: VideoUploadKind
    public let sizeBytes: Int
    public let expiresAt: Date?
    public let statusUrl: String
    public let completeUrl: String
    public let url: String?
    public let chunkSize: Int?
    public let chunkCount: Int?
    public let partsUrl: String?
    public let partSize: Int?
    public let partCount: Int?

    public init(
        type: VideoUploadKind,
        sizeBytes: Int,
        expiresAt: Date? = nil,
        statusUrl: String,
        completeUrl: String,
        url: String? = nil,
        chunkSize: Int? = nil,
        chunkCount: Int? = nil,
        partsUrl: String? = nil,
        partSize: Int? = nil,
        partCount: Int? = nil
    ) {
        self.type = type
        self.sizeBytes = sizeBytes
        self.expiresAt = expiresAt
        self.statusUrl = statusUrl
        self.completeUrl = completeUrl
        self.url = url
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.partsUrl = partsUrl
        self.partSize = partSize
        self.partCount = partCount
    }

    /// The size of one piece, chunk or part. The contract's own sizes are
    /// the fallback for a plan that somehow left it out.
    public var pieceSize: Int {
        switch type {
        case .chunked: return max(1, chunkSize ?? VideoLimits.chunkSize)
        case .parts: return max(1, partSize ?? VideoLimits.partSize)
        }
    }

    /// How many pieces the file is in.
    public var pieceCount: Int { VideoPieces.count(total: sizeBytes, pieceSize: pieceSize) }
}

/// `POST /videos/uploads` → `201`.
public struct VideoUploadStart: Decodable, Sendable {
    public let video: PostVideo
    public let upload: VideoUploadPlan

    public init(video: PostVideo, upload: VideoUploadPlan) {
        self.video = video
        self.upload = upload
    }
}

/// `GET {status_url}`: where an upload stands, with every gap.
public struct VideoUploadStatus: Decodable, Sendable {
    public let video: PostVideo
    public let upload: VideoUploadPlan?
    /// Bytes committed from the start without a gap.
    public let committedBytes: Int
    /// `chunked`: the offsets still to send.
    public let missingOffsets: [Int]?
    /// `parts`: the part numbers still to send.
    public let missingParts: [Int]?
    public let complete: Bool

    public init(
        video: PostVideo,
        upload: VideoUploadPlan?,
        committedBytes: Int,
        missingOffsets: [Int]? = nil,
        missingParts: [Int]? = nil,
        complete: Bool
    ) {
        self.video = video
        self.upload = upload
        self.committedBytes = committedBytes
        self.missingOffsets = missingOffsets
        self.missingParts = missingParts
        self.complete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case video, upload, committedBytes, missingOffsets, missingParts, complete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        video = try c.decode(PostVideo.self, forKey: .video)
        upload = (try? c.decodeIfPresent(VideoUploadPlan.self, forKey: .upload)) ?? nil
        committedBytes = (try? c.decode(Int.self, forKey: .committedBytes)) ?? 0
        missingOffsets = (try? c.decodeIfPresent([Int].self, forKey: .missingOffsets)) ?? nil
        missingParts = (try? c.decodeIfPresent([Int].self, forKey: .missingParts)) ?? nil
        complete = (try? c.decode(Bool.self, forKey: .complete)) ?? false
    }
}

/// One signed target for a `parts` upload: `PUT` the part's bytes to `url`
/// with exactly `headers`, and **no** Authorization — it goes to storage.
public struct VideoPartTarget: Decodable, Equatable, Sendable {
    public let number: Int
    public let size: Int
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let expiresAt: Date?

    public init(number: Int, size: Int, method: String = "PUT", url: String, headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.number = number
        self.size = size
        self.method = method
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case number, size, method, url, headers, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        size = try c.decode(Int.self, forKey: .size)
        method = (try? c.decode(String.self, forKey: .method)) ?? "PUT"
        url = try c.decode(String.self, forKey: .url)
        // Header values are strings on the wire; anything else is dropped
        // rather than failing the target.
        headers = (try? c.decode([String: String].self, forKey: .headers)) ?? [:]
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }
}

/// `POST {parts_url}` → the targets asked for.
struct VideoPartTargets: Decodable {
    let targets: [VideoPartTarget]
}

/// `POST {parts_url}` body.
struct VideoPartsRequest: Encodable {
    let numbers: [Int]
}

/// `POST /videos/uploads` body.
struct VideoUploadStartRequest: Encodable {
    let sizeBytes: Int
    let durationS: Double
    let contentType: String
}

/// What the server offers, readable before signing in (`GET /config`).
public struct VideoConfig: Equatable, Sendable, Decodable {
    public let enabled: Bool
    public let maxDurationSeconds: Double
    public let maxUploadBytes: Int
    public let uploadsPerDay: Int?

    public init(enabled: Bool, maxDurationSeconds: Double = VideoLimits.maximumDuration,
                maxUploadBytes: Int = VideoLimits.maximumUploadBytes, uploadsPerDay: Int? = 20) {
        self.enabled = enabled
        self.maxDurationSeconds = maxDurationSeconds
        self.maxUploadBytes = maxUploadBytes
        self.uploadsPerDay = uploadsPerDay
    }

    private enum CodingKeys: String, CodingKey { case enabled, maxDurationS, maxUploadBytes, uploadsPerDay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        maxDurationSeconds = (try? c.decode(Double.self, forKey: .maxDurationS)) ?? VideoLimits.maximumDuration
        maxUploadBytes = (try? c.decode(Int.self, forKey: .maxUploadBytes)) ?? VideoLimits.maximumUploadBytes
        uploadsPerDay = (try? c.decodeIfPresent(Int.self, forKey: .uploadsPerDay)) ?? nil
    }
}

/// The `/config` envelope.
struct ServerConfigEnvelope: Decodable {
    let video: VideoConfig?
}

// MARK: - Limits

/// The contract's numbers, in one place.
public enum VideoLimits {
    /// Refused above this, in seconds. Five over three minutes, for the
    /// padding phones and encoders add: a three-minute recording is never
    /// refused.
    public static let maximumDuration: TimeInterval = 185
    /// What "trim it" trims to: three minutes.
    public static let trimDuration: TimeInterval = 180
    /// 300 MB, declared at the plan and held to every chunk.
    public static let maximumUploadBytes = 314_572_800
    /// A chunk through the API.
    public static let chunkSize = 5 * 1_048_576
    /// A part straight to storage.
    public static let partSize = 8 * 1_048_576
    /// The most part numbers one `parts_url` call may ask for.
    public static let partsPerRequest = 20
    /// Pieces in flight at once. "Two at a time is plenty."
    public static let parallelPieces = 2
}

// MARK: - The upload's arithmetic

/// Which bytes each piece is, and which pieces are still to send. The same
/// arithmetic as the server's, from 1, for chunks and parts alike: piece `n`
/// is bytes `(n − 1) × size` to `min(n × size, total) − 1`.
public enum VideoPieces {

    /// How many pieces a file of `total` bytes is in. Never fewer than one.
    public static func count(total: Int, pieceSize: Int) -> Int {
        guard pieceSize > 0 else { return 1 }
        return max(1, (total + pieceSize - 1) / pieceSize)
    }

    /// The byte range of piece `number` (from 1), or an empty range past the end.
    public static func range(number: Int, total: Int, pieceSize: Int) -> Range<Int> {
        let start = (number - 1) * pieceSize
        guard number >= 1, start < total else { return total..<total }
        return start..<min(start + pieceSize, total)
    }

    /// `Content-Range: bytes first-last/total` for a chunk.
    public static func contentRange(number: Int, total: Int, pieceSize: Int) -> String {
        let bytes = range(number: number, total: total, pieceSize: pieceSize)
        return "bytes \(bytes.lowerBound)-\(bytes.upperBound - 1)/\(total)"
    }

    /// The pieces the server still needs, by number, in order.
    ///
    /// A status with no list at all (an older or odd answer) means everything
    /// from the committed offset on, which is always safe: sending a piece
    /// again replaces it with the same bytes.
    public static func missing(in status: VideoUploadStatus, plan: VideoUploadPlan) -> [Int] {
        let size = plan.pieceSize
        let count = plan.pieceCount
        let numbers: [Int]
        switch plan.type {
        case .chunked:
            if let offsets = status.missingOffsets {
                numbers = offsets.filter { $0 >= 0 && $0 % size == 0 }.map { $0 / size + 1 }
            } else {
                numbers = fromCommitted(status.committedBytes, pieceSize: size, count: count)
            }
        case .parts:
            numbers = status.missingParts ?? fromCommitted(status.committedBytes, pieceSize: size, count: count)
        }
        return Array(Set(numbers.filter { (1...count).contains($0) })).sorted()
    }

    private static func fromCommitted(_ committed: Int, pieceSize: Int, count: Int) -> [Int] {
        let first = max(0, committed) / pieceSize + 1
        return first <= count ? Array(first...count) : []
    }
}

/// How long to wait before trying again: 1, 2, 4, 8 … up to 60 seconds, with
/// jitter, so a thousand phones coming back from one outage do not arrive in
/// the same second.
public enum VideoBackoff {
    public static let ceiling: TimeInterval = 60

    /// - Parameters:
    ///   - attempt: 1 for the first retry.
    ///   - jitter: 0…1; the delay is scaled into `0.5…1.0` of the step.
    public static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let step = min(ceiling, pow(2, Double(max(0, attempt - 1))))
        let spread = 0.5 + 0.5 * min(max(jitter, 0), 1)
        return max(0.5, step * spread)
    }
}
