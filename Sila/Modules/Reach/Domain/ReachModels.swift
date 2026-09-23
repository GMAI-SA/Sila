import Foundation

// MARK: - Contract v21: reaching a closed app

/// Whether this account asked to be reminded about a scheduled room.
public struct RoomReminder: Equatable, Sendable, Decodable {
    public let roomId: UUID
    public let reminderSet: Bool
    public let reminderCount: Int

    public init(roomId: UUID, reminderSet: Bool, reminderCount: Int) {
        self.roomId = roomId
        self.reminderSet = reminderSet
        self.reminderCount = reminderCount
    }

    private enum CodingKeys: String, CodingKey { case roomId, reminderSet, reminderCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        reminderSet = (try? c.decode(Bool.self, forKey: .reminderSet)) ?? false
        reminderCount = (try? c.decode(Int.self, forKey: .reminderCount)) ?? 0
    }
}

/// A weekly room: the same title, the same hour, every week.
public struct RoomSeries: Identifiable, Equatable, Sendable, Decodable {
    public let id: UUID
    public let title: String
    public let topic: String?
    public let starterQuestion: String?
    public let host: UserSummary?
    /// Monday = 0.
    public let weekday: Int
    public let localTime: String
    public let timezone: String
    public let nextAt: Date?
    public let nextRoomId: UUID?
    public let followerCount: Int
    public let following: Bool
    public let isHost: Bool
    public let ended: Bool

    public init(id: UUID = UUID(), title: String, topic: String? = nil, starterQuestion: String? = nil,
                host: UserSummary? = nil, weekday: Int = 0, localTime: String = "21:00", timezone: String = "Asia/Riyadh",
                nextAt: Date? = nil, nextRoomId: UUID? = nil, followerCount: Int = 0, following: Bool = false,
                isHost: Bool = false, ended: Bool = false) {
        self.id = id; self.title = title; self.topic = topic; self.starterQuestion = starterQuestion
        self.host = host; self.weekday = weekday; self.localTime = localTime; self.timezone = timezone
        self.nextAt = nextAt; self.nextRoomId = nextRoomId; self.followerCount = followerCount
        self.following = following; self.isHost = isHost; self.ended = ended
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, topic, starterQuestion, host, weekday, localTime, timezone, nextAt, nextRoomId
        case followerCount, following, isHost, ended
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        topic = (try? c.decodeIfPresent(String.self, forKey: .topic)) ?? nil
        starterQuestion = (try? c.decodeIfPresent(String.self, forKey: .starterQuestion)) ?? nil
        host = (try? c.decodeIfPresent(UserSummary.self, forKey: .host)) ?? nil
        weekday = (try? c.decode(Int.self, forKey: .weekday)) ?? 0
        localTime = (try? c.decode(String.self, forKey: .localTime)) ?? ""
        timezone = (try? c.decode(String.self, forKey: .timezone)) ?? ""
        nextAt = (try? c.decodeIfPresent(Date.self, forKey: .nextAt)) ?? nil
        nextRoomId = (try? c.decodeIfPresent(UUID.self, forKey: .nextRoomId)) ?? nil
        followerCount = (try? c.decode(Int.self, forKey: .followerCount)) ?? 0
        following = (try? c.decode(Bool.self, forKey: .following)) ?? false
        isHost = (try? c.decode(Bool.self, forKey: .isHost)) ?? false
        ended = (try? c.decode(Bool.self, forKey: .ended)) ?? false
    }

    /// "Every Tuesday at 21:00", in the reader's language.
    public var scheduleLine: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        let names = calendar.weekdaySymbols // Sunday first
        let name = names[(weekday + 1) % 7]
        return L10n.t("rooms.series.every", name, localTime)
    }
}

/// `POST /rooms/series`.
public struct CreateSeriesRequest: Encodable, Equatable, Sendable {
    public let title: String
    public let topic: String?
    public let starterQuestion: String?
    public let scope: String
    public let scopeCountry: String?
    public let scopeRegion: String?
    public let weekday: Int
    public let localTime: String
    public let timezone: String
    public let durationMinutes: Int

    /// The series that repeats a room scheduled for `date`, in this phone's
    /// time zone.
    public init(title: String, topic: String?, starterQuestion: String?, scope: ComposeScope,
                repeating date: Date, timeZone: TimeZone = .current, durationMinutes: Int = 60) {
        self.title = title
        self.topic = topic
        self.starterQuestion = starterQuestion
        self.scope = scope.wireValue
        self.scopeCountry = scope.scopeCountry
        self.scopeRegion = scope.scopeRegion
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        // Calendar: Sunday = 1 … Saturday = 7. The server: Monday = 0.
        self.weekday = ((parts.weekday ?? 2) + 5) % 7
        self.localTime = String(format: "%02d:%02d", parts.hour ?? 21, parts.minute ?? 0)
        self.timezone = timeZone.identifier
        self.durationMinutes = durationMinutes
    }
}

