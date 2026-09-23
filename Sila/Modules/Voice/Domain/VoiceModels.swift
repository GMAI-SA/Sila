import Foundation

// MARK: - Contract v20: recorded voice

/// What kind of recording this is. The kind sets how long it may run and the
/// line the recorder shows; `hotTake` also carries agree / disagree.
public enum VoiceKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case thought
    case question
    case story
    case hotTake = "hot_take"

    public var id: String { rawValue }

    /// The server's cap, in seconds.
    public var maxSeconds: Int {
        switch self {
        case .thought: return 30
        case .question: return 60
        case .story: return 120
        case .hotTake: return 60
        }
    }

    public var title: String {
        switch self {
        case .thought: return L10n.t("voice.kind.thought")
        case .question: return L10n.t("voice.kind.question")
        case .story: return L10n.t("voice.kind.story")
        case .hotTake: return L10n.t("voice.kind.hotTake")
        }
    }

    /// The line under the button: what this kind is for.
    public var prompt: String {
        switch self {
        case .thought: return L10n.t("voice.kind.thought.prompt")
        case .question: return L10n.t("voice.kind.question.prompt")
        case .story: return L10n.t("voice.kind.story.prompt")
        case .hotTake: return L10n.t("voice.kind.hotTake.prompt")
        }
    }
}

/// Where the machine caption is.
public enum CaptionStatus: String, Sendable, Hashable {
    case pending, done, failed, removed
}

/// Agree / disagree on a Hot Take. Anonymous, like a poll vote.
public struct VoiceStances: Equatable, Hashable, Sendable, Decodable {
    public enum Stance: String, Sendable, Hashable { case agree, disagree }

    public let agree: Int
    public let disagree: Int
    public let viewerStance: Stance?

    public init(agree: Int = 0, disagree: Int = 0, viewerStance: Stance? = nil) {
        self.agree = agree
        self.disagree = disagree
        self.viewerStance = viewerStance
    }

    public var total: Int { agree + disagree }

    /// Share agreeing, 0…1; 0.5 when nobody has said anything yet.
    public var agreeShare: Double { total == 0 ? 0.5 : Double(agree) / Double(total) }

    private enum CodingKeys: String, CodingKey { case agree, disagree, viewerStance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agree = (try? c.decode(Int.self, forKey: .agree)) ?? 0
        disagree = (try? c.decode(Int.self, forKey: .disagree)) ?? 0
        let raw = (try? c.decodeIfPresent(String.self, forKey: .viewerStance)) ?? nil
        viewerStance = raw.flatMap(Stance.init(rawValue:))
    }
}

/// A recording, as the server holds it (`VoiceOut`).
public struct VoiceClip: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public let clipId: UUID
    public let kind: VoiceKind
    public let audioURL: URL?
    public let durationMs: Int
    /// 100 buckets, 0–255 — the waveform.
    public let peaks: [Int]
    public let caption: String?
    public let captionStatus: CaptionStatus
    public let captionLanguage: String?
    public let captionByAuthor: Bool
    public let stances: VoiceStances?

    public var id: UUID { clipId }

    public init(
        clipId: UUID = UUID(),
        kind: VoiceKind = .thought,
        audioURL: URL? = nil,
        durationMs: Int = 0,
        peaks: [Int] = [],
        caption: String? = nil,
        captionStatus: CaptionStatus = .pending,
        captionLanguage: String? = nil,
        captionByAuthor: Bool = false,
        stances: VoiceStances? = nil
    ) {
        self.clipId = clipId
        self.kind = kind
        self.audioURL = audioURL
        self.durationMs = durationMs
        self.peaks = peaks
        self.caption = caption
        self.captionStatus = captionStatus
        self.captionLanguage = captionLanguage
        self.captionByAuthor = captionByAuthor
        self.stances = stances
    }

    private enum CodingKeys: String, CodingKey {
        case clipId, kind, audioUrl, durationMs, peaks, caption, captionStatus, captionLanguage, captionByAuthor, stances
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipId = try c.decode(UUID.self, forKey: .clipId)
        kind = VoiceKind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .thought
        // Root-relative, like image paths: resolved against the API host or
        // it is a URL no player can load.
        audioURL = AppConfig.mediaURL((try? c.decodeIfPresent(String.self, forKey: .audioUrl)) ?? nil)
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
        peaks = ((try? c.decode([Int].self, forKey: .peaks)) ?? []).map { min(max($0, 0), 255) }
        let text = (try? c.decodeIfPresent(String.self, forKey: .caption)) ?? nil
        caption = (text?.isEmpty == false) ? text : nil
        captionStatus = CaptionStatus(rawValue: (try? c.decode(String.self, forKey: .captionStatus)) ?? "") ?? .pending
        captionLanguage = (try? c.decodeIfPresent(String.self, forKey: .captionLanguage)) ?? nil
        captionByAuthor = (try? c.decode(Bool.self, forKey: .captionByAuthor)) ?? false
        stances = (try? c.decodeIfPresent(VoiceStances.self, forKey: .stances)) ?? nil
    }

    public var duration: TimeInterval { TimeInterval(durationMs) / 1000 }

    /// The label a caption always carries, or `nil` when there is no caption
    /// line to draw.
    public var captionLabel: String? {
        if captionByAuthor, caption != nil { return L10n.t("voice.caption.byAuthor") }
        switch captionStatus {
        case .pending: return L10n.t("voice.caption.pending")
        case .done: return caption == nil ? nil : L10n.t("voice.caption.auto")
        case .failed, .removed: return nil
        }
    }

    /// A copy with new stances — after a Hot Take vote.
    public func with(stances: VoiceStances) -> VoiceClip {
        VoiceClip(clipId: clipId, kind: kind, audioURL: audioURL, durationMs: durationMs, peaks: peaks,
                  caption: caption, captionStatus: captionStatus, captionLanguage: captionLanguage,
                  captionByAuthor: captionByAuthor, stances: stances)
    }
}

/// `PATCH /media/voice/clips/{id}/caption`.
struct CaptionEditRequest: Encodable { let caption: String }
/// `POST /media/voice/clips/{id}/caption/redo`.
struct CaptionRedoRequest: Encodable { let language: String? }
/// `PUT /posts/{id}/stance`.
struct StanceRequest: Encodable { let stance: String }

/// "0:42" — a clip length or countdown, with Western digits like every
/// number in the app.
public enum VoiceTime {
    public static func label(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
