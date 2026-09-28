import Foundation

/// Where an upload is, as the person sees it.
public enum VideoUploadActivity: Equatable, Sendable {
    /// Bytes on their way: those the server has plus those in flight.
    case sending(sent: Int, total: Int)
    /// The connection dropped or the server paused for a moment; the upload
    /// carries on by itself. `sent` is what was already there.
    case waiting(sent: Int, total: Int)
    /// Every byte is there; the server is being told.
    case completing

    /// 0…1, for the progress line. Never 1 before the server has said so.
    public var fraction: Double {
        switch self {
        case let .sending(sent, total), let .waiting(sent, total):
            guard total > 0 else { return 0 }
            return min(0.99, Double(sent) / Double(total))
        case .completing:
            return 0.99
        }
    }
}

/// What must be kept on the device to resume an upload after anything,
/// the app being killed included (contract v28 §3.1).
public struct VideoUploadCheckpoint: Codable, Equatable, Sendable {
    public let plan: VideoUploadPlan
    public let videoId: UUID

    public init(plan: VideoUploadPlan, videoId: UUID) {
        self.plan = plan
        self.videoId = videoId
    }
}

/// Sends one prepared file to the server as its plan says, and completes it.
///
/// Both plan types (contract v28 §3): `chunked` sends 5 MiB chunks to the API
/// with `Content-Range`; `parts` asks for signed URLs and sends 8 MiB parts
/// straight to storage. Either way it asks the server where the upload stands
/// first, so a resumed upload sends only what is missing, in any order.
///
/// It never gives up on something that passes: a dropped connection, a
/// timeout or a `503` waits 1, 2, 4 … up to 60 seconds, with jitter, then asks
/// again and carries on. An upload the server has let go (`410`) starts again
/// with the same file, without a word. Only a refusal — a `4xx` that is not
/// about the upload's own state — stops it.
public actor VideoUploader {

    /// What to do after an error.
    enum Decision: Equatable {
        /// Wait, then ask where the upload stands and carry on.
        case retry
        /// Ask where it stands and send what is missing, now.
        case resend
        /// The upload has gone; start a new plan with the same file.
        case restart
        /// A refusal: stop and say why.
        case stop
    }

    private let service: VideoServiceProtocol
    private let workDirectory: URL
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double

    /// New plans in a row before an upload that keeps vanishing is given up.
    static let maximumRestarts = 3
    /// Immediate re-sends in a row before they wait like any other retry.
    static let maximumResends = 3

    /// - Parameters:
    ///   - service: The server.
    ///   - workDirectory: Where each piece's file is written before it is
    ///     sent (a background session uploads from files only).
    ///   - sleep: Waits between retries. Tests pass one that returns at once.
    ///   - jitter: 0…1, spreading retries out.
    public init(
        service: VideoServiceProtocol,
        workDirectory: URL,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.service = service
        self.workDirectory = workDirectory
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Uploads `file` and completes it.
    ///
    /// - Parameters:
    ///   - file: The prepared video, exactly `sizeBytes` long.
    ///   - resumeFrom: The plan kept from before, when there is one.
    ///   - onCheckpoint: Told every time the plan changes — a new one, or
    ///     `nil` when the old one has gone — so it can be kept on disk.
    ///   - onActivity: Told how far along it is.
    /// - Returns: The video, `processing` (or later).
    public func upload(
        file: URL,
        sizeBytes: Int,
        durationSeconds: Double,
        resumeFrom: VideoUploadCheckpoint?,
        onCheckpoint: @escaping @Sendable (VideoUploadCheckpoint?) async -> Void,
        onActivity: @escaping @Sendable (VideoUploadActivity) -> Void
    ) async throws -> PostVideo {
        var checkpoint = resumeFrom
        var failures = 0
        var resends = 0
        var restarts = 0
        var lastSent = 0

        while true {
            try Task.checkCancellation()
            do {
                let current: VideoUploadCheckpoint
                if let checkpoint {
                    current = checkpoint
                } else {
                    let start = try await service.startUpload(
                        sizeBytes: sizeBytes,
                        durationSeconds: durationSeconds,
                        contentType: "video/mp4"
                    )
                    current = VideoUploadCheckpoint(plan: start.upload, videoId: start.video.id)
                    checkpoint = current
                    await onCheckpoint(current)
                }
                let plan = current.plan

                let status = try await service.uploadStatus(plan)
                if status.complete || status.video.status != .uploading {
                    // Complete already — perhaps by this very call before the
                    // app was killed — or gone, which completing will say.
                    onActivity(.completing)
                    return try await service.complete(plan)
                }

                let missing = VideoPieces.missing(in: status, plan: plan)
                let pending = missing.reduce(0) {
                    $0 + VideoPieces.range(number: $1, total: plan.sizeBytes, pieceSize: plan.pieceSize).count
                }
                lastSent = max(0, plan.sizeBytes - pending)
                onActivity(.sending(sent: lastSent, total: plan.sizeBytes))
                if !missing.isEmpty {
                    try await send(missing, of: file, plan: plan, alreadySent: lastSent, onActivity: onActivity)
                }
                onActivity(.completing)
                let video = try await service.complete(plan)
                return video
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let api = APIError.wrapping(error)
                if api == .cancelled { throw CancellationError() }
                switch Self.decision(for: api) {
                case .stop:
                    throw api
                case .restart:
                    restarts += 1
                    guard restarts <= Self.maximumRestarts else { throw api }
                    checkpoint = nil
                    failures = 0
                    await onCheckpoint(nil)
                case .resend where resends < Self.maximumResends:
                    resends += 1
                case .resend, .retry:
                    failures += 1
                    onActivity(.waiting(sent: lastSent, total: sizeBytes))
                    try await sleep(VideoBackoff.delay(attempt: failures, jitter: jitter()))
                }
            }
        }
    }

    /// Reads an error the way the contract says to (§12): only a `4xx` other
    /// than `409 upload_incomplete` and `410` stops an upload.
    static func decision(for error: APIError) -> Decision {
        switch error {
        case .transport, .decoding:
            return .retry
        case .cancelled:
            return .stop
        case .unauthenticated, .biometricFailed, .detailsMismatch:
            return .stop
        case let .http(status, _):
            // Storage answers a part whose signature has run out with 403:
            // ask for a fresh one.
            if status == 403 { return .resend }
            return retryable(status) ? .retry : .stop
        case let .api(code, _, status):
            switch code {
            case .uploadExpired, .videoNotFound:
                return .restart
            case .uploadIncomplete, .uploadTypeMismatch:
                // Something is missing, or the upload is already complete:
                // either way, ask where it stands.
                return .resend
            case .videoUploadUnavailable, .rateLimited, .unauthorized:
                return .retry
            case .videoRateLimited:
                // Twenty uploads a day is a limit, not a pause: waiting a
                // minute would not change it.
                return .stop
            default:
                return retryable(status) ? .retry : .stop
            }
        }
    }

    private static func retryable(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 401 || status == 429 || status == 499
    }

    // MARK: - Pieces

    /// Sends every missing piece, all at once: the transport keeps two on the
    /// wire and queues the rest, and in the app they carry on while it is
    /// suspended. A piece that fails does not stop the others; the first
    /// failure is thrown once they have all finished.
    private func send(
        _ numbers: [Int],
        of file: URL,
        plan: VideoUploadPlan,
        alreadySent: Int,
        onActivity: @escaping @Sendable (VideoUploadActivity) -> Void
    ) async throws {
        let tracker = PieceTracker(base: alreadySent, total: plan.sizeBytes, report: onActivity)
        switch plan.type {
        case .chunked:
            var pieces: [(Int, URL)] = []
            for number in numbers {
                pieces.append((number, try writePiece(number, of: file, plan: plan)))
            }
            try await sendAll(pieces, tracker: tracker) { [service] number, piece, progress in
                try await service.sendChunk(plan, number: number, file: piece, progress: progress)
            }
        case .parts:
            // Signed URLs are good for fifteen minutes, so they are asked
            // for a batch at a time, just before the batch goes.
            var index = 0
            while index < numbers.count {
                let batch = Array(numbers[index..<min(index + VideoLimits.partsPerRequest, numbers.count)])
                index += batch.count
                let targets = try await service.partTargets(plan, numbers: batch)
                var byNumber: [Int: VideoPartTarget] = [:]
                targets.forEach { byNumber[$0.number] = $0 }
                var pieces: [(Int, URL)] = []
                for number in batch where byNumber[number] != nil {
                    pieces.append((number, try writePiece(number, of: file, plan: plan)))
                }
                let signed = byNumber
                try await sendAll(pieces, tracker: tracker) { [service] number, piece, progress in
                    guard let target = signed[number] else { return }
                    try await service.sendPart(target, file: piece, progress: progress)
                }
            }
        }
    }

    private func sendAll(
        _ pieces: [(Int, URL)],
        tracker: PieceTracker,
        send: @escaping @Sendable (Int, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
    ) async throws {
        let failure: Error? = await withTaskGroup(of: Error?.self) { group in
            for (number, piece) in pieces {
                group.addTask {
                    defer { try? FileManager.default.removeItem(at: piece) }
                    do {
                        try await send(number, piece) { sent in tracker.update(number, sent: Int(sent)) }
                        tracker.finish(number, size: Self.size(of: piece))
                        return nil
                    } catch {
                        tracker.update(number, sent: 0)
                        return error
                    }
                }
            }
            var first: Error?
            for await result in group {
                if let result, first == nil || first is CancellationError { first = result }
            }
            return first
        }
        if let failure { throw failure }
    }

    private static func size(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Copies piece `number` of `file` into a file of its own.
    private func writePiece(_ number: Int, of file: URL, plan: VideoUploadPlan) throws -> URL {
        let range = VideoPieces.range(number: number, total: plan.sizeBytes, pieceSize: plan.pieceSize)
        let directory = workDirectory.appendingPathComponent("pieces", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let piece = directory.appendingPathComponent("\(UUID().uuidString)-\(number).part")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try handle.read(upToCount: range.count) ?? Data()
        guard data.count == range.count else {
            // The file on disk is not the one the plan was made for.
            throw APIError.api(code: .uploadChunkInvalid, message: "", status: 400)
        }
        try data.write(to: piece, options: .atomic)
        return piece
    }
}

/// Adds up the bytes of the pieces in flight, and says so when the whole
/// number of percent changes — often enough for a progress line, not so
/// often that the screen redraws for every packet.
final class PieceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let base: Int
    private let total: Int
    private let report: @Sendable (VideoUploadActivity) -> Void
    private var inFlight: [Int: Int] = [:]
    private var done = 0
    private var lastPercent = -1

    init(base: Int, total: Int, report: @escaping @Sendable (VideoUploadActivity) -> Void) {
        self.base = base
        self.total = total
        self.report = report
    }

    func update(_ number: Int, sent: Int) {
        lock.lock()
        inFlight[number] = sent
        let activity = snapshot()
        lock.unlock()
        if let activity { report(activity) }
    }

    /// A piece arrived: all of its bytes count, whatever the last progress
    /// report said.
    func finish(_ number: Int, size: Int) {
        lock.lock()
        let reported = inFlight.removeValue(forKey: number) ?? 0
        done += max(size, reported)
        let activity = snapshot()
        lock.unlock()
        if let activity { report(activity) }
    }

    /// Under the lock.
    private func snapshot() -> VideoUploadActivity? {
        let sent = min(total, base + done + inFlight.values.reduce(0, +))
        let percent = total > 0 ? sent * 100 / total : 0
        guard percent != lastPercent else { return nil }
        lastPercent = percent
        return .sending(sent: sent, total: total)
    }
}
