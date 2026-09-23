import AVFoundation

/// A local-file player for listening back to a take before it is sent.
@MainActor
final class AVAudioPlayerBox: NSObject, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let onEnd: () -> Void

    init?(url: URL, onEnd: @escaping () -> Void) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        self.onEnd = onEnd
        super.init()
        player.delegate = self
    }

    func play() -> Bool {
        (try? AudioSessionArbiter.shared.acquireForPlayback()) != nil && player.play()
    }

    func stop() {
        player.stop()
        AudioSessionArbiter.shared.release(.player)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            AudioSessionArbiter.shared.release(.player)
            self.onEnd()
        }
    }
}
