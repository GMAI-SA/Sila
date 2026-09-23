import Foundation

/// In-memory ``VoiceServiceProtocol``: an upload becomes a clip whose caption
/// arrives on the second read, as the real one does a few seconds later.
public final class VoiceServiceMock: VoiceServiceProtocol, @unchecked Sendable {

    public enum MockScenario: String, CaseIterable, Sendable {
        case working
        /// The upload is refused as too long.
        case tooLong
        /// Every call fails with a transport error.
        case offline
    }

    private let scenario: MockScenario
    private let lock = NSLock()
    private var clips: [UUID: VoiceClip] = [:]
    private var reads: [UUID: Int] = [:]
    private var stances: [UUID: VoiceStances] = [:]
    public private(set) var uploads: [(kind: VoiceKind, languageHint: String?)] = []

    public init(scenario: MockScenario = .working) {
        self.scenario = scenario
    }

    private func check() throws {
        if scenario == .offline { throw APIError.transport("The Internet connection appears to be offline.") }
    }

    public func upload(_ file: URL, kind: VoiceKind, languageHint: String?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> VoiceClip {
        try check()
        if scenario == .tooLong {
            throw APIError.api(code: .audioTooLong, message: "At most \(kind.maxSeconds) seconds", status: 400)
        }
        progress(0.5)
        progress(1)
        let clip = VoiceClip(kind: kind, audioURL: AppConfig.mediaURL("/api/v1/media/voice/sample.m4a"),
                             durationMs: 8_400, peaks: (0..<100).map { ($0 * 37) % 255 })
        lock.withLock {
            clips[clip.id] = clip
            uploads.append((kind, languageHint))
        }
        return clip
    }

    public func fetchClip(_ id: UUID) async throws -> VoiceClip {
        try check()
        return try lock.withLock {
            guard let clip = clips[id] else { throw APIError.api(code: .unknown, message: "No such clip", status: 404) }
            reads[id, default: 0] += 1
            guard clip.captionStatus == .pending, reads[id, default: 0] >= 2 else { return clip }
            let done = VoiceClip(clipId: clip.clipId, kind: clip.kind, audioURL: clip.audioURL, durationMs: clip.durationMs,
                                 peaks: clip.peaks, caption: "What do you think of the new season?",
                                 captionStatus: .done, captionLanguage: "en")
            clips[id] = done
            return done
        }
    }

    public func editCaption(_ id: UUID, text: String) async throws -> VoiceClip {
        try check()
        return try replace(id) { clip in
            VoiceClip(clipId: clip.clipId, kind: clip.kind, audioURL: clip.audioURL, durationMs: clip.durationMs,
                      peaks: clip.peaks, caption: text, captionStatus: .done, captionLanguage: clip.captionLanguage,
                      captionByAuthor: true)
        }
    }

    public func removeCaption(_ id: UUID) async throws -> VoiceClip {
        try check()
        return try replace(id) { clip in
            VoiceClip(clipId: clip.clipId, kind: clip.kind, audioURL: clip.audioURL, durationMs: clip.durationMs,
                      peaks: clip.peaks, caption: nil, captionStatus: .removed)
        }
    }

    public func redoCaption(_ id: UUID, language: String?) async throws -> VoiceClip {
        try check()
        return try replace(id) { clip in
            VoiceClip(clipId: clip.clipId, kind: clip.kind, audioURL: clip.audioURL, durationMs: clip.durationMs,
                      peaks: clip.peaks, caption: nil, captionStatus: .pending, captionLanguage: language)
        }
    }

    public func setStance(_ stance: VoiceStances.Stance?, postId: UUID) async throws -> VoiceStances {
        try check()
        return lock.withLock {
            let current = stances[postId] ?? VoiceStances(agree: 3, disagree: 1)
            var agree = current.agree - (current.viewerStance == .agree ? 1 : 0)
            var disagree = current.disagree - (current.viewerStance == .disagree ? 1 : 0)
            if stance == .agree { agree += 1 }
            if stance == .disagree { disagree += 1 }
            let next = VoiceStances(agree: agree, disagree: disagree, viewerStance: stance)
            stances[postId] = next
            return next
        }
    }

    private func replace(_ id: UUID, _ transform: (VoiceClip) -> VoiceClip) throws -> VoiceClip {
        try lock.withLock {
            guard let clip = clips[id] else { throw APIError.api(code: .unknown, message: "No such clip", status: 404) }
            let next = transform(clip)
            reads[id] = 0
            clips[id] = next
            return next
        }
    }
}
