import Foundation
import Observation
import UIKit

/// Where one upload is, for the composer and the feed.
public enum VideoUploadPhase: Equatable, Sendable {
    /// Being compressed on the phone, 0…1.
    case preparing(Double)
    /// On its way to the server.
    case uploading(VideoUploadActivity)
    /// On the server and complete: ready to post.
    case uploaded(PostVideo)
    /// The post is being written.
    case posting
    /// Stopped. Only a refusal gets here; a dropped connection never does.
    case failed(VideoUploadFailure)

    /// Whether the phone is still working on it.
    public var isWorking: Bool {
        switch self {
        case .preparing, .uploading, .posting: return true
        case .uploaded, .failed: return false
        }
    }
}

/// Why an upload stopped, in words, and whether trying again can help.
public struct VideoUploadFailure: Equatable, Sendable {
    public let message: String
    public let canRetry: Bool
    /// The server's code, for analytics; `nil` for the phone's own reasons.
    public let code: String?

    public init(message: String, canRetry: Bool, code: String? = nil) {
        self.message = message
        self.canRetry = canRetry
        self.code = code
    }
}

/// Every video on its way from a composer to a post.
///
/// App-wide rather than the composer's, because an upload outlives the
/// sheet: somebody may press Post while the video is still going up, close
/// the app, lose the connection in a lift, and the post must still appear,
/// once, when the video is there. Each job is kept on disk (see
/// ``VideoUploadStore``) with its plan, so a relaunch resumes it instead of
/// starting again.
///
/// A job the person has not posted yet belongs to its composer; one left
/// behind by a relaunch has no composer to go back to, so it is let go.
///
/// Nothing a person does with the phone meanwhile ends a job for good.
/// Compressing that iOS stops because the app went to the background starts
/// again when the app is back (``sceneDidBecomeActive()``). A post whose
/// first try was written but whose answer was lost is found and shown rather
/// than refused, and a video the server let go before its post was written
/// goes up again from the file kept here.
@MainActor
@Observable
public final class VideoUploadCenter {

    /// Jobs of the signed-in account, oldest first.
    public private(set) var jobs: [VideoUploadJob] = []
    public private(set) var phases: [UUID: VideoUploadPhase] = [:]
    /// The server's limits, once read.
    public private(set) var config: VideoConfig?
    /// Told about each post written for a video that finished after its
    /// composer had closed, so the feed shows it. A post written before
    /// anybody was listening — straight after a relaunch — is told as soon
    /// as somebody is.
    public var onPosted: (@MainActor ([Post]) -> Void)? {
        didSet {
            guard let onPosted, !unannounced.isEmpty else { return }
            let posts = unannounced
            unannounced = []
            onPosted(posts)
        }
    }
    private var unannounced: [Post] = []

    private let service: VideoServiceProtocol
    private let preparer: VideoPreparing
    private let composer: ComposerServiceProtocol
    private let store: VideoUploadStore
    private let analytics: AnalyticsClient
    private let uploader: VideoUploader
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let stopTransfers: @Sendable () async -> Void
    private let fetchPost: (@Sendable (UUID) async throws -> Post)?
    private let isActive: @MainActor () -> Bool
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var accountId: UUID?
    /// Jobs whose compressing iOS stopped while the app was away, to start
    /// again when it is back.
    private var awaitingForeground: Set<UUID> = []
    /// Compressing stopped on screen, in a row, per job.
    private var interruptionsOnScreen: [UUID: Int] = [:]
    /// Times a job's video went up again because the server had let the
    /// last one go before its post was written.
    private var reuploads: [UUID: Int] = [:]

    /// Compressing stopped on screen this many times in a row — the media
    /// services restarting — is started again by itself; once more, and
    /// the person is offered Retry.
    static let maximumInterruptionsOnScreen = 2

    /// - Parameters:
    ///   - stopTransfers: Cancels every piece in flight — the transport's
    ///     ``VideoUploadTransport/cancelAll()``.
    ///   - fetchPost: Reads one post, for a post an earlier try wrote whose
    ///     answer never arrived, so the feed can show it. Without it that
    ///     post is still counted as written; the feed shows it on its next
    ///     refresh.
    ///   - isActive: Whether the app is on screen. Tests say.
    ///   - sleep: Waits between retries; tests pass one that returns at once.
    public init(
        service: VideoServiceProtocol,
        preparer: VideoPreparing,
        composer: ComposerServiceProtocol,
        store: VideoUploadStore = VideoUploadStore(),
        analytics: AnalyticsClient,
        stopTransfers: @escaping @Sendable () async -> Void = {},
        fetchPost: (@Sendable (UUID) async throws -> Post)? = nil,
        isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.service = service
        self.preparer = preparer
        self.composer = composer
        self.store = store
        self.analytics = analytics
        self.stopTransfers = stopTransfers
        self.fetchPost = fetchPost
        self.isActive = isActive
        self.sleep = sleep
        self.uploader = VideoUploader(service: service, workDirectory: store.directory, sleep: sleep)
    }

