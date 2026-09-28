import AVFoundation
import Foundation
import UIKit

/// Scripted ``VideoServiceProtocol``: a small server of its own, for tests,
/// previews and the `-mockVideo` launch argument.
///
/// It keeps the pieces it is sent at their offsets, in one file per video,
/// so the video that becomes "ready" is exactly the bytes that were uploaded
/// — a chunk in the wrong place would play wrong. Its state is kept on disk,
/// so a journey that kills the app half way through an upload finds the
/// server where it left it.
public actor VideoServiceMock: VideoServiceProtocol {

    /// The worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// A `chunked` plan; ready after two reads.
        case success
        /// A `parts` plan: signed targets, then parts straight to "storage".
        case parts
        /// The connection drops half way through the second piece, once.
        case dropsOnce
        /// The first complete answers `410 upload_expired`; a new plan works.
        case expiresOnce
        /// Converted, then held for a moderator.
        case held
        /// The server could not read the file.
        case failed
        /// `403 video_not_allowed` at the plan: not verified.
        case notAllowed
        /// Every call fails as it does with no connection.
        case offline
        /// Small pieces arrive one after another, three seconds apart: long
        /// enough to switch away from the app, or to kill it, in the middle.
        case slow
    }

    private struct Stored: Codable {
        var type: VideoUploadKind
        var sizeBytes: Int
        var pieceSize: Int
        var durationSeconds: Double
        var received: [Int]
        var status: VideoStatus
        var reads: Int
        var failureCode: String?
        /// The post that holds it.
        var postId: UUID?
        /// Why it was removed: `true` by a moderator, `false` by anything
        /// else (the sweep of videos nobody posted, a cancelled upload).
        var removedByModerator: Bool?
    }

    private struct State: Codable {
        var videos: [UUID: Stored] = [:]
        var dropped = false
        var expired = false
    }

    public private(set) var scenario: MockScenario
    /// Every call, in order: the assertion surface.
    public private(set) var calls: [String] = []

    private var state: State
    private let directory: URL
    private let pieceLatency: TimeInterval
    private let readyAfterReads: Int
    private let pieceSize: Int

    /// - Parameters:
    ///   - directory: Where the mock keeps its "server". A relaunched app
    ///     finds it again here.
    ///   - pieceLatency: Seconds each piece takes. Tests pass `0`.
    ///   - readyAfterReads: Reads of a video before it is ready (or held,
    ///     or failed).
    ///   - pieceSize: Small, so a sample of a few hundred kilobytes is
    ///     several pieces.
    public init(
        scenario: MockScenario = .success,
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("sila-mock-video-\(UUID().uuidString)"),
        pieceLatency: TimeInterval = 0.15,
        readyAfterReads: Int = 2,
        pieceSize: Int = 64 * 1024
    ) {
        self.scenario = scenario
        self.directory = directory
        self.pieceLatency = scenario == .slow ? max(pieceLatency, 3) : pieceLatency
        self.readyAfterReads = readyAfterReads
        // Slow and in small pieces: a three-second sample is seven of them,
        // the last arriving some twenty seconds in — time enough to switch
        // away and to quit with some still to send.
        self.pieceSize = scenario == .slow ? min(pieceSize, 16 * 1024) : pieceSize
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = try? Data(contentsOf: directory.appendingPathComponent("state.json"))
        state = saved.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    /// The mock's own directory for a launch, kept between launches.
    public static var launchDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("sila-mock-video", isDirectory: true)
    }

    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    /// Where a video stands on the mocked server, for assertions.
    public func receivedPieces(_ id: UUID) -> [Int] {
        state.videos[id]?.received.sorted() ?? []
    }

    /// The file the mocked server assembled.
    public nonisolated func storedFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).mp4")
    }

    // MARK: - VideoServiceProtocol

    public func fetchConfig() async throws -> VideoConfig {
        calls.append("config")
        try failIfOffline()
        return VideoConfig(enabled: true)
    }

    public func startUpload(sizeBytes: Int, durationSeconds: Double, contentType: String) async throws -> VideoUploadStart {
        calls.append("start")
        try failIfOffline()
        if scenario == .notAllowed {
            throw APIError.api(code: .videoNotAllowed, message: L10n.t("video.error.notVerified"), status: 403)
        }
        if durationSeconds > VideoLimits.maximumDuration {
            throw APIError.api(code: .videoTooLong, message: "", status: 400)
        }
        if sizeBytes > VideoLimits.maximumUploadBytes {
            throw APIError.api(code: .videoTooLarge, message: "", status: 413)
        }
        let id = UUID()
        let type: VideoUploadKind = scenario == .parts ? .parts : .chunked
        state.videos[id] = Stored(type: type, sizeBytes: sizeBytes, pieceSize: pieceSize,
                                  durationSeconds: durationSeconds, received: [], status: .uploading, reads: 0)
        FileManager.default.createFile(atPath: storedFile(id).path, contents: nil)
        save()
        return VideoUploadStart(video: PostVideo(id: id, status: .uploading, durationSeconds: durationSeconds),
                                upload: plan(id))
    }

    public func uploadStatus(_ plan: VideoUploadPlan) async throws -> VideoUploadStatus {
        calls.append("status")
        try failIfOffline()
        let id = try videoId(of: plan)
        guard let stored = state.videos[id] else { throw APIError.api(code: .videoNotFound, message: "", status: 404) }
        let count = VideoPieces.count(total: stored.sizeBytes, pieceSize: stored.pieceSize)
        let missing = (1...count).filter { !stored.received.contains($0) }
        let committed = (1...count).prefix { stored.received.contains($0) }.reduce(0) {
            $0 + VideoPieces.range(number: $1, total: stored.sizeBytes, pieceSize: stored.pieceSize).count
        }
        let open = stored.status == .uploading
        return VideoUploadStatus(
            video: video(id),
            upload: open ? plan : nil,
            committedBytes: open ? committed : stored.sizeBytes,
            missingOffsets: open && stored.type == .chunked ? missing.map { ($0 - 1) * stored.pieceSize } : nil,
            missingParts: open && stored.type == .parts ? missing : nil,
            complete: [.processing, .held, .ready].contains(stored.status)
        )
    }

    public func sendChunk(_ plan: VideoUploadPlan, number: Int, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        calls.append("chunk \(number)")
        try await receive(videoId(of: plan), number: number, file: file, progress: progress)
    }

    public func partTargets(_ plan: VideoUploadPlan, numbers: [Int]) async throws -> [VideoPartTarget] {
        calls.append("targets \(numbers.map(String.init).joined(separator: ","))")
        try failIfOffline()
        let id = try videoId(of: plan)
        guard let stored = state.videos[id] else { throw APIError.api(code: .uploadExpired, message: "", status: 410) }
        return numbers.map { number in
            VideoPartTarget(
                number: number,
                size: VideoPieces.range(number: number, total: stored.sizeBytes, pieceSize: stored.pieceSize).count,
                url: "https://storage.mock/ingest/\(id.uuidString.lowercased())/original?partNumber=\(number)",
                headers: ["content-length": String(VideoPieces.range(number: number, total: stored.sizeBytes, pieceSize: stored.pieceSize).count)],
                expiresAt: Date().addingTimeInterval(900)
            )
        }
    }

    public func sendPart(_ target: VideoPartTarget, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        calls.append("part \(target.number)")
        guard let components = URLComponents(string: target.url),
              let raw = components.path.split(separator: "/").dropFirst().first,
              let id = UUID(uuidString: String(raw)) else {
            throw APIError.http(status: 403, message: "")
        }
        try await receive(id, number: target.number, file: file, progress: progress)
    }

    public func complete(_ plan: VideoUploadPlan) async throws -> PostVideo {
        calls.append("complete")
        try failIfOffline()
        let id = try videoId(of: plan)
        guard var stored = state.videos[id] else { throw APIError.api(code: .uploadExpired, message: "", status: 410) }
        if [.processing, .held, .ready].contains(stored.status) { return video(id) }
        if scenario == .expiresOnce, !state.expired {
            state.expired = true
            stored.status = .removed
            state.videos[id] = stored
            save()
            throw APIError.api(code: .uploadExpired, message: "", status: 410)
        }
        guard stored.status == .uploading else { throw APIError.api(code: .uploadExpired, message: "", status: 410) }
        let count = VideoPieces.count(total: stored.sizeBytes, pieceSize: stored.pieceSize)
        guard Set(stored.received) == Set(1...count) else {
            throw APIError.api(code: .uploadIncomplete, message: "", status: 409)
        }
        stored.status = .processing
        state.videos[id] = stored
        save()
        return video(id)
    }

    public func fetchVideo(_ id: UUID) async throws -> PostVideo {
        calls.append("video")
        try failIfOffline()
        guard var stored = state.videos[id] else { throw APIError.api(code: .videoNotFound, message: "", status: 404) }
        if stored.status == .processing {
            stored.reads += 1
            if stored.reads >= readyAfterReads {
                switch scenario {
                case .held: stored.status = .held
                case .failed:
                    stored.status = .failed
                    stored.failureCode = "video_unreadable"
                default:
                    stored.status = .ready
                    await publish(id, durationSeconds: stored.durationSeconds)
                }
            }
            state.videos[id] = stored
            save()
        }
        return video(id)
    }

    public func discard(_ id: UUID) async throws {
        calls.append("discard")
        if state.videos[id]?.postId != nil {
            throw APIError.api(code: .videoUsed, message: "", status: 409)
        }
        state.videos[id]?.status = .removed
        state.videos[id]?.removedByModerator = false
        try? FileManager.default.removeItem(at: storedFile(id))
        save()
    }

    // MARK: - Posts and removals

    /// What `POST /posts` does with the video it names (the server's
    /// `claim_for_post`): only a complete video on no post yet is taken.
    /// A composer mock calls this so the mocked server knows the video is
    /// posted, and refuses it a second time as the real one does.
    public func claim(_ id: UUID, forPost postId: UUID) throws {
        calls.append("claim")
        guard var stored = state.videos[id] else { throw APIError.api(code: .invalidVideo, message: "", status: 400) }
        if stored.postId != nil { throw APIError.api(code: .videoUsed, message: "", status: 409) }
        switch stored.status {
        case .uploading: throw APIError.api(code: .videoNotUploaded, message: "", status: 409)
        case .failed: throw APIError.api(code: .videoProcessingFailed, message: "", status: 409)
        case .removed: throw APIError.api(code: .videoRemoved, message: "", status: 409)
        case .processing, .held, .ready: break
        }
        stored.postId = postId
        state.videos[id] = stored
        save()
    }

    /// Removes a video as the server would: `byModerator`, or by the daily
    /// sweep of videos nobody posted.
    public func remove(_ id: UUID, byModerator: Bool) {
        state.videos[id]?.status = .removed
        state.videos[id]?.removedByModerator = byModerator
        try? FileManager.default.removeItem(at: storedFile(id))
        save()
    }

    // MARK: - The mocked server

    private func receive(_ id: UUID, number: Int, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try failIfOffline()
        guard let stored = state.videos[id], stored.status == .uploading else {
            throw APIError.api(code: .uploadExpired, message: "", status: 410)
        }
        let data = try Data(contentsOf: file)
        let range = VideoPieces.range(number: number, total: stored.sizeBytes, pieceSize: stored.pieceSize)
        guard data.count == range.count else {
            throw APIError.api(code: .uploadChunkInvalid, message: "", status: 400)
        }
        // Half of it, then the rest: a progress line with something to show.
        // Slow pieces arrive one after another, as over a poor connection,
        // so an upload is still going when a journey switches away or quits.
        let wait = scenario == .slow ? pieceLatency * Double(number) : pieceLatency
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait / 2 * 1_000_000_000))
        }
        progress(Int64(data.count / 2))
        if scenario == .dropsOnce, number == 2, !state.dropped {
            state.dropped = true
            save()
            // The connection drops half way: nothing of this piece is kept.
            throw APIError.transport("The network connection was lost.")
        }
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait / 2 * 1_000_000_000))
        }
        // Read again after the waits: other pieces of the same video arrived
        // meanwhile (an actor lets another call in at every wait), and
        // writing back the copy read before them would forget them — with
        // a few hundred pieces in flight, most of the video.
        guard var current = state.videos[id], current.status == .uploading else {
            throw APIError.api(code: .uploadExpired, message: "", status: 410)
        }
        let handle = try FileHandle(forWritingTo: storedFile(id))
        try handle.seek(toOffset: UInt64(range.lowerBound))
        try handle.write(contentsOf: data)
        try handle.close()
        progress(Int64(data.count))
        if !current.received.contains(number) { current.received.append(number) }
        state.videos[id] = current
        save()
    }

    /// Makes the files a ready video has: a poster, and captions in both
    /// languages. The "stream" is the assembled file itself.
    private func publish(_ id: UUID, durationSeconds: Double) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: storedFile(id)))
        generator.appliesPreferredTrackTransform = true
        if let image = try? await generator.image(at: .zero).image,
           let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) {
            try? jpeg.write(to: file(id, "poster.jpg"))
        }
        let half = max(0.5, durationSeconds / 2)
        let end = max(1, durationSeconds)
        func vtt(_ first: String, _ second: String) -> String {
            "WEBVTT\n\n00:00:00.000 --> \(stamp(half))\n\(first)\n\n\(stamp(half)) --> \(stamp(end))\n\(second)\n"
        }
        try? vtt("مرحبًا من صلة", "هذا فيديو تجريبي").write(to: file(id, "captions-ar.vtt"), atomically: true, encoding: .utf8)
        try? vtt("Hello from Sila", "This is a test video").write(to: file(id, "captions-en.vtt"), atomically: true, encoding: .utf8)
    }

    private func stamp(_ seconds: Double) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "00:%02d:%02d.%03d", millis / 60_000, (millis / 1000) % 60, millis % 1000)
    }

    private nonisolated func file(_ id: UUID, _ name: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-\(name)")
    }

    private func video(_ id: UUID) -> PostVideo {
        guard let stored = state.videos[id] else { return PostVideo(id: id, status: .removed) }
        let ready = stored.status == .ready
        return PostVideo(
            id: id,
            status: stored.status,
            posterURL: ready ? file(id, "poster.jpg") : nil,
            hlsURL: ready ? storedFile(id) : nil,
            durationSeconds: stored.durationSeconds,
            width: 320,
            height: 240,
            captions: ready ? [
                VideoCaptionTrack(language: "ar", url: file(id, "captions-ar.vtt")),
                VideoCaptionTrack(language: "en", url: file(id, "captions-en.vtt")),
            ] : [],
            postId: stored.postId,
            failure: stored.failureCode.map { VideoFailure(code: $0) },
            removedByModerator: stored.status == .removed && stored.removedByModerator == true
        )
    }

    private func plan(_ id: UUID) -> VideoUploadPlan {
        let stored = state.videos[id]
        let size = stored?.sizeBytes ?? 0
        let piece = stored?.pieceSize ?? pieceSize
        let base = "/api/v1/videos/uploads/\(id.uuidString.lowercased())"
        let count = VideoPieces.count(total: size, pieceSize: piece)
        if stored?.type == .parts {
            return VideoUploadPlan(type: .parts, sizeBytes: size, expiresAt: Date().addingTimeInterval(86_400),
                                   statusUrl: base, completeUrl: "/api/v1/videos/\(id.uuidString.lowercased())/complete",
                                   partsUrl: base + "/parts", partSize: piece, partCount: count)
        }
        return VideoUploadPlan(type: .chunked, sizeBytes: size, expiresAt: Date().addingTimeInterval(86_400),
                               statusUrl: base, completeUrl: "/api/v1/videos/\(id.uuidString.lowercased())/complete",
                               url: base, chunkSize: piece, chunkCount: count)
    }

    private func videoId(of plan: VideoUploadPlan) throws -> UUID {
        guard let raw = plan.statusUrl.split(separator: "/").last, let id = UUID(uuidString: String(raw)) else {
            throw APIError.api(code: .videoNotFound, message: "", status: 404)
        }
        return id
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    /// Forgets everything: `-resetVideoUploads`, at the start of a journey.
    public nonisolated static func reset(_ directory: URL = launchDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