/// Sila's question of the week (`GET /prompts/current`).
public struct WeeklyPrompt: Identifiable, Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable { case text, poll, voice, room }

    public let id: UUID
    public let title: String
    public let titleAr: String?
    public let body: String?
    public let bodyAr: String?
    public let hashtag: String
    public let kind: Kind
    public let expiresAt: Date?
    public let live: Bool
    public let responseCount: Int
    public let rhythmKey: String?

    public init(id: UUID = UUID(), title: String, titleAr: String? = nil, body: String? = nil, bodyAr: String? = nil,
                hashtag: String, kind: Kind = .text, expiresAt: Date? = nil, live: Bool = true,
                responseCount: Int = 0, rhythmKey: String? = nil) {
        self.id = id; self.title = title; self.titleAr = titleAr; self.body = body; self.bodyAr = bodyAr
        self.hashtag = hashtag; self.kind = kind; self.expiresAt = expiresAt; self.live = live
        self.responseCount = responseCount; self.rhythmKey = rhythmKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleAr, body, bodyAr, hashtag, kind, expiresAt, live, responseCount, rhythmKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        titleAr = (try? c.decodeIfPresent(String.self, forKey: .titleAr)) ?? nil
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? nil
        bodyAr = (try? c.decodeIfPresent(String.self, forKey: .bodyAr)) ?? nil
        hashtag = ((try? c.decode(String.self, forKey: .hashtag)) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .text
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
        live = (try? c.decode(Bool.self, forKey: .live)) ?? false
        responseCount = (try? c.decode(Int.self, forKey: .responseCount)) ?? 0
        rhythmKey = (try? c.decodeIfPresent(String.self, forKey: .rhythmKey)) ?? nil
    }

    public func localizedTitle(_ language: String = L10n.languageCode) -> String {
        language == "ar" && titleAr?.isEmpty == false ? titleAr! : title
    }

    public func localizedBody(_ language: String = L10n.languageCode) -> String? {
        let value = language == "ar" && bodyAr?.isEmpty == false ? bodyAr : body
        return value?.isEmpty == false ? value : nil
    }

    /// The hashtag as it goes in a post.
    public var tag: String { "#\(hashtag)" }
}

struct CurrentPromptResponse: Decodable {
    let prompt: WeeklyPrompt?
    private enum CodingKeys: String, CodingKey { case prompt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = (try? c.decodeIfPresent(WeeklyPrompt.self, forKey: .prompt)) ?? nil
    }
}

/// What a composer opens with — from a prompt, a starter, a series.
public struct ComposerPrefill: Equatable, Sendable {
    public var text: String
    public var hashtag: String?
    public var poll: Bool
    public var voiceKind: VoiceKind?

    public init(text: String = "", hashtag: String? = nil, poll: Bool = false, voiceKind: VoiceKind? = nil) {
        self.text = text
        self.hashtag = hashtag
        self.poll = poll
        self.voiceKind = voiceKind
    }

    /// The text with the hashtag appended once.
    public var composedText: String {
        guard let hashtag, !hashtag.isEmpty else { return text }
        let tag = hashtag.hasPrefix("#") ? hashtag : "#\(hashtag)"
        if text.localizedCaseInsensitiveContains(tag) { return text }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "\(tag) " : "\(base) \(tag)"
    }
}

// MARK: - Push

/// `PUT /me/devices` / `DELETE /me/devices`.
struct DeviceRegistration: Encodable, Equatable {
    let platform: String
    let transport: String
    let token: String
    let environment: String?
    let locale: String?
    let timezone: String?
    let appVersion: String?
}

struct DeviceRemoval: Encodable, Equatable {
    let transport: String
    let token: String
}

/// The quiet hours on push: minutes after midnight, in the account's time zone.
public struct QuietHours: Equatable, Sendable, Codable {
    public var startMin: Int
    public var endMin: Int

    public init(startMin: Int, endMin: Int) {
        self.startMin = startMin
        self.endMin = endMin
    }
}

/// Every push loc-key the server may send (contract v21 + v23). Listed here so
/// the catalogue test sees each `push.` key used, and so a test can assert
/// every one has a sentence in both languages.
public enum PushCopy {
    public static let keys: [String] = [
        "push.reply", "push.mention", "push.like", "push.repost", "push.follow", "push.follow_request",
        "push.follow_accepted", "push.message", "push.room_invite", "push.room_like", "push.room_shared",
        "push.room_tomorrow", "push.room_soon", "push.room_live", "push.room_cancelled", "push.community_invite",
        "push.community_join_request", "push.community_accepted", "push.poll_closed", "push.prompt",
        "push.identity_impostor", "push.reaction", "push.thread_reply", "push.event_invite", "push.event_tomorrow",
        "push.event_soon", "push.event_live", "push.event_changed", "push.event_cancelled"
    ]
}