    // MARK: - Reading

    public func job(_ id: UUID) -> VideoUploadJob? {
        jobs.first { $0.id == id }
    }

    public func phase(_ id: UUID) -> VideoUploadPhase? {
        phases[id]
    }

    /// Posts waiting for their video, for the strip above the feed.
    public var pendingPosts: [VideoUploadJob] {
        jobs.filter { $0.pendingPost != nil }
    }

    /// The composer's thumbnail for a job.
    public func thumbnail(_ id: UUID) -> Data? {
        guard let name = job(id)?.thumbnailFileName else { return nil }
        return try? Data(contentsOf: store.url(for: name))
    }

    /// The longest video the server takes, in seconds.
    public var maximumDuration: TimeInterval {
        config?.maxDurationSeconds ?? VideoLimits.maximumDuration
    }

    /// Reads `/config` once. Silent on failure: the contract's own numbers
    /// stand in.
    public func loadConfig() async {
        guard config == nil else { return }
        config = try? await service.fetchConfig()
    }

    // MARK: - The composer's side

    /// Measures a picked file.
    public func inspect(_ source: URL) async throws -> VideoSourceInfo {
        try await preparer.inspect(source)
    }

    /// The first three minutes of a longer video, for when the system's
    /// trimming screen is not there.
    public func firstMinutes(of source: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sila-trim-\(UUID().uuidString).mp4")
        return try await preparer.trim(source, to: destination, seconds: VideoLimits.trimDuration)
    }

    /// Starts on a picked video at once: compressed, then uploaded, while
    /// the person writes. Uploaded on choosing rather than on Post, so by the
    /// time they have written a sentence it is usually there.
    /// - Returns: The job's id, which the composer holds.
    @discardableResult
    public func begin(source: URL, info: VideoSourceInfo) -> UUID? {
        guard let accountId else { return nil }
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let name = "\(id.uuidString)-source.\(ext)"
        guard (try? store.adopt(source, as: name)) != nil else {
            return nil
        }
        let job = VideoUploadJob(
            id: id,
            accountId: accountId,
            sourceFileName: name,
            sizeBytes: info.sizeBytes,
            durationSeconds: info.durationSeconds,
            width: info.width,
            height: info.height
        )
        jobs.append(job)
        phases[id] = .preparing(0)
        save()
        analytics.track(.videoPicked, properties: ["result": "ok"])
        run(id)
        Task { [weak self] in await self?.makeThumbnail(id) }
        return id
    }

    /// Tries a stopped job again, from wherever it had got to.
    public func retry(_ id: UUID) {
        guard job(id) != nil, !(phases[id]?.isWorking ?? false) else { return }
        phases[id] = nil
        run(id)
    }

    /// The person took the video off, or gave up the draft: every file goes,
    /// here and on the server.
    public func discard(_ id: UUID) {
        guard let job = job(id) else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        let videoId = job.uploadedVideoId ?? job.checkpoint?.videoId
        remove(id)
        if let videoId {
            // Best effort: a draft never posted is removed by the server
            // within a day anyway.
            Task { [service] in try? await service.discard(videoId) }
        }
    }

    /// The composer posted this video itself: nothing is left to do.
    public func didPost(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        remove(id)
        analytics.track(.videoPosted)
    }

    /// Post as soon as the video is there. The composer closes; the post
    /// appears in the feed once written, and until then the strip above the
    /// feed says how far the upload is.
    public func post(_ id: UUID, _ pending: PendingVideoPost) {
        guard var job = job(id) else { return }
        job.pendingPost = pending
        replace(job)
        save()
        switch phases[id] {
        case let .uploaded(video)?:
            tasks[id] = Task { [weak self] in await self?.publish(id, video: video) }
        case .failed?:
            retry(id)
        case nil:
            run(id)
        default:
            // Still going: the run posts it when it is done.
            break
        }
    }

    // MARK: - Lifecycle

