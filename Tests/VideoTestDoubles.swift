import Foundation
@testable import Sila

/// A preparer with no AVFoundation behind it: it reports the length and
/// shape it is told to, and "compresses" by copying.
final class FakeVideoPreparer: VideoPreparing, @unchecked Sendable {
    var durationSeconds: Double = 12
    var width = 720
    var height = 1280
    var inspectFailure: Error?
    var prepareFailure: Error?
    /// Thrown by the next calls to `prepare`, one each, before
    /// ``prepareFailure`` or success: an export iOS stopped half way.
    var prepareFailures: [Error] = []
    /// Every call to `prepare`, whatever became of it.
    private(set) var attempts = 0
    private(set) var prepared: [URL] = []
    private(set) var trimmedTo: [TimeInterval] = []
    private let lock = NSLock()

    func inspect(_ source: URL) async throws -> VideoSourceInfo {
        if let inspectFailure { throw inspectFailure }
        let size = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.intValue ?? 0
        return VideoSourceInfo(durationSeconds: durationSeconds, sizeBytes: size, width: width, height: height,
                               estimatedBitRate: 1_000_000)
    }

    func prepare(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedVideo {
        let scripted = lock.withLock { () -> Error? in
            attempts += 1
            return prepareFailures.isEmpty ? nil : prepareFailures.removeFirst()
        }
        if let scripted { throw scripted }
        if let prepareFailure { throw prepareFailure }
        progress(0.5)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        lock.withLock { prepared.append(source) }
        progress(1)
        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.intValue ?? 0
        return PreparedVideo(file: destination, sizeBytes: size, durationSeconds: durationSeconds, width: width, height: height)
    }

    func trim(_ source: URL, to destination: URL, seconds: TimeInterval) async throws -> URL {
        lock.withLock { trimmedTo.append(seconds) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        durationSeconds = seconds
        return destination
    }

    func thumbnail(_ source: URL) async -> Data? { Data([0xFF, 0xD8, 0xFF]) }
}

/// ``VideoServiceMock``, with failures scripted per call: each call named
/// here throws the next error on its list before the mock answers.
actor FlakyVideoService: VideoServiceProtocol {
    let inner: VideoServiceMock
    /// `start`, `status`, `chunk`, `targets`, `part`, `complete`, `video`.
    var failures: [String: [APIError]] = [:]
    private(set) var calls: [String] = []

    init(inner: VideoServiceMock) { self.inner = inner }

    func script(_ call: String, _ errors: [APIError]) { failures[call] = errors }

    private func trip(_ call: String) throws {
        calls.append(call)
        if var queue = failures[call], !queue.isEmpty {
            let error = queue.removeFirst()
            failures[call] = queue
            throw error
        }
    }

    func fetchConfig() async throws -> VideoConfig { try await inner.fetchConfig() }

    func startUpload(sizeBytes: Int, durationSeconds: Double, contentType: String) async throws -> VideoUploadStart {
        try trip("start")
        return try await inner.startUpload(sizeBytes: sizeBytes, durationSeconds: durationSeconds, contentType: contentType)
    }

    func uploadStatus(_ plan: VideoUploadPlan) async throws -> VideoUploadStatus {
        try trip("status")
        return try await inner.uploadStatus(plan)
    }

    func sendChunk(_ plan: VideoUploadPlan, number: Int, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try trip("chunk")
        try await inner.sendChunk(plan, number: number, file: file, progress: progress)
    }

    func partTargets(_ plan: VideoUploadPlan, numbers: [Int]) async throws -> [VideoPartTarget] {
        try trip("targets")
        return try await inner.partTargets(plan, numbers: numbers)
    }

    func sendPart(_ target: VideoPartTarget, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try trip("part")
        try await inner.sendPart(target, file: file, progress: progress)
    }

    func complete(_ plan: VideoUploadPlan) async throws -> PostVideo {
        try trip("complete")
        return try await inner.complete(plan)
    }

    func fetchVideo(_ id: UUID) async throws -> PostVideo {
        try trip("video")
        return try await inner.fetchVideo(id)
    }

    func discard(_ id: UUID) async throws {
        try trip("discard")
        try await inner.discard(id)
    }
}

/// A composer that writes posts as the server does: `POST /posts` takes its
/// video on the mocked video server (``VideoServiceMock/claim(_:forPost:)``),
/// so the same video is refused a second time with `409 video_used`.
/// `loseAnswers` posts are written but answered with a timed-out
/// connection, as in a lift: written on the server, never heard of here.
final class CommittingComposerService: ComposerServiceProtocol, @unchecked Sendable {
    let videos: VideoServiceMock
    var loseAnswers = 0
    private(set) var drafts: [PostDraft] = []
    private(set) var written: [Post] = []
    private let lock = NSLock()

    init(videos: VideoServiceMock) { self.videos = videos }

    func createPost(_ draft: PostDraft) async throws -> Post {
        lock.withLock { drafts.append(draft) }
        let id = UUID()
        if let videoId = draft.videoId {
            try await videos.claim(videoId, forPost: id)
        }
        var post = Post(
            id: id,
            author: FeedServiceMock.aziz,
            text: draft.trimmedText,
            createdAt: Date(),
            scope: PostScope(rawValue: draft.scope.wireValue) ?? .international,
            scopeCountry: draft.scope.scopeCountry,
            scopeRegion: draft.scope.scopeRegion,
            replyToPostId: draft.replyToPostId
        )
        post.video = draft.videoId.map { PostVideo(id: $0, status: .processing) }
        let lose = lock.withLock { () -> Bool in
            written.append(post)
            guard loseAnswers > 0 else { return false }
            loseAnswers -= 1
            return true
        }
        if lose { throw APIError.transport("The request timed out.") }
        return post
    }

    func uploadImage(_ data: Data) async throws -> String { "/api/v1/media/posts/committed.jpg" }

    /// `GET /posts/{id}`.
    func post(_ id: UUID) throws -> Post {
        guard let post = lock.withLock({ written.first { $0.id == id } }) else {
            throw APIError.api(code: .postNotFound, message: "", status: 404)
        }
        return post
    }
}

/// Collects what an upload reported, from any thread.
final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [VideoUploadActivity] = []
    private var plans: [VideoUploadCheckpoint?] = []
    private var sleeps: [TimeInterval] = []

    var activities: [VideoUploadActivity] { lock.withLock { entries } }
    var checkpoints: [VideoUploadCheckpoint?] { lock.withLock { plans } }
    var waits: [TimeInterval] { lock.withLock { sleeps } }

    func record(_ activity: VideoUploadActivity) { lock.withLock { entries.append(activity) } }
    func record(_ checkpoint: VideoUploadCheckpoint?) { lock.withLock { plans.append(checkpoint) } }
    func slept(_ seconds: TimeInterval) { lock.withLock { sleeps.append(seconds) } }
}

enum VideoFixtures {
    /// A fresh directory of the test's own.
    static func directory(_ name: String = "video") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `count` bytes that are not all the same, so a piece in the wrong
    /// place shows.
    static func file(bytes count: Int, in directory: URL) throws -> URL {
        var data = Data(count: count)
        for index in 0..<count { data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index / 256) }
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }
}
