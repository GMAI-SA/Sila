import AVFoundation
import Foundation

/// Records one's own voice post. Behind a protocol so tests drive a fake:
/// the simulator has no microphone worth testing against.
@MainActor
public protocol VoiceRecording: AnyObject {
    /// Asks for the microphone, if not already granted.
    func requestPermission() async -> Bool
    /// Starts a fresh recording, discarding any earlier take.
    func start() throws
    /// Stops and returns the file, or `nil` if nothing was recorded.
    func stop() -> URL?
    /// Throws the take away.
    func discard()
    /// 0…1, for the level bars. Read while recording.
    var level: Float { get }
    /// Seconds recorded so far.
    var elapsed: TimeInterval { get }
    var isRecording: Bool { get }
    /// Called when the recording ends by itself — a phone call, a room, the
    /// cap — with the file kept so far.
    var onInterrupted: ((URL?) -> Void)? { get set }
}

/// The real recorder: mono AAC in an .m4a, metered for the level bars. The
/// server re-encodes and strips metadata anyway; this only needs to be audio.
@MainActor
public final class SystemVoiceRecorder: NSObject, VoiceRecording, AVAudioRecorderDelegate {

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private let arbiter: AudioSessionArbiter
    public var onInterrupted: ((URL?) -> Void)?
    private var interruptionObserver: NSObjectProtocol?

    public init(arbiter: AudioSessionArbiter = .shared) {
        self.arbiter = arbiter
        super.init()
        arbiter.onYield(.recorder) { [weak self] in self?.interrupt() }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.interrupt() }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    public func requestPermission() async -> Bool {
        await SystemMicrophonePermission().requestPermission()
    }

    public func start() throws {
        discard()
        try arbiter.acquireForRecording()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else { throw VoiceRecorderError.couldNotStart }
        self.recorder = recorder
        fileURL = url
    }

    public func stop() -> URL? {
        guard let recorder else { return fileURL }
        let recorded = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        arbiter.release(.recorder)
        return recorded > 0.2 ? fileURL : nil
    }

    public func discard() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        arbiter.release(.recorder)
    }

    public var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        // -60 dB … 0 dB → 0 … 1
        let power = recorder.averagePower(forChannel: 0)
        return max(0, min(1, (power + 60) / 60))
    }

    public var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
    public var isRecording: Bool { recorder?.isRecording ?? false }

    /// A call, or a room taking the session: stop and keep what was recorded.
    private func interrupt() {
        guard recorder != nil else { return }
        let url = stop()
        onInterrupted?(url)
    }
}

public enum VoiceRecorderError: Error { case couldNotStart }
