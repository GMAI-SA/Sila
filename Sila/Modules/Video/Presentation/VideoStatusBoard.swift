import Foundation
import Observation
import SwiftUI

/// The latest word on the author's own videos, while they wait to be ready.
///
/// A post is written before its video is converted and screened; until then
/// only its author sees it, with where the video stands (contract v28 §5).
/// Every card showing such a video asks the board to watch it, and the board
/// asks `GET /videos/{id}` — every two to three seconds at first, less often
/// after, and every half minute while a moderator has it — until it is ready,
/// failed or removed. One poll per video, however many cards show it.
@MainActor
@Observable
public final class VideoStatusBoard {

    /// The newest copy of each watched video.
    public private(set) var latest: [UUID: PostVideo] = [:]

    private let service: VideoServiceProtocol
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var watchers: [UUID: Int] = [:]
    private var polls: [UUID: Task<Void, Never>] = [:]

    /// Seconds between reads: quickly at first, when a short video is often
    /// ready within the minute, then patiently.
    static let quickInterval: TimeInterval = 2.5
    static let quickPeriod: TimeInterval = 120
    static let slowInterval: TimeInterval = 10
    static let heldInterval: TimeInterval = 30

    public init(
        service: VideoServiceProtocol,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.service = service
        self.sleep = sleep
    }

    /// The freshest copy of `video`: the board's, when it has one.
    public func current(_ video: PostVideo) -> PostVideo {
        latest[video.id] ?? video
    }

    /// A card showing `video` appeared. Starts a poll unless the video is
    /// settled or one is already running.
    public func watch(_ video: PostVideo) {
        watchers[video.id, default: 0] += 1
        let known = current(video)
        guard !known.status.isSettled, polls[video.id] == nil else { return }
        polls[video.id] = Task { [weak self] in await self?.poll(video.id, status: known.status) }
    }

    /// A card showing it went away. The poll stops with the last one.
    public func unwatch(_ id: UUID) {
        let remaining = (watchers[id] ?? 1) - 1
        if remaining <= 0 {
            watchers[id] = nil
            polls[id]?.cancel()
            polls[id] = nil
        } else {
            watchers[id] = remaining
        }
    }

    /// Sign-out, or a test starting again.
    public func reset() {
        polls.values.forEach { $0.cancel() }
        polls = [:]
        watchers = [:]
        latest = [:]
    }

    private func poll(_ id: UUID, status: VideoStatus) async {
        let started = Date()
        var status = status
        var failures = 0
        while !Task.isCancelled {
            let interval: TimeInterval
            if status == .held {
                interval = Self.heldInterval
            } else if Date().timeIntervalSince(started) < Self.quickPeriod {
                interval = Self.quickInterval
            } else {
                interval = Self.slowInterval
            }
            do {
                try await sleep(failures == 0 ? interval : VideoBackoff.delay(attempt: failures, jitter: 0.5) + interval)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            do {
                let fresh = try await service.fetchVideo(id)
                failures = 0
                latest[id] = fresh
                status = fresh.status
                if fresh.status.isSettled { break }
            } catch {
                let api = APIError.wrapping(error)
                if api.isCancellation { break }
                // Gone, or not ours to read: nothing will change.
                if api.code == .videoNotFound || api.code == .notFound { break }
                failures += 1
            }
        }
        polls[id] = nil
    }
}

// MARK: - Environment

private struct VideoStatusBoardKey: EnvironmentKey {
    static let defaultValue: VideoStatusBoard? = nil
}

private struct VideoUploadCenterKey: EnvironmentKey {
    static let defaultValue: VideoUploadCenter? = nil
}

extension EnvironmentValues {
    /// Watches the author's own videos become ready. `nil` — a guest, a
    /// preview — shows each video as the post carried it.
    public var videoStatusBoard: VideoStatusBoard? {
        get { self[VideoStatusBoardKey.self] }
        set { self[VideoStatusBoardKey.self] = newValue }
    }

    /// The uploads on their way, for the strip of posts waiting above the
    /// feed. `nil` draws no strip.
    public var videoUploadCenter: VideoUploadCenter? {
        get { self[VideoUploadCenterKey.self] }
        set { self[VideoUploadCenterKey.self] = newValue }
    }
}
