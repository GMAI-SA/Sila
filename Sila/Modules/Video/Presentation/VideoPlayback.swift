import AVFoundation
import Network
import Observation
import SwiftUI
import UIKit

/// Decides which video in view may play by itself, and keeps it to one.
///
/// Muted autoplay happens only where ``VideoAutoplayPolicy`` allows it — on
/// Wi-Fi outside Low Data Mode, with the system's "Auto-Play Video Previews"
/// on and Low Power Mode off — and only for the card most in view. Whatever
/// plays, with sound or without, is the only thing playing: starting one
/// pauses the other.
///
/// Shared, like ``VoicePlayer``: there is one screen and one pair of ears.
@MainActor
@Observable
public final class VideoAutoplayCoordinator {

    public static let shared = VideoAutoplayCoordinator()

    public private(set) var policy: VideoAutoplayPolicy
    /// The card that should be playing muted by itself, if any.
    public private(set) var activeCard: UUID?
    /// `-videoAutoplay on|off` in a debug build: the journeys decide rather
    /// than the Mac's network.
    private let forced: Bool?

    // Where each card is changes with every frame of a scroll; nothing is
    // drawn from it directly, so no view is told each time.
    @ObservationIgnored private var frames: [UUID: CGRect] = [:]
    @ObservationIgnored private weak var playing: VideoPlaybackModel?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        policy = VideoAutoplayPolicy(
            connection: .unknown,
            systemAllowsAutoplay: UIAccessibility.isVideoAutoplayEnabled,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        var forced: Bool?
        #if DEBUG
        if let index = arguments.firstIndex(of: "-videoAutoplay"), arguments.indices.contains(index + 1) {
            forced = arguments[index + 1] == "on"
        }
        #endif
        self.forced = forced
        // A voice post or a room taking the sound pauses a video playing
        // with its own.
        AudioSessionArbiter.shared.onYield(.video) { [weak self] in self?.pauseAll() }
        guard !AppConfig.isRunningUnitTests else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = VideoAutoplayPolicy.Connection(
                isSatisfied: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi),
                isConstrained: path.isConstrained,
                isExpensive: path.isExpensive
            )
            Task { @MainActor [weak self] in
                self?.policy.connection = connection
                self?.recompute()
            }
        }
        monitor.start(queue: DispatchQueue(label: "sila.video.path"))
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIAccessibility.videoAutoplayStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.policy.systemAllowsAutoplay = UIAccessibility.isVideoAutoplayEnabled
                self?.recompute()
            }
        })
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.policy.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.recompute()
            }
        })
    }

    /// Whether a video may start by itself right now.
    public var allowsAutoplay: Bool { forced ?? policy.allowsAutoplay }

    /// A card moved on screen.
    func report(_ card: UUID, frame: CGRect) {
        frames[card] = frame
        recompute()
    }

    /// A card left the screen.
    func withdraw(_ card: UUID) {
        frames[card] = nil
        recompute()
    }

    /// How much of a card is on screen, 0…1.
    func visibleFraction(_ card: UUID) -> CGFloat {
        guard let frame = frames[card] else { return 0 }
        return VideoAutoplayPolicy.visibleFraction(of: frame, in: Self.viewport)
    }

    /// A model is about to play: whatever else plays stops.
    func willPlay(_ model: VideoPlaybackModel) {
        if let playing, playing !== model { playing.pause(byUser: false) }
        playing = model
    }

    /// Something else wants the screen's sound — a voice post, a room.
    func pauseAll() {
        playing?.pause(byUser: false)
    }

    private func recompute() {
        guard allowsAutoplay else {
            activeCard = nil
            return
        }
        let chosen = VideoAutoplayPolicy.choose(frames, in: Self.viewport)
        if chosen != activeCard { activeCard = chosen }
    }

    private static var viewport: CGRect {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        return window?.bounds ?? UIScreen.main.bounds
    }
}

/// One card's player: poster first, then the stream, muted or not, with the
/// captions the app draws itself.
@MainActor
@Observable
public final class VideoPlaybackModel {

    public let video: PostVideo
    /// This card, as the coordinator knows it. The same video on two screens
    /// is two cards.
    public let card = UUID()

    public private(set) var player: AVPlayer?
    public private(set) var isPlaying = false
    public private(set) var isMuted = true
    /// Whether the stream has been started at all — the poster stays until it is.
    public private(set) var hasStarted = false
    /// Started by the coordinator rather than a tap: muted, and looping.
    public private(set) var isAutoplaying = false
    public private(set) var elapsed: Double = 0
    public private(set) var duration: Double
    public private(set) var isBuffering = false
    public private(set) var failed = false
    /// The chosen caption track's language, or `nil` for none.
    public private(set) var captionLanguage: String?
    /// The words on screen now.
    public private(set) var caption: String?
    /// Said once, when the sound cannot be had.
    public var notice: String?
    /// The person paused it: it does not start by itself again while in view.
    public private(set) var pausedByUser = false

