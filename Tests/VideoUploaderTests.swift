import XCTest
@testable import Sila

/// The upload itself (contract v28 §3, §12): both plan types, every piece in
/// its place, and nothing a dropped connection or a vanished upload does
/// ever stopping it.
final class VideoUploaderTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = VideoFixtures.directory("uploader")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func mock(_ scenario: VideoServiceMock.MockScenario = .success) -> VideoServiceMock {
        VideoServiceMock(scenario: scenario, directory: directory.appendingPathComponent("server"),
                         pieceLatency: 0, readyAfterReads: 1, pieceSize: 1024)
    }

    private func uploader(_ service: VideoServiceProtocol, log: ActivityLog) -> VideoUploader {
        VideoUploader(
            service: service,
            workDirectory: directory.appendingPathComponent("work"),
            sleep: { seconds in log.slept(seconds) },
            jitter: { 1 }
        )
    }

    private func run(
        _ uploader: VideoUploader,
        file: URL,
        size: Int,
        resumeFrom: VideoUploadCheckpoint? = nil,
        log: ActivityLog
    ) async throws -> PostVideo {
        try await uploader.upload(
            file: file,
            sizeBytes: size,
            durationSeconds: 12,
            resumeFrom: resumeFrom,
            onCheckpoint: { log.record($0) },
            onActivity: { log.record($0) }
        )
    }

    // MARK: - Both plans

    func testAChunkedUploadSendsEveryChunkInItsPlaceAndCompletes() async throws {
        let service = mock()
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 5_000, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 5_000, log: log)

        XCTAssertEqual(video.status, .processing)
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), try Data(contentsOf: file),
                       "the server has exactly the bytes sent, each chunk at its offset")
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("chunk") }.count, 5)
        XCTAssertEqual(calls.first, "start")
        XCTAssertEqual(calls.last, "complete")
        XCTAssertEqual(log.checkpoints.compactMap { $0 }.first?.videoId, video.id, "the plan is handed over to be kept")
        XCTAssertTrue(log.activities.contains(.completing))
        let fractions = log.activities.compactMap { activity -> Double? in
            if case .sending = activity { return activity.fraction }
            return nil
        }
        XCTAssertEqual(fractions.last ?? 0, 0.99, accuracy: 0.0001, "progress reaches the end of the bytes")
        XCTAssertTrue(log.waits.isEmpty, "nothing went wrong, so nothing waited")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("work/pieces").path)
        XCTAssertTrue(leftovers.isEmpty, "every piece's file goes once it has gone")
    }

    func testAPartsUploadAsksForTargetsAndSendsStraightToStorage() async throws {
        let service = mock(.parts)
        let log = ActivityLog()
        // Forty-five parts: three batches of signed URLs, twenty at most each.
        let file = try VideoFixtures.file(bytes: 45 * 1024 - 7, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 45 * 1024 - 7, log: log)

        XCTAssertEqual(video.status, .processing)
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), try Data(contentsOf: file))
        let calls = await service.calls
        let targetCalls = calls.filter { $0.hasPrefix("targets") }
        XCTAssertEqual(targetCalls.count, 3, "signed URLs are asked for a batch at a time")
        XCTAssertTrue(targetCalls.allSatisfy { $0.split(separator: ",").count <= VideoLimits.partsPerRequest })
        XCTAssertEqual(calls.filter { $0.hasPrefix("part ") }.count, 45)
        XCTAssertFalse(calls.contains { $0.hasPrefix("chunk") })
    }

    // MARK: - Resuming

    /// The app was killed with the plan kept: only what is missing goes.
    func testAResumedUploadSendsOnlyWhatIsMissing() async throws {
        let service = mock()
        let file = try VideoFixtures.file(bytes: 4_096, in: directory)
        let start = try await service.startUpload(sizeBytes: 4_096, durationSeconds: 12, contentType: "video/mp4")
        // Chunks 1 and 3 arrived before the app went away.
        for number in [1, 3] {
            let piece = directory.appendingPathComponent("piece-\(number)")
            try Data(try Data(contentsOf: file)[((number - 1) * 1024)..<(number * 1024)]).write(to: piece)
            try await service.sendChunk(start.upload, number: number, file: piece, progress: { _ in })
        }

        let log = ActivityLog()
        let video = try await run(
            uploader(service, log: log), file: file, size: 4_096,
            resumeFrom: VideoUploadCheckpoint(plan: start.upload, videoId: start.video.id), log: log
        )

        XCTAssertEqual(video.id, start.video.id, "the same upload, not a new one")
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1, "no new plan")
        XCTAssertEqual(Array(calls.suffix(4)).filter { $0.hasPrefix("chunk") }.sorted(), ["chunk 2", "chunk 4"])
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), try Data(contentsOf: file))
        if case let .sending(sent, total)? = log.activities.first {
            XCTAssertEqual(sent, 2_048, "progress starts from what the server already has")
            XCTAssertEqual(total, 4_096)
        } else {
            XCTFail("the first report is how much is already there")
        }
    }

    /// A connection cut half way through a chunk: the chunk is not kept, the
    /// uploader waits, asks where it stands, and carries on.
    func testADroppedConnectionIsWaitedOutAndResumed() async throws {
        let service = mock(.dropsOnce)
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 3_000, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 3_000, log: log)

        XCTAssertEqual(video.status, .processing)
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), try Data(contentsOf: file))
        XCTAssertEqual(log.waits, [1], "one wait, of a second")
        XCTAssertTrue(log.activities.contains { if case .waiting = $0 { return true }; return false },
                      "the person is told it is waiting, not that it failed")
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "chunk 2" }.count, 2, "the cut chunk is sent again")
        XCTAssertEqual(calls.filter { $0 == "status" }.count, 2, "and the server is asked where it stands first")
    }

    /// `410 upload_expired`: a new plan with the same file, without a word.
    func testAnUploadThatHasGoneStartsAgainSilently() async throws {
        let service = mock(.expiresOnce)
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 2_500, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 2_500, log: log)

        XCTAssertEqual(video.status, .processing)
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 2)
        XCTAssertEqual(log.checkpoints.count, 3, "a plan, then none, then a new one")
        XCTAssertNil(log.checkpoints[1] ?? nil)
        XCTAssertNotEqual(log.checkpoints[0]?.videoId, log.checkpoints[2]?.videoId)
        XCTAssertEqual(log.checkpoints[2]?.videoId, video.id)
        XCTAssertTrue(log.waits.isEmpty, "starting again is not a failure to wait out")
    }

    /// A kept plan the server no longer has at all starts again too.
    func testAKeptPlanTheServerHasForgottenStartsAgain() async throws {
        let service = mock()
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 1_500, in: directory)
        let stale = VideoUploadCheckpoint(
            plan: VideoUploadPlan(type: .chunked, sizeBytes: 1_500, statusUrl: "/api/v1/videos/uploads/\(UUID().uuidString)",
                                  completeUrl: "/c", url: "/u", chunkSize: 1024),
            videoId: UUID()
        )
        let video = try await run(uploader(service, log: log), file: file, size: 1_500, resumeFrom: stale, log: log)
        XCTAssertNotEqual(video.id, stale.videoId)
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), try Data(contentsOf: file))
    }

    func testCompletingWithSomethingMissingSendsItAndCompletesAgain() async throws {
        let service = FlakyVideoService(inner: mock())
        await service.script("complete", [.api(code: .uploadIncomplete, message: "", status: 409)])
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 2_048, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 2_048, log: log)

        XCTAssertEqual(video.status, .processing)
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "complete" }.count, 2)
        XCTAssertTrue(log.waits.isEmpty, "asked again at once")
    }

    func testAPartWhoseSignatureRanOutIsSignedAgain() async throws {
        let service = FlakyVideoService(inner: mock(.parts))
        await service.script("part", [.http(status: 403, message: "Request has expired")])
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 2_048, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 2_048, log: log)

        XCTAssertEqual(video.status, .processing)
        XCTAssertEqual(try Data(contentsOf: (service.inner).storedFile(video.id)), try Data(contentsOf: file))
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "targets" }.count, 2, "fresh URLs for what did not arrive")
    }

    func testAServerPausingForAMomentIsWaitedOut() async throws {
        let service = FlakyVideoService(inner: mock())
        await service.script("chunk", [
            .api(code: .videoUploadUnavailable, message: "", status: 503),
            .http(status: 502, message: "Bad Gateway"),
        ])
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 1_000, in: directory)

        let video = try await run(uploader(service, log: log), file: file, size: 1_000, log: log)

        XCTAssertEqual(video.status, .processing)
        XCTAssertEqual(log.waits, [1, 2], "1, 2, 4 … seconds")
    }

    // MARK: - What stops it

    func testARefusalStopsTheUpload() async throws {
        let service = mock(.notAllowed)
        let log = ActivityLog()
        let file = try VideoFixtures.file(bytes: 1_000, in: directory)
        do {
            _ = try await run(uploader(service, log: log), file: file, size: 1_000, log: log)
            XCTFail("a refusal stops the upload")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .videoNotAllowed)
        }
        XCTAssertTrue(log.waits.isEmpty, "a refusal is not retried")
    }

    /// No connection at all: it waits, longer each time, up to a minute, and
    /// never gives up by itself.
    func testWithNoConnectionItKeepsWaitingAndNeverFails() async throws {
        let service = mock(.offline)
        let file = try VideoFixtures.file(bytes: 1_000, in: directory)
        let waits = ActivityLog()
        let uploader = VideoUploader(
            service: service,
            workDirectory: directory,
            sleep: { seconds in
                waits.slept(seconds)
                // Ten waits is enough to know it would go on waiting.
                if waits.waits.count >= 10 { throw CancellationError() }
            },
            jitter: { 1 }
        )
        do {
            _ = try await uploader.upload(file: file, sizeBytes: 1_000, durationSeconds: 3, resumeFrom: nil,
                                          onCheckpoint: { _ in }, onActivity: { _ in })
            XCTFail("an upload with no connection cannot finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "it only stops because it was stopped: \(error)")
        }
        XCTAssertEqual(waits.waits, [1, 2, 4, 8, 16, 32, 60, 60, 60, 60])
    }

    func testTheContractsReadingOfEachError() {
        typealias D = VideoUploader.Decision
        XCTAssertEqual(VideoUploader.decision(for: .transport("offline")), D.retry)
        XCTAssertEqual(VideoUploader.decision(for: .http(status: 503, message: "")), D.retry)
        XCTAssertEqual(VideoUploader.decision(for: .http(status: 408, message: "")), D.retry)
        XCTAssertEqual(VideoUploader.decision(for: .http(status: 403, message: "")), D.resend, "storage's expired signature")
        XCTAssertEqual(VideoUploader.decision(for: .http(status: 400, message: "")), D.stop)
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .uploadExpired, message: "", status: 410)), D.restart)
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .uploadIncomplete, message: "", status: 409)), D.resend)
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .videoUploadUnavailable, message: "", status: 503)), D.retry)
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .unauthorized, message: "", status: 401)), D.retry,
                       "an access token that ran out mid-upload: the next call refreshes it")
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .videoRateLimited, message: "", status: 429)), D.stop,
                       "twenty a day is a refusal, not a pause")
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .videoTooLong, message: "", status: 400)), D.stop)
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .videoNotAllowed, message: "", status: 403)), D.stop)
        XCTAssertEqual(VideoUploader.decision(for: .api(code: .unknown, message: "", status: 500)), D.retry)
        XCTAssertEqual(VideoUploader.decision(for: .unauthenticated), D.stop)
    }

    func testCancellingStopsItWithoutAWord() async throws {
        let service = VideoServiceMock(scenario: .slow, directory: directory.appendingPathComponent("server"),
                                       pieceLatency: 1.5, pieceSize: 1024)
        let file = try VideoFixtures.file(bytes: 4_000, in: directory)
        let uploader = VideoUploader(service: service, workDirectory: directory)
        let task = Task {
            try await uploader.upload(file: file, sizeBytes: 4_000, durationSeconds: 3, resumeFrom: nil,
                                      onCheckpoint: { _ in }, onActivity: { _ in })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled upload does not finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