    /// Picks up where the last launch left off, for this account.
    ///
    /// A job with a post waiting is resumed. A job without one belonged to a
    /// composer that is gone, so it is discarded — the server removes a
    /// video never posted within a day in any case.
    ///
    /// Pieces written for an upload before the last process ended go too.
    /// Only the upload that wrote a piece ever sends or deletes it, and that
    /// upload is gone; the resumed one asks the server what is missing and
    /// writes those afresh. Kept, each interrupted upload would leave up to
    /// a whole video's worth of files behind.
    public func restore(accountId: UUID?) {
        guard accountId != self.accountId else { return }
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        phases = [:]
        forgetInterruptions()
        store.remove([VideoUploader.piecesFolder])
        self.accountId = accountId
        guard let accountId else {
            jobs = []
            return
        }
        let stored = store.load()
        var kept: [VideoUploadJob] = []
        for job in stored {
            if job.accountId == accountId, job.pendingPost != nil {
                kept.append(job)
            } else {
                store.remove(job.fileNames)
                if job.accountId == accountId, let videoId = job.uploadedVideoId ?? job.checkpoint?.videoId {
                    Task { [service] in try? await service.discard(videoId) }
                }
            }
        }
        jobs = kept
        save()
        kept.forEach { run($0.id) }
    }

    /// The app is on screen again. Compressing that iOS stopped while it was
    /// away starts again, from the picked file, which is kept until the
    /// compressed one is made.
    public func sceneDidBecomeActive() {
        let waiting = awaitingForeground
        awaitingForeground = []
        for id in waiting where job(id) != nil {
            interruptionsOnScreen[id] = nil
            run(id)
        }
    }

