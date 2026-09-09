import Foundation

/// Scripted ``VoiceEngineProtocol`` for tests, previews and mocked builds.
///
/// It enforces the one rule that matters rather than recording it: **a
/// connection made with `canPublish: false` refuses to open the microphone.**
/// That is what the media server does with a listener's token, and a mock that
/// let the call through would let a test pass that the real thing would fail —
/// which on this surface means shipping a mic button that does nothing.
@MainActor
public final class VoiceEngineMock: VoiceEngineProtocol {

    public private(set) var connection: VoiceConnectionState = .idle {
        didSet { if connection != oldValue { onChange?() } }
    }
    public private(set) var isMicrophoneEnabled = false {
        didSet { if isMicrophoneEnabled != oldValue { onChange?() } }
    }
    public private(set) var speakingIdentities: Set<String> = []
    public private(set) var mutedIdentities: Set<String> = []
    public private(set) var canPublish = false
    public var onChange: (@MainActor () -> Void)?
    public var onRoomEvent: (@MainActor (VoiceRoomEvent) -> Void)?
    /// Every data message this engine was asked to send.
    public private(set) var publishedMessages: [RoomDataMessage] = []
    /// Who each message was addressed to; empty means the whole room.
    public private(set) var publishedDestinations: [[String]] = []

    /// Calls in order, e.g. `["connect:listener", "mic:on"]`.
    public private(set) var recordedCalls: [String] = []
    /// What the last connection's token permitted.
    public private(set) var connectedCanPublish = false
    /// The URL and token last connected with, for assertions.
    public private(set) var connectedURL: String?
    public private(set) var connectedToken: String?
    /// How many times ``disconnect()`` ran. A leave must produce exactly one.
    public private(set) var disconnectCount = 0

    /// When set, ``connect(url:token:canPublish:)`` throws it.
    public var connectError: VoiceEngineError?
    /// Whether iOS would grant the microphone.
    public var isPermissionGranted: Bool

    /// - Parameter isPermissionGranted: `false` drives the denied path.
    public init(isPermissionGranted: Bool = true) {
        self.isPermissionGranted = isPermissionGranted
    }

    public func connect(url: String, token: String, canPublish: Bool) async throws {
        recordedCalls.append("connect:\(canPublish ? "publisher" : "listener")")
        connectedURL = url
        connectedToken = token
        if let connectError {
            connection = .failed(connectError.userMessage)
            throw connectError
        }
        connectedCanPublish = canPublish
        self.canPublish = canPublish
        connection = .connected
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        recordedCalls.append("mic:\(enabled ? "on" : "off")")
        if enabled {
            // The whole point of this mock. A listener's token cannot publish,
            // and pretending otherwise here would hide the bug it exists to catch.
            guard connectedCanPublish else { throw VoiceEngineError.notPermittedToPublish }
            guard isPermissionGranted else { throw VoiceEngineError.microphoneDenied }
        }
        isMicrophoneEnabled = enabled
    }

    public func disconnect() async {
        recordedCalls.append("disconnect")
        disconnectCount += 1
        isMicrophoneEnabled = false
        connectedCanPublish = false
        canPublish = false
        speakingIdentities = []
        mutedIdentities = []
        connection = .idle
    }

    public func publish(_ message: RoomDataMessage, to identities: [String]) async {
        publishedDestinations.append(identities)
        recordedCalls.append("data:\(message.type):\(message.raised)")
        publishedMessages.append(message)
    }

    // MARK: - Test hooks

    /// Simulates the media server applying `UpdateParticipant` to this
    /// connection — the promotion that needs no reconnect.
    public func setCanPublish(_ value: Bool) {
        connectedCanPublish = value
        canPublish = value
        if !value, isMicrophoneEnabled { isMicrophoneEnabled = false }
        onChange?()
        onRoomEvent?(.permissionsChanged(canPublish: value))
    }

    /// Simulates any room event arriving from the media server.
    public func simulate(_ event: VoiceRoomEvent) {
        if case let .muteChanged(identity, isMuted) = event {
            if isMuted { mutedIdentities.insert(identity) } else { mutedIdentities.remove(identity) }
            onChange?()
        }
        onRoomEvent?(event)
    }

    /// Simulates the media server reporting who is talking.
    public func setSpeaking(_ identities: Set<String>) {
        speakingIdentities = identities
        onChange?()
    }

    /// Simulates a socket dropping under the app.
    public func simulateFailure(_ message: String) {
        isMicrophoneEnabled = false
        connection = .failed(message)
    }
}
