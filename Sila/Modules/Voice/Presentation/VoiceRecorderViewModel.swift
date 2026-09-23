import Foundation
import Observation

/// Drives ``VoiceRecorderSheet``: record (press to start, press to stop — a
/// two-minute hold is hostile), listen back, retake, upload, and watch the
/// caption arrive. The clip is handed to the composer only when the person
/// chooses to use it; nothing is posted from here.
@MainActor
@Observable
public final class VoiceRecorderViewModel {

    public enum Phase: Equatable {
        case idle
        case recording
        case recorded(URL, TimeInterval)
        case uploading(Double)
        case uploaded(VoiceClip)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public var kind: VoiceKind {
        didSet { if phase == .recording { kind = oldValue } }
    }
    /// The last few levels, newest last, for the bars.
    public private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var micDenied = false
    public private(set) var isPlayingBack = false
    /// The caption as the author is editing it.
    public var captionDraft = ""
    public private(set) var isSavingCaption = false
    public var toast: SLToastMessage?

    private let recorder: VoiceRecording
    private let service: VoiceServiceProtocol
    private let analytics: AnalyticsClient
    private let languageHint: String?
    private let onUse: @MainActor (VoiceClip) -> Void
    private var ticker: Task<Void, Never>?
    private var captionWatch: Task<Void, Never>?
    /// Seconds between caption reads while it is on its way.
    private let pollInterval: UInt64
    private let player = LocalClipPlayer()

    /// - Parameters:
    ///   - kind: Starting kind; replies open in `question`.
    ///   - lockedKind: When set, the kind chips are hidden (a reply is a question).
    public init(
        kind: VoiceKind = .thought,
        recorder: VoiceRecording,
        service: VoiceServiceProtocol,
        analytics: AnalyticsClient,
        languageHint: String? = L10n.languageCode,
        pollInterval: UInt64 = 2_000_000_000,
        onUse: @escaping @MainActor (VoiceClip) -> Void
    ) {
        self.kind = kind
        self.recorder = recorder
        self.service = service
        self.analytics = analytics
        self.languageHint = languageHint == "ar" || languageHint == "en" ? languageHint : nil
        self.pollInterval = pollInterval
        self.onUse = onUse
        recorder.onInterrupted = { [weak self] url in self?.interrupted(url) }
    }

    // MARK: - Derived

    public var remaining: TimeInterval { max(0, TimeInterval(kind.maxSeconds) - elapsed) }
    public var isRecording: Bool { phase == .recording }
    public var canChangeKind: Bool {
        switch phase {
        case .idle, .recorded: return true
        default: return false
        }
    }

    public var uploadedClip: VoiceClip? {
        if case let .uploaded(clip) = phase { return clip }
        return nil
    }

    // MARK: - Recording