    /// Sign-out: nothing of the account's is kept or sent any further.
    public func forgetAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        jobs = []
        phases = [:]
        forgetInterruptions()
        accountId = nil
        store.removeAll()
        Task { [stopTransfers] in await stopTransfers() }
    }

    // MARK: - The run

    private func run(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in await self?.drive(id) }
    }

    private func drive(_ id: UUID) async {
        do {
            let file = try await prepareIfNeeded(id)
            guard let job = job(id) else { return }

            let video: PostVideo
            if let uploaded = job.uploadedVideoId {
                video = PostVideo(id: uploaded, status: .processing, durationSeconds: job.durationSeconds,
                                  width: job.width, height: job.height)
            } else {
                phases[id] = .uploading(.sending(sent: 0, total: job.sizeBytes))
                video = try await uploader.upload(
                    file: file,
                    sizeBytes: job.sizeBytes,
                    durationSeconds: job.durationSeconds,
                    resumeFrom: job.checkpoint,
                    onCheckpoint: { [weak self] checkpoint in
                        await self?.update(id) { $0.checkpoint = checkpoint }
                    },
                    onActivity: { [weak self] activity in
                        Task { @MainActor [weak self] in self?.report(id, activity) }
                    }
                )
                try Task.checkCancellation()
                update(id) {
                    $0.uploadedVideoId = video.id
                    $0.checkpoint = nil
                }
            }
            phases[id] = .uploaded(video)
            if self.job(id)?.pendingPost != nil {
                await publish(id, video: video)
            }
        } catch is CancellationError {
            return
        } catch VideoPreparationError.interrupted {
            guard !Task.isCancelled, job(id) != nil else { return }
            interrupted(id)
        } catch {
            guard !Task.isCancelled, job(id) != nil else { return }
            fail(id, error)
        }
    }

    /// Compressing was stopped by something other than the person. Away
    /// from the screen the job waits, still "getting ready", for the app to
    /// come back, and starts again then. On screen — the media services
    /// restarted — it starts again at once, and only after that has
    /// happened a few times in a row is the person offered Retry.
    private func interrupted(_ id: UUID) {
        guard isActive() else {
            awaitingForeground.insert(id)
            return
        }
        let count = (interruptionsOnScreen[id] ?? 0) + 1
        interruptionsOnScreen[id] = count
        if count <= Self.maximumInterruptionsOnScreen {
            run(id)
        } else {
            interruptionsOnScreen[id] = nil
            fail(id, VideoPreparationError.interrupted)
        }
    }

    /// Compresses the picked file, unless that is done already.
    private func prepareIfNeeded(_ id: UUID) async throws -> URL {
        guard let job = job(id) else { throw CancellationError() }
        if let name = job.fileName {
            let file = store.url(for: name)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        guard let sourceName = job.sourceFileName else {
            throw VideoPreparationError.unreadable
        }
        phases[id] = .preparing(0)
        let name = "\(id.uuidString).mp4"
        let prepared = try await preparer.prepare(store.url(for: sourceName), to: store.url(for: name)) { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard case .preparing? = self?.phases[id] else { return }
                self?.phases[id] = .preparing(fraction)
            }
        }
        try Task.checkCancellation()
        interruptionsOnScreen[id] = nil
        update(id) {
            $0.fileName = name
            $0.sourceFileName = nil
            $0.sizeBytes = prepared.sizeBytes
            $0.durationSeconds = prepared.durationSeconds
            $0.width = prepared.width
            $0.height = prepared.height
        }
        store.remove([sourceName])
        return prepared.file
    }

    /// Writes the post that waited for this video.
    ///
    /// The person has already pressed Post, so a dropped connection here is
    /// waited out like one during the upload; only a refusal stops it. A
    /// refusal saying the video is on a post already, or has gone, is not
    /// what it seems, and is settled with the server first (see
    /// ``settle(_:videoId:)``). The time iOS lends an app keeps this going
    /// if the app is switched away from just now.
    private func publish(_ id: UUID, video: PostVideo) async {
        guard let pending = job(id)?.pendingPost else { return }
        phases[id] = .posting
        let time = VideoBackgroundTime.begin("Posting a video")
        defer { time.finish() }
        var attempt = 0
        while !Task.isCancelled {
            do {
                var post = try await composer.createPost(pending.draft(videoId: video.id))
                // The server's post carries the video; a copy that does not
                // (an older mock, a partial answer) is given the one sent.
                if post.video == nil { post.video = video }
                finishPosting(id, post)
                return
            } catch {
                let api = APIError.wrapping(error)
                if api.isCancellation { return }
                if let code = api.code, [APIErrorCode.videoUsed, .videoRemoved, .uploadExpired].contains(code) {
                    switch await settle(api, videoId: video.id) {
                    case let .written(post):
                        guard !Task.isCancelled else { return }
                        finishPosting(id, post)
                    case .uploadAgain:
                        if !uploadAgain(id) { fail(id, api) }
                    case .refused:
                        fail(id, api)
                    case .cancelled:
                        break
                    }
                    return
                }
                switch VideoUploader.decision(for: api) {
                case .retry:
                    attempt += 1
                    try? await sleep(VideoBackoff.delay(attempt: attempt, jitter: Double.random(in: 0...1)))
                default:
                    fail(id, api)
                    return
                }
            }
        }
    }

    /// What became of a video the post could not take, as the server tells
    /// its owner.
    private enum Settled {
        /// It is on a post already: this one, written by an earlier try.
        /// The post, when it could be read.
        case written(Post?)
        /// It went, and not by a moderator: send the file again.
        case uploadAgain
        /// The refusal stands.
        case refused
        /// The job was let go meanwhile.
        case cancelled
    }

    /// Asks the server what became of the video before a refusal is shown.
    ///
    /// `409 video_used` after a try whose answer was lost — a lift, a
    /// timeout, the app killed straight after — means that try was written:
    /// only its owner's own post can hold the video. `409 video_removed`
    /// means the video went before the post was: the daily sweep of videos
    /// nobody posted (the app was suspended between the upload and the post
    /// for more than a day), or the upload running out. Neither is anything
    /// the person did, so neither is shown. A moderator's removal is, in the
    /// words it already has.
    private func settle(_ refusal: APIError, videoId: UUID) async -> Settled {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let current = try await service.fetchVideo(videoId)
                if refusal.code == .videoUsed {
                    guard let postId = current.postId else { return .refused }
                    return .written(await writtenPost(postId, video: current))
                }
                switch current.status {
                case .removed:
                    return current.removedByModerator ? .refused : .uploadAgain
                case .failed:
                    return current.failure?.code == APIErrorCode.uploadExpired.rawValue ? .uploadAgain : .refused
                default:
                    return .refused
                }
            } catch {
                let api = APIError.wrapping(error)
                if api.isCancellation { return .cancelled }
                if api.code == .videoNotFound {
                    return refusal.code == .videoUsed ? .refused : .uploadAgain
                }
                guard VideoUploader.decision(for: api) == .retry else { return .refused }
                attempt += 1
                try? await sleep(VideoBackoff.delay(attempt: attempt, jitter: Double.random(in: 0...1)))
            }
        }
        return .cancelled
    }

    /// The post an earlier try wrote, for the feed. `nil` when it cannot be
    /// read — it has been deleted since, or the connection is not there —
    /// which leaves the video posted all the same: the job is done.
    private func writtenPost(_ postId: UUID, video: PostVideo) async -> Post? {
        guard let fetchPost else { return nil }
        for attempt in 1...Self.postReads {
            do {
                var post = try await fetchPost(postId)
                if post.video == nil { post.video = video }
                return post
            } catch {
                let api = APIError.wrapping(error)
                guard !api.isCancellation, VideoUploader.decision(for: api) == .retry, attempt < Self.postReads else {
                    return nil
                }
                try? await sleep(VideoBackoff.delay(attempt: attempt, jitter: Double.random(in: 0...1)))
            }
        }
        return nil
    }

    /// Tries at reading a post an earlier try wrote.
    static let postReads = 4

    /// Sends the kept file again as a new video, and writes the post when
    /// it is there, as if the first had never been.
    /// - Returns: `false` when the file is gone too, or the video has had to
    ///   go up again too many times already.
    private func uploadAgain(_ id: UUID) -> Bool {
        guard let name = job(id)?.fileName,
              FileManager.default.fileExists(atPath: store.url(for: name).path) else { return false }
        let count = (reuploads[id] ?? 0) + 1
        guard count <= VideoUploader.maximumRestarts else { return false }
        reuploads[id] = count
        update(id) {
            $0.uploadedVideoId = nil
            $0.checkpoint = nil
        }
        run(id)
        return true
    }

    /// The post is written: the job is done, and the feed is told.
    private func finishPosting(_ id: UUID, _ post: Post?) {
        remove(id)
        analytics.track(.videoPosted)
        guard let post else { return }
        if let onPosted {
            onPosted([post])
        } else {
            unannounced.append(post)
        }
    }

    private func report(_ id: UUID, _ activity: VideoUploadActivity) {
        // A late report never takes an upload back from done, and progress
        // never runs backwards while it is sending.
        guard case let .uploading(current)? = phases[id] else { return }
        if case .sending = activity, case .sending = current, activity.fraction < current.fraction { return }
        phases[id] = .uploading(activity)
    }

    private func fail(_ id: UUID, _ error: Error) {
        let failure = Self.failure(for: error)
        phases[id] = .failed(failure)
        analytics.track(.videoUploadFailed, properties: ["code": failure.code ?? "device"])
    }

    /// The words for a stopped upload, and whether trying again can help.
    static func failure(for error: Error) -> VideoUploadFailure {
        if let preparation = error as? VideoPreparationError {
            switch preparation {
            case .tooLarge:
                return VideoUploadFailure(message: L10n.t("video.error.tooLarge"), canRetry: false)
            case .interrupted:
                return VideoUploadFailure(message: L10n.t("video.error.prepareInterrupted"), canRetry: true)
            case .unreadable:
                return VideoUploadFailure(message: L10n.t("video.error.unreadable"), canRetry: false)
            }
        }
        let api = APIError.wrapping(error)
        let code = api.code
        let final: Set<APIErrorCode> = [
            .videoTooLong, .videoTooLarge, .videoNotAllowed, .selfVerificationRequired, .unverified,
            .identityHold, .videoProcessingFailed, .videoRemoved, .invalidVideo, .videoUsed, .videoWithMedia,
        ]
        let canRetry = code.map { !final.contains($0) } ?? true
        return VideoUploadFailure(message: api.userMessage, canRetry: canRetry, code: code?.rawValue)
    }

    // MARK: - Bookkeeping

    private func makeThumbnail(_ id: UUID) async {
        // From the picked file, or — when compressing finished first and
        // the picked file has gone — from the prepared one.
        var data: Data?
        for name in [job(id)?.sourceFileName, job(id)?.fileName].compactMap({ $0 }) where data == nil {
            data = await preparer.thumbnail(store.url(for: name))
        }
        if data == nil, let name = job(id)?.fileName {
            data = await preparer.thumbnail(store.url(for: name))
        }
        guard let data, job(id) != nil else { return }
        let thumbnail = "\(id.uuidString).jpg"
        store.write(data, as: thumbnail)
        update(id) { $0.thumbnailFileName = thumbnail }
    }

    private func update(_ id: UUID, _ change: (inout VideoUploadJob) -> Void) {
        guard var job = job(id) else { return }
        change(&job)
        replace(job)
        save()
    }

    private func replace(_ job: VideoUploadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
    }

    private func remove(_ id: UUID) {
        guard let job = job(id) else { return }
        store.remove(job.fileNames)
        jobs.removeAll { $0.id == id }
        phases[id] = nil
        tasks[id] = nil
        awaitingForeground.remove(id)
        interruptionsOnScreen[id] = nil
        reuploads[id] = nil
        save()
    }

    private func forgetInterruptions() {
        awaitingForeground = []
        interruptionsOnScreen = [:]
        reuploads = [:]
    }

    private func save() {
        store.save(jobs)
    }
}
