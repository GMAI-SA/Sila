import AVFoundation
import Foundation

/// The one owner of `AVAudioSession`, shared by voice posts and voice rooms.
///
/// Three things want the audio session and must never fight over it: the
/// voice-post recorder, the voice-post player and a LiveKit room. Whoever
/// takes it goes through here, and a room always wins: before a room connects,
/// the recorder and the player are stopped and the session is released with
/// `.notifyOthersOnDeactivation`, so the room configures a clean session
/// rather than inheriting a recorder's.
///
/// **Rooms are never recorded.** Nothing here gives the recorder access to a
/// room's audio; the arbiter's only job is to hand the session from one to the
/// other cleanly.
@MainActor
public final class AudioSessionArbiter {

    public enum Owner: Equatable, Sendable { case none, recorder, player, room }

    public static let shared = AudioSessionArbiter()

    public private(set) var owner: Owner = .none
    /// Called when a room takes the session, so a recorder can stop and keep
    /// what it has and a player can pause.
    private var yieldHandlers: [Owner: () -> Void] = [:]

    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    /// Registers what to do when the session is taken away.
    public func onYield(_ owner: Owner, _ handler: @escaping () -> Void) {
        yieldHandlers[owner] = handler
    }

    /// For recording one's own voice post.
    public func acquireForRecording() throws {
        guard owner != .room else { throw AudioSessionError.roomActive }
        take(.recorder)
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }

    /// For playing a voice post. `.playback` only while something plays.
    public func acquireForPlayback() throws {
        guard owner != .room else { throw AudioSessionError.roomActive }
        take(.player)
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    /// Before a room connects: everyone else stops and the session is released,
    /// telling other apps they may resume.
    public func prepareForRoom() {
        take(.room)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Gives the session back.
    public func release(_ from: Owner) {
        guard owner == from else { return }
        owner = .none
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func take(_ next: Owner) {
        guard owner != next else { return }
        let previous = owner
        owner = next
        if previous != .none { yieldHandlers[previous]?() }
    }
}

public enum AudioSessionError: Error, Equatable {
    /// A voice room holds the microphone; leave it to record.
    case roomActive
}