    /// The one big button: starts, or stops.
    public func toggleRecording() async {
        if isRecording {
            finish()
            return
        }
        guard await recorder.requestPermission() else {
            micDenied = true
            return
        }
        do {
            try recorder.start()
        } catch AudioSessionError.roomActive {
            toast = .warning(L10n.t("voice.error.roomActive"))
            return
        } catch {
            phase = .failed(L10n.t("voice.error.couldNotRecord"))
            return
        }
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        phase = .recording
        analytics.track(.voiceRecordStarted, properties: ["kind": kind.rawValue])
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.tick()
            }
        }
    }

    func tick() {
        guard isRecording else { return }
        elapsed = recorder.elapsed
        levels.removeFirst()
        levels.append(recorder.level)
        if elapsed >= TimeInterval(kind.maxSeconds) { finish() }
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        let seconds = recorder.elapsed
        if let url = recorder.stop(), seconds >= 1 {
            phase = .recorded(url, seconds)
        } else {
            phase = .idle
            toast = .warning(L10n.t("voice.error.tooShort"))
        }
    }

    /// A phone call or a room took the session: keep what was recorded.
    private func interrupted(_ url: URL?) {
        ticker?.cancel()
        ticker = nil
        if let url, elapsed >= 1 {
            phase = .recorded(url, elapsed)
            toast = .info(L10n.t("voice.interrupted"))
        } else {
            phase = .idle
        }
    }

    /// Throws the take away and starts again.
    public func retake() {
        player.stop()
        isPlayingBack = false
        recorder.discard()
        captionWatch?.cancel()
        elapsed = 0
        phase = .idle
    }

    // MARK: - Listening back

    public func togglePlayback() {
        guard case let .recorded(url, _) = phase else { return }
        if isPlayingBack {
            player.stop()
            isPlayingBack = false
        } else {
            isPlayingBack = player.play(url) { [weak self] in self?.isPlayingBack = false }
        }
    }

    // MARK: - Upload and caption

    public func upload() async {
        guard case let .recorded(url, _) = phase else { return }
        player.stop()
        isPlayingBack = false
        phase = .uploading(0)
        do {
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor [weak self] in self?.reportUpload(fraction) }
            }
            let clip = try await service.upload(url, kind: kind, languageHint: languageHint, progress: report)
            try? FileManager.default.removeItem(at: url)
            adopt(clip)
            watchCaption()
        } catch {
            let wrapped = APIError.wrapping(error)
            guard !wrapped.isCancellation else { phase = .recorded(url, elapsed); return }
            phase = .recorded(url, elapsed)
            toast = .error(wrapped.userMessage)
        }
    }

    private func reportUpload(_ fraction: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(fraction)
    }

    private func adopt(_ clip: VoiceClip) {
        phase = .uploaded(clip)
        if !clip.captionByAuthor || captionDraft.isEmpty { captionDraft = clip.caption ?? "" }
    }

    /// Reads the clip every couple of seconds until the caption is no longer
    /// on its way, for at most a minute.
    func watchCaption() {
        captionWatch?.cancel()
        guard let clip = uploadedClip, clip.captionStatus == .pending else { return }
        let id = clip.id
        captionWatch = Task { [weak self] in
            for _ in 0..<30 {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.pollInterval)
                guard !Task.isCancelled else { return }
                guard let fresh = try? await self.service.fetchClip(id) else { continue }
                self.adopt(fresh)
                if fresh.captionStatus != .pending { return }
            }
        }
    }

    /// Saves the author's own words over the machine's.
    public func saveCaption() async {
        guard let clip = uploadedClip else { return }
        let text = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return await removeCaption() }
        await captionCall { try await self.service.editCaption(clip.id, text: text) }
    }

    public func removeCaption() async {
        guard let clip = uploadedClip else { return }
        await captionCall { try await self.service.removeCaption(clip.id) }
    }

    /// Asks the machine again — in a chosen language when it guessed wrong.
    public func redoCaption(language: String?) async {
        guard let clip = uploadedClip else { return }
        await captionCall { try await self.service.redoCaption(clip.id, language: language) }
        watchCaption()
    }

    private func captionCall(_ call: @escaping () async throws -> VoiceClip) async {
        isSavingCaption = true
        defer { isSavingCaption = false }
        do {
            let clip = try await call()
            phase = .uploaded(clip)
            captionDraft = clip.caption ?? ""
        } catch {
            toast = .error(for: error)
        }
    }

    /// Hands the clip to the composer.
    public func use() {
        guard let clip = uploadedClip else { return }
        captionWatch?.cancel()
        onUse(clip)
    }

    /// Leaving without using it: nothing is kept on the phone. (A clip already
    /// uploaded and never posted is deleted by the server after a day.)
    public func cancel() {
        ticker?.cancel()
        captionWatch?.cancel()
        player.stop()
        if case .recording = phase { _ = recorder.stop() }
        recorder.discard()
    }
}

/// Plays the local take before it is uploaded.
@MainActor
final class LocalClipPlayer: NSObject {
    private var player: AVAudioPlayerBox?

    func play(_ url: URL, onEnd: @escaping () -> Void) -> Bool {
        stop()
        guard let box = AVAudioPlayerBox(url: url, onEnd: onEnd) else { return false }
        player = box
        return box.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
