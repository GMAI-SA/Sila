import Foundation

/// Everything the voice surfaces ask of the server (contract v20).
public protocol VoiceServiceProtocol: Sendable {
    /// `POST /media/voice` — the recording is decoded, re-encoded, stripped of
    /// metadata and measured by the server. `progress` runs 0…1 as it uploads.
    func upload(
        _ file: URL,
        kind: VoiceKind,
        languageHint: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VoiceClip
    /// `GET /media/voice/clips/{id}` — author only; polled for the caption.
    func fetchClip(_ id: UUID) async throws -> VoiceClip
    /// The author's own words replace the machine's.
    func editCaption(_ id: UUID, text: String) async throws -> VoiceClip
    func removeCaption(_ id: UUID) async throws -> VoiceClip
    /// Try the machine again, optionally in a forced language (max three).
    func redoCaption(_ id: UUID, language: String?) async throws -> VoiceClip
    /// Agree / disagree on a Hot Take; `nil` withdraws.
    func setStance(_ stance: VoiceStances.Stance?, postId: UUID) async throws -> VoiceStances
}