    private var cues: [String: [WebVTTCue]] = [:]
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private let coordinator: VideoAutoplayCoordinator
    private let arbiter: AudioSessionArbiter
    private let fetchCaptions: @Sendable (URL) async throws -> String

    /// The caption language chosen last, kept for the next video this
    /// session, so somebody who reads captions does not turn them on every
    /// time.
    static var preferredCaptionLanguage: String?

    init(
        video: PostVideo,
        coordinator: VideoAutoplayCoordinator = .shared,
        arbiter: AudioSessionArbiter = .shared,
        fetchCaptions: @escaping @Sendable (URL) async throws -> String = { try await VideoPlaybackModel.download($0) }
    ) {
        self.video = video
        self.coordinator = coordinator
        self.arbiter = arbiter
        self.fetchCaptions = fetchCaptions
        self.duration = video.durationSeconds ?? 0
        if let preferred = Self.preferredCaptionLanguage, video.captions(in: preferred) != nil {
            captionLanguage = preferred
        }
    }

    // MARK: - Playing

    /// Plays: muted and looping when the coordinator starts it, with its
    /// sound when somebody tapped.
    public func play(muted: Bool, autoplay: Bool = false) {
        guard let player = ensurePlayer() else { return }
        var muted = muted
        if !muted {
            do {
                try arbiter.acquireForVideo()
            } catch {
                // A room holds the sound. The picture still plays.
                muted = true
                notice = L10n.t("video.error.roomActive")
            }
        } else {
            arbiter.prepareForMutedVideo()
        }
        coordinator.willPlay(self)
        player.isMuted = muted
        isMuted = muted
        isAutoplaying = autoplay
        if !autoplay { pausedByUser = false }
        if duration > 0, elapsed >= duration - 0.25 { player.seek(to: .zero) }
        player.play()
        isPlaying = true
        hasStarted = true
        if let captionLanguage, cues[captionLanguage] == nil {
            Task { await loadCues(captionLanguage) }
        }
    }

    public func pause(byUser: Bool) {
        player?.pause()
        isPlaying = false
        if byUser { pausedByUser = true }
        if !isMuted { arbiter.release(.video) }
    }

    /// The play button. A video playing by itself in the feed is taken over
    /// by the tap — with its sound, and no longer looping — rather than
    /// stopped, because that is what somebody tapping a moving picture wants.
    public func togglePlay() {
        if isPlaying, isAutoplaying {
            play(muted: false)
        } else if isPlaying {
            pause(byUser: true)
        } else {
            play(muted: hasStarted ? isMuted : false)
        }
    }

    /// Sound on or off. Turning it on takes the playback session, like a
    /// voice post; a tap on a video playing by itself also stops it looping.
    public func toggleMute() {
        guard let player else {
            play(muted: false)
            return
        }
        if isMuted {
            do {
                try arbiter.acquireForVideo()
            } catch {
                notice = L10n.t("video.error.roomActive")
                return
            }
            player.isMuted = false
            isMuted = false
            isAutoplaying = false
        } else {
            player.isMuted = true
            isMuted = true
            arbiter.release(.video)
        }
    }

    public func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        elapsed = target
        updateCaption()
    }

    /// Stops and lets go of the stream: the card left the screen.
    public func tearDown() {
        pause(byUser: false)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        hasStarted = false
        isAutoplaying = false
    }

    // MARK: - Captions

    /// Shows the captions in `language`, or none.
    public func selectCaptions(_ language: String?) async {
        captionLanguage = language
        Self.preferredCaptionLanguage = language
        guard let language else {
            caption = nil
            return
        }
        await loadCues(language)
    }

    private func loadCues(_ language: String) async {
        guard cues[language] == nil, let track = video.captions(in: language) else {
            updateCaption()
            return
        }
        do {
            let text = try await fetchCaptions(track.url)
            cues[language] = WebVTT.parse(text)
        } catch {
            cues[language] = []
        }
        updateCaption()
    }

    private func updateCaption() {
        guard let captionLanguage, let track = cues[captionLanguage] else {
            caption = nil
            return
        }
        caption = WebVTT.text(at: elapsed, in: track)
    }

    /// Captions are public files, like the video's: no token, nothing kept.
    nonisolated static func download(_ url: URL) async throws -> String {
        if url.isFileURL {
            // The mocked server's captions, on this phone.
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The player

    private func ensurePlayer() -> AVPlayer? {
        if let player { return player }
        guard let url = video.hlsURL else { return nil }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Never the stream's own subtitles: the app draws the captions, and
        // two sets would be one too many.
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
                self.isBuffering = self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.updateCaption()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in if failed { self?.failed = true } }
        }
        self.player = player
        return player
    }

    private func reachedEnd() {
        guard let player else { return }
        player.seek(to: .zero)
        if isAutoplaying {
            // Muted in the feed: round again, like a moving picture.
            player.play()
        } else {
            isPlaying = false
            elapsed = 0
            if !isMuted { arbiter.release(.video) }
        }
    }
}

/// An `AVPlayerLayer`, as SwiftUI can hold it.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer?

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
