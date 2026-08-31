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
/// Three things here are load-bearing rather than configuration.
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
/// **Publishing is refused locally when the token does not permit it.** The
/// token is the real enforcement — the media server drops a listener's audio
/// regardless — but a client that tried anyway would sit there with an open
/// microphone and no explanation. See ``VoiceEngineError/notPermittedToPublish``.
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
    public var onChange: (@MainActor () -> Void)?

    private let room: LiveKit.Room
    private let permission: MicrophonePermissionRequesting
    /// What the current token permits. `false` until a connection says otherwise.
    private var canPublish = false

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
        } catch {
            connection = .failed(APIError.wrapping(error).userMessage)
            throw VoiceEngineError.transport(error.localizedDescription)
        }
    }

    // MARK: - The microphone

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if enabled {
            // Gate one: this token. Unreachable from the UI, which hides the
            // control for a listener — but a silent open microphone would be a
            // worse failure than a named one.
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
                error?.localizedDescription ?? "Sila couldn't reach the room's audio."
            )
        }
    }

    nonisolated public func room(_ room: LiveKit.Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let identities = Set(participants.compactMap { $0.identity?.stringValue })
        Task { @MainActor [weak self] in
            self?.speakingIdentities = identities
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
