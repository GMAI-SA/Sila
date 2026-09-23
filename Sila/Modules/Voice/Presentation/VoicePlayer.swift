import AVFoundation
import Foundation
import Observation

/// One player for the whole app, so two voice posts never play at once.
///
/// Holds a single `AVPlayer`; starting another clip stops the first. Takes the
/// audio session as `.playback` only while something plays, and gives it up to
/// a voice room the moment one connects.
@MainActor
@Observable
public final class VoicePlayer {

    public static let shared = VoicePlayer()

    public static let speeds: [Float] = [1, 1.5, 2]

    /// The clip loaded, playing or paused.
    public private(set) var currentId: UUID?
    public private(set) var isPlaying = false
    /// 0…1 through the current clip.
    public private(set) var progress: Double = 0
    public private(set) var speed: Float = 1

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var duration: TimeInterval = 0
    private let arbiter: AudioSessionArbiter

    init(arbiter: AudioSessionArbiter = .shared) {
        self.arbiter = arbiter
        arbiter.onYield(.player) { [weak self] in self?.pause() }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.duration > 0 else { return }
                self.progress = min(1, max(0, time.seconds / self.duration))
            }
        }
    }

    public func isCurrent(_ clip: VoiceClip) -> Bool { currentId == clip.id }

    /// Plays or pauses this clip; another clip playing is stopped first.
    public func toggle(_ clip: VoiceClip) {
        if currentId == clip.id {
            isPlaying ? pause() : resume()
            return
        }
        guard let url = clip.audioURL else { return }
        load(url: url, id: clip.id, duration: clip.duration)
        resume()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        arbiter.release(.player)
    }

    /// Jumps to a point, 0…1, in the current clip.
    public func seek(to fraction: Double, in clip: VoiceClip) {
        if currentId != clip.id, let url = clip.audioURL {
            load(url: url, id: clip.id, duration: clip.duration)
        }
        let target = max(0, min(1, fraction)) * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        progress = max(0, min(1, fraction))
    }

    /// 1× → 1.5× → 2× → 1×.
    public func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(index + 1) % Self.speeds.count]
        if isPlaying { player.rate = speed }
    }

    private func load(url: URL, id: UUID, duration: TimeInterval) {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentId = id
        self.duration = duration
        progress = 0
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.progress = 0
                self.player.seek(to: .zero)
                self.arbiter.release(.player)
            }
        }
    }

    private func resume() {
        guard (try? arbiter.acquireForPlayback()) != nil else { return }
        player.playImmediately(atRate: speed)
        isPlaying = true
    }
}
