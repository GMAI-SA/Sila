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
            return L10n.t("rooms.voice.notPermittedToPublish")
        case let .transport(message):
            return message
        }
    }
}

/// Something the media server said about the room, forwarded so the roster
/// can react at once instead of on the next poll.
///
/// Deliberately coarse. The room screen re-reads the roster from the API on
/// any of these — the API row is the truth — so the event only has to say
/// *that* something changed, and, for the two that change what the viewer
/// may do right now, what.
public enum VoiceRoomEvent: Equatable, Sendable {
    /// Somebody's connection arrived.
    case participantJoined(identity: String)
    /// Somebody's connection went.
    case participantLeft(identity: String)
    /// The server changed what *this* connection may do — a promotion or
    /// demotion applied live, without a reconnect.
    case permissionsChanged(canPublish: Bool)
    /// Somebody's role announcement changed.
    case metadataChanged(identity: String)
    /// Somebody's microphone was muted or unmuted — by them, or by the host.
    case muteChanged(identity: String, isMuted: Bool)
    /// A data message from another participant.
    case message(RoomDataMessage)
}

/// What travels over a room's data channel.
///
/// Three kinds, all of them ephemeral: a hand going up or down, a reaction,
/// and a line of text. The hand is sent *as well as* the API call, never
/// instead of it — the API row is the queue the host decides from, and this
/// is the nudge that refreshes their screen now. Reactions and chat have no
/// API at all: like the audio, they exist while the room does and are not
/// kept afterwards, which is what lets a listener join in without asking
/// anybody for permission first.
public struct RoomDataMessage: Codable, Equatable, Sendable {
    public static let topic = "sila.room"

    /// `hand`, `reaction` or `chat`.
    public let type: String
    /// The account the message is about, or from.
    public let userId: String
    /// For `hand`: whether it went up.
    public let raised: Bool
    /// For `reaction`: the emoji.
    public let emoji: String?
    /// For `chat`: what was said.
    public let text: String?
    /// Who sent it, so a receiver can render without a roster lookup — a
    /// listener is not on the stage and may not be on the page the host has.
    public let handle: String?
    public let name: String?
    /// For `chat`: sent to the host alone rather than to the room. Addressed
    /// on the wire too, so "only the host" means only the host receives it.
    public let toHost: Bool

    public init(
        type: String = "hand",
        userId: String,
        raised: Bool = false,
        emoji: String? = nil,
        text: String? = nil,
        handle: String? = nil,
        name: String? = nil,
        toHost: Bool = false
    ) {
        self.type = type
        self.userId = userId
        self.raised = raised
        self.emoji = emoji
        self.text = text
        self.handle = handle
        self.name = name
        self.toHost = toHost
    }

    public static func hand(userId: UUID, raised: Bool) -> RoomDataMessage {
        RoomDataMessage(userId: userId.uuidString.lowercased(), raised: raised)
    }

    /// An emoji, from anybody in the room including the audience.
    public static func reaction(_ emoji: String, userId: UUID, handle: String?, name: String?) -> RoomDataMessage {
        RoomDataMessage(
            type: "reaction",
            userId: userId.uuidString.lowercased(),
            emoji: emoji,
            handle: handle,
            name: name
        )
    }

    /// A line of text, to the room or to the host alone.
    public static func chat(
        _ text: String,
        userId: UUID,
        handle: String?,
        name: String?,
        toHost: Bool
    ) -> RoomDataMessage {
        RoomDataMessage(
            type: "chat",
            userId: userId.uuidString.lowercased(),
            text: text,
            handle: handle,
            name: name,
            toHost: toHost
        )
    }

    public var isHand: Bool { type == "hand" }
    public var isReaction: Bool { type == "reaction" && !(emoji ?? "").isEmpty }
    public var isChat: Bool { type == "chat" && !(text ?? "").isEmpty }

    private enum CodingKeys: String, CodingKey {
        case type, userId, raised, emoji, text, handle, name, toHost
    }

    /// Tolerant: a build that has never heard of a type still decodes the
    /// fields it knows rather than dropping the whole message.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? "hand"
        userId = (try? container.decode(String.self, forKey: .userId)) ?? ""
        raised = ((try? container.decode(Bool.self, forKey: .raised)) ?? nil) ?? false
        emoji = (try? container.decodeIfPresent(String.self, forKey: .emoji)) ?? nil
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
        handle = (try? container.decodeIfPresent(String.self, forKey: .handle)) ?? nil
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        toHost = ((try? container.decodeIfPresent(Bool.self, forKey: .toHost)) ?? nil) ?? false
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> RoomDataMessage? {
        try? JSONDecoder().decode(RoomDataMessage.self, from: data)
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
    /// The identity is the **account id** (lower-cased UUID string), which is
    /// what the server puts in the token's `sub`. Never the handle.
    var speakingIdentities: Set<String> { get }
    /// Identities whose microphone is currently muted — including by the host.
    var mutedIdentities: Set<String> { get }
    /// What the live connection may do right now. Starts as what the token
    /// said; changes when the server applies a promotion or demotion live.
    var canPublish: Bool { get }
    /// Called on the main actor whenever anything above changed.
    var onChange: (@MainActor () -> Void)? { get set }
    /// Called on the main actor with every room event the media server reports.
    var onRoomEvent: (@MainActor (VoiceRoomEvent) -> Void)? { get set }

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

    /// Sends a data message to everyone in the room. Best-effort: a failure
    /// costs the host a few seconds of poll latency, never the request itself,
    /// which went to the API first.
    /// Sends a data message to the room, or to named identities only.
    func publish(_ message: RoomDataMessage, to identities: [String]) async
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

extension VoiceEngineProtocol {
    /// To everybody in the room.
    public func publish(_ message: RoomDataMessage) async {
        await publish(message, to: [])
    }
}

