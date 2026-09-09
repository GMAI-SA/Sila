import AVFoundation
import Foundation
import LiveKit

/// The production ``VoiceEngineProtocol``, on LiveKit.
///
/// **This is the only file in Sila that imports a third-party library.** The
/// app is otherwise zero-dependency; a WebRTC stack is the one thing it would
/// be irresponsible to hand-roll, and keeping the import to a single file is
/// what lets every rule the rooms feature has to hold be tested without one.
///
/// Four things here are load-bearing rather than configuration.
///
/// **The audio session is `.playAndRecord` with `.voiceChat`.** Not
/// `.playback`: a listener who is later invited to speak must not need the
/// session torn down and rebuilt mid-conversation, and `.voiceChat` is what
/// enables the echo cancellation that makes two people on speakerphone
/// possible at all.
///
/// **The session is only *activated* with recording once somebody publishes.**
/// The category permits recording; the microphone is not opened until
/// ``setMicrophoneEnabled(_:)`` is called, and that call is the only place
/// iOS is asked for permission. A listener never sees the prompt, because a
/// listener never needs the device.
///
/// **Publishing is refused locally when the connection does not permit it.**
/// The grant is the real enforcement — the media server drops a listener's
/// audio regardless — but a client that tried anyway would sit there with an
/// open microphone and no explanation. See ``VoiceEngineError/notPermittedToPublish``.
///
/// **The room's events are forwarded, not interpreted.** A join, a leave, a
/// permission change, a mute, a data message — each is handed up as a
/// ``VoiceRoomEvent`` so the roster refreshes the moment something happened
/// rather than on the next poll. The API row stays the truth.
@MainActor
public final class LiveKitVoiceEngine: NSObject, VoiceEngineProtocol {

    public private(set) var connection: VoiceConnectionState = .idle {
        didSet { if connection != oldValue { onChange?() } }
    }
    public private(set) var isMicrophoneEnabled = false {
        didSet { if isMicrophoneEnabled != oldValue { onChange?() } }
    }
    public private(set) var speakingIdentities: Set<String> = [] {
        didSet { if speakingIdentities != oldValue { onChange?() } }
    }
    public private(set) var mutedIdentities: Set<String> = [] {
        didSet { if mutedIdentities != oldValue { onChange?() } }
    }
    /// What the live connection may do. Seeded from the token, updated when
    /// the server applies a promotion or demotion to the live participant.
    public private(set) var canPublish = false {
        didSet { if canPublish != oldValue { onChange?() } }
    }
    public var onChange: (@MainActor () -> Void)?
    public var onRoomEvent: (@MainActor (VoiceRoomEvent) -> Void)?

    private let room: LiveKit.Room
    private let permission: MicrophonePermissionRequesting

    /// - Parameter permission: The microphone prompt. Injectable so a test can
    ///   drive the denied path without a device.
    public init(permission: MicrophonePermissionRequesting = SystemMicrophonePermission()) {
        self.permission = permission
        self.room = LiveKit.Room()
        super.init()
        room.add(delegate: self)
    }

    // MARK: - Connecting

    public func connect(url: String, token: String, canPublish: Bool) async throws {
        // Configured before the socket opens, so the first audio frame has
        // somewhere to go. `.voiceChat` rather than `.videoChat`: this app has
        // no camera path, and the receiver/speaker routing differs.
        configureAudioSession()

        self.canPublish = canPublish
        connection = .connecting
        do {
            try await room.connect(
                url: url,
                token: token,
                roomOptions: RoomOptions(
                    // A listener's token forbids publishing anyway; saying so
                    // here as well means the SDK never even prepares a capture
                    // graph for somebody who will not use one.
                    defaultAudioPublishOptions: AudioPublishOptions(name: "microphone"),
                    adaptiveStream: false,
                    dynacast: false
                )
            )
            connection = .connected
            // What the server actually granted wins over what the client was
            // told; the two agree unless a role changed mid-flight.
            self.canPublish = room.localParticipant.permissions.canPublish
            refreshMuted()
        } catch {
            connection = .failed(APIError.wrapping(error).userMessage)
            throw VoiceEngineError.transport(error.localizedDescription)
        }
    }

