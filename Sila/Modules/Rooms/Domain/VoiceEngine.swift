import Foundation

/// Where the media connection is.
///
/// Deliberately smaller than LiveKit's own state machine: the room screen has
/// exactly four things to say, and importing a transport's vocabulary into a
/// view model is how a UI ends up unable to change transports.
public enum VoiceConnectionState: Equatable, Sendable {
    /// Nothing connected, nothing being attempted.
    case idle
    /// A socket is being opened.
    case connecting
    /// Audio is flowing.
    case connected
    /// The socket dropped and the SDK is retrying.
    case reconnecting
    /// It failed, and this is the sentence to show.
    case failed(String)

    /// `true` when audio is, or is about to be, flowing.
    public var isActive: Bool {
        switch self {
        case .connected, .connecting, .reconnecting: return true
        case .idle, .failed: return false
        }
    }

    /// The line under the room title, or `nil` when there is nothing to say.
    public var message: String? {
        switch self {
        case .idle, .connected: return nil
        case .connecting: return RoomCopy.connecting
        case .reconnecting: return RoomCopy.reconnecting
        case let .failed(reason): return reason
        }
    }
}

/// Why taking the microphone did not work.
public enum VoiceEngineError: Error, Equatable, Sendable {
    /// The person denied microphone access, or the device has none.
    ///
    /// The only error on this surface with an action attached, which is why it
    /// is a case rather than a string: the room screen sends people to Settings.
    case microphoneDenied
    /// The engine was asked to publish on a token that does not permit it.
    ///
    /// **This should be unreachable from the UI**, because the microphone
    /// affordance is gated on ``RoomRole/canPublish``. It exists so that if it
    /// ever *is* reached, the failure is a named client bug rather than silence
    /// the user is left to interpret — the media server would drop the audio
    /// either way.
    case notPermittedToPublish
    /// Anything the transport reported.
    case transport(String)

    /// A sentence safe to put in front of somebody.
    public var userMessage: String {
        switch self {
        case .microphoneDenied:
            return RoomCopy.microphoneDenied
        case .notPermittedToPublish:
            return "You're listening to this room, so there is no microphone to turn on."
        case let .transport(message):
            return message
        }
    }
}

/// The media transport, behind a seam.
///
/// LiveKit lives on the far side of this protocol and **nowhere else in the
/// app** — one file imports it. That is not tidiness for its own sake: it is
/// what lets every rule this feature has to hold be tested without a WebRTC
/// stack, a simulator microphone or a live media server.
///
/// The contract has one asymmetry worth naming. ``connect(url:token:canPublish:)``
/// takes `canPublish` and refuses to publish without it, which looks redundant
/// beside a token that already says the same thing. It is redundant, and it is
/// kept: the token is the enforcement, this flag is the client admitting it
/// knows, and the day the two disagree the app should fail loudly on its own
/// side rather than have audio silently dropped somewhere in Kansas.
@MainActor
public protocol VoiceEngineProtocol: AnyObject {

    /// Where the connection is.
    var connection: VoiceConnectionState { get }
    /// Whether this device is currently publishing audio.
    var isMicrophoneEnabled: Bool { get }
    /// Identities the media server says are speaking right now.
    ///
    /// The identity is the handle, which is what the server puts in the token.
    var speakingIdentities: Set<String> { get }
    /// Called on the main actor whenever anything above changed.
    var onChange: (@MainActor () -> Void)? { get set }

    /// Opens the media connection.
    /// - Parameters:
    ///   - url: The `wss://` URL from the join response.
    ///   - token: The LiveKit token from the join response.
    ///   - canPublish: What that token permits, per the server's `role`.
    func connect(url: String, token: String, canPublish: Bool) async throws

    /// Turns the microphone on or off.
    ///
    /// - Throws: ``VoiceEngineError/microphoneDenied`` when the person said no
    ///   to the system prompt, and ``VoiceEngineError/notPermittedToPublish``
    ///   when the current token does not allow publishing at all.
    func setMicrophoneEnabled(_ enabled: Bool) async throws

    /// Closes the connection and stops all audio.
    ///
    /// Must be safe to call twice, and safe to call when nothing is connected —
    /// it is called from leave, from termination and from `deinit` paths, and
    /// exactly one of those wins the race.
    func disconnect() async
}

/// The microphone permission prompt, behind a seam.
///
/// Separate from ``VoiceEngineProtocol`` for one reason: **when** it is asked
/// is a product decision, not a transport detail. Sila asks only when somebody
/// actually takes the microphone, never on entering a room — a listener needs
/// no microphone and being asked for one on the way in teaches them that this
/// app wants more than it needs.
public protocol MicrophonePermissionRequesting: Sendable {

    /// Asks iOS, or returns the standing answer if there already is one.
    /// - Returns: `true` when recording is permitted.
    func requestPermission() async -> Bool
}

/// A ``MicrophonePermissionRequesting`` with a fixed answer, for tests.
public struct StaticMicrophonePermission: MicrophonePermissionRequesting {

    private let isGranted: Bool

    public init(isGranted: Bool = true) {
        self.isGranted = isGranted
    }

    public func requestPermission() async -> Bool { isGranted }
}