    // MARK: - The microphone

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if enabled {
            // Gate one: this connection. Unreachable from the UI, which hides
            // the control for a listener — but a silent open microphone would
            // be a worse failure than a named one.
            guard canPublish else { throw VoiceEngineError.notPermittedToPublish }
            // Gate two: iOS. Asked here and nowhere else — this is the moment
            // somebody actually took the microphone.
            guard await permission.requestPermission() else {
                throw VoiceEngineError.microphoneDenied
            }
        }

        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            isMicrophoneEnabled = enabled
        } catch {
            throw VoiceEngineError.transport(error.localizedDescription)
        }
    }

    // MARK: - Data

    public func publish(_ message: RoomDataMessage, to identities: [String]) async {
        // Best-effort by contract: a hand's API call already succeeded, and a
        // lost nudge costs the host one poll interval. A reaction or a line of
        // chat is ephemeral by design — there is nothing to retry it against.
        //
        // Addressed when identities are named, so "only the host" is a
        // property of the wire rather than a promise the receivers keep.
        try? await room.localParticipant.publish(
            data: message.encoded(),
            options: DataPublishOptions(
                destinationIdentities: identities.map { Participant.Identity(from: $0) },
                topic: RoomDataMessage.topic,
                reliable: true
            )
        )
    }

    // MARK: - Leaving

    public func disconnect() async {
        // Muting first, so the last thing that happens on the wire is silence
        // rather than a socket closing mid-syllable. A failure here is ignored
        // on purpose: the disconnect below ends the audio either way, and an
        // error thrown out of a leave path is an error nobody can act on.
        if isMicrophoneEnabled {
            try? await room.localParticipant.setMicrophone(enabled: false)
            isMicrophoneEnabled = false
        }
        await room.disconnect()
        canPublish = false
        speakingIdentities = []
        mutedIdentities = []
        connection = .idle
    }

    // MARK: - Audio session

    /// `.playAndRecord` + `.voiceChat`, with the room routed to the speaker.
    ///
    /// Handed to LiveKit rather than applied directly: the SDK activates and
    /// deactivates the session around track lifecycles, and a category set
    /// behind its back is one it will overwrite.
    private func configureAudioSession() {
        AudioManager.shared.sessionConfiguration = AudioSessionConfiguration(
            category: .playAndRecord,
            categoryOptions: [
                // A voice room held against the ear is a voice room nobody can
                // join while doing anything else.
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .allowAirPlay
            ],
            mode: .voiceChat
        )
        AudioManager.shared.isSpeakerOutputPreferred = true
    }

    /// Who has a muted microphone right now, read off the participants.
    private func refreshMuted() {
        var muted: Set<String> = []
        for participant in room.remoteParticipants.values {
            guard let identity = participant.identity?.stringValue else { continue }
            if participant.audioTracks.contains(where: { $0.isMuted }) {
                muted.insert(identity)
            }
        }
        mutedIdentities = muted
    }
}

// MARK: - RoomDelegate

extension LiveKitVoiceEngine: RoomDelegate {

    nonisolated public func room(
        _ room: LiveKit.Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch connectionState {
            case .connected: self.connection = .connected
            case .connecting: self.connection = .connecting
            case .reconnecting: self.connection = .reconnecting
            case .disconnected:
                // Only a state, not a verdict: a deliberate leave lands here
                // too, and `disconnect()` has already said `.idle`.
                if self.connection.isActive { self.connection = .idle }
            }
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isMicrophoneEnabled = false
            self.speakingIdentities = []
            self.connection = error.map { .failed($0.localizedDescription) } ?? .idle
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            self?.connection = .failed(
                error?.localizedDescription ?? L10n.t("rooms.voice.connectFailed")
            )
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, didUpdateSpeakingParticipants participants: [Participant]) {
        // Identities are account ids — the token's `sub` — lower-cased so a
        // roster row's UUID compares without caring about case.
        let identities = Set(participants.compactMap { $0.identity?.stringValue.lowercased() })
        Task { @MainActor [weak self] in
            self?.speakingIdentities = identities
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue.lowercased() ?? ""
        Task { @MainActor [weak self] in
            self?.onRoomEvent?(.participantJoined(identity: identity))
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue.lowercased() ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.mutedIdentities.remove(identity)
            self.onRoomEvent?(.participantLeft(identity: identity))
        }
    }

    nonisolated public func room(
        _ room: LiveKit.Room,
        participant: Participant,
        didUpdatePermissions permissions: ParticipantPermissions
    ) {
        let isLocal = participant is LocalParticipant
        let allowed = permissions.canPublish
        Task { @MainActor [weak self] in
            guard let self, isLocal else { return }
            self.canPublish = allowed
            if !allowed, self.isMicrophoneEnabled {
                // The server took the microphone; the SDK stops the track. The
                // flag follows so the button does not claim otherwise.
                self.isMicrophoneEnabled = false
            }
            self.onRoomEvent?(.permissionsChanged(canPublish: allowed))
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, participant: Participant, didUpdateMetadata metadata: String?) {
        let identity = participant.identity?.stringValue.lowercased() ?? ""
        Task { @MainActor [weak self] in
            self?.onRoomEvent?(.metadataChanged(identity: identity))
        }
    }

    nonisolated public func room(
        _ room: LiveKit.Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didUpdateIsMuted isMuted: Bool
    ) {
        guard trackPublication.kind == .audio else { return }
        let identity = participant.identity?.stringValue.lowercased() ?? ""
        let isLocal = participant is LocalParticipant
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isLocal {
                // A host-side mute lands here as the track going quiet under
                // us; the microphone flag has to follow or the button lies.
                if isMuted { self.isMicrophoneEnabled = false }
            } else if isMuted {
                self.mutedIdentities.insert(identity)
            } else {
                self.mutedIdentities.remove(identity)
            }
            self.onRoomEvent?(.muteChanged(identity: identity, isMuted: isMuted))
        }
    }

    nonisolated public func room(
        _ room: LiveKit.Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String
    ) {
        guard topic == RoomDataMessage.topic, let message = RoomDataMessage.decode(data) else { return }
        Task { @MainActor [weak self] in
            self?.onRoomEvent?(.message(message))
        }
    }
}

// MARK: - Permission

/// The real microphone prompt.
///
/// Asked exactly once per app install by iOS, and asked by Sila only when
/// somebody takes the microphone — never on entering a room.
public struct SystemMicrophonePermission: MicrophonePermissionRequesting {

    public init() {}

    public func requestPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            // Do **not** re-prompt: iOS will not show the dialog a second time,
            // and the caller has a sentence pointing at Settings.
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}
