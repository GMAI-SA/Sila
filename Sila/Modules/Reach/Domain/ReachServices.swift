import Foundation

/// Rooms beyond joining one: reminders and weekly series (contract v21), and
/// — later phases — co-hosts, questions, polls and chat.
public protocol RoomEngagementServiceProtocol: Sendable {
    func setReminder(_ on: Bool, roomId: UUID) async throws -> RoomReminder
    func createSeries(_ request: CreateSeriesRequest) async throws -> RoomSeries
    func fetchSeries(_ id: UUID) async throws -> RoomSeries
    func setFollowingSeries(_ on: Bool, seriesId: UUID) async throws -> RoomSeries
    func stopSeries(_ id: UUID) async throws
}

/// Where this phone gets pushes, and what happened to them.
public protocol PushServiceProtocol: Sendable {
    func register(token: String, environment: String) async throws
    func unregister(token: String) async throws
    func markOpened(pushId: String) async throws
}

/// The production services.
public final class RoomEngagementService: RoomEngagementServiceProtocol {
    let network: NetworkClient
    let tokens: AccessTokenProviding
    let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    public func setReminder(_ on: Bool, roomId: UUID) async throws -> RoomReminder {
        let token = try await tokens.accessToken()
        let reminder = try await network.send(
            APIRequest(path: "/rooms/\(id(roomId))/remind", method: on ? .post : .delete, accessToken: token),
            as: RoomReminder.self
        )
        analytics.track(on ? .roomReminderSet : .roomReminderCleared, properties: ["room_id": id(roomId)])
        return reminder
    }

    public func createSeries(_ request: CreateSeriesRequest) async throws -> RoomSeries {
        let token = try await tokens.accessToken()
        let series = try await network.send(try APIRequest.json("/rooms/series", body: request, accessToken: token),
                                            as: RoomSeries.self)
        analytics.track(.roomSeriesCreated)
        return series
    }

    public func fetchSeries(_ seriesId: UUID) async throws -> RoomSeries {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: "/rooms/series/\(id(seriesId))", accessToken: token), as: RoomSeries.self)
    }

    public func setFollowingSeries(_ on: Bool, seriesId: UUID) async throws -> RoomSeries {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/rooms/series/\(id(seriesId))/follow", method: on ? .post : .delete, accessToken: token),
            as: RoomSeries.self
        )
    }

    public func stopSeries(_ seriesId: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: "/rooms/series/\(id(seriesId))", method: .delete, accessToken: token))
    }
}

public final class PushService: PushServiceProtocol {
    private let network: NetworkClient
    private let tokens: AccessTokenProviding

    public init(network: NetworkClient, tokens: AccessTokenProviding) {
        self.network = network
        self.tokens = tokens
    }

    public func register(token device: String, environment: String) async throws {
        let token = try await tokens.accessToken()
        let body = DeviceRegistration(
            platform: "ios", transport: "apns", token: device, environment: environment,
            locale: L10n.languageCode, timezone: TimeZone.current.identifier,
            appVersion: BatchingAnalyticsClient.bundleVersion
        )
        try await network.send(try APIRequest.json("/me/devices", method: .put, body: body, accessToken: token))
    }

    public func unregister(token device: String) async throws {
        let token = try await tokens.accessToken()
        try await network.send(try APIRequest.json("/me/devices", method: .delete,
                                                   body: DeviceRemoval(transport: "apns", token: device), accessToken: token))
    }

    public func markOpened(pushId: String) async throws {
        let token = try await tokens.accessToken()
        let safe = pushId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pushId
        try await network.send(APIRequest(path: "/push/messages/\(safe)/opened", method: .post, accessToken: token))
    }
}

/// In-memory doubles for previews, UI journeys and tests.
public final class RoomEngagementServiceMock: RoomEngagementServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var reminders: Set<UUID> = []
    public private(set) var series: [UUID: RoomSeries] = [:]
    public var failing = false

    public init() {}

    private func check() throws {
        if failing { throw APIError.transport("The Internet connection appears to be offline.") }
    }

    public func setReminder(_ on: Bool, roomId: UUID) async throws -> RoomReminder {
        try check()
        return lock.withLock {
            if on { reminders.insert(roomId) } else { reminders.remove(roomId) }
            return RoomReminder(roomId: roomId, reminderSet: on, reminderCount: on ? 5 : 4)
        }
    }

    public func createSeries(_ request: CreateSeriesRequest) async throws -> RoomSeries {
        try check()
        let made = RoomSeries(title: request.title, topic: request.topic, starterQuestion: request.starterQuestion,
                              weekday: request.weekday, localTime: request.localTime, timezone: request.timezone,
                              nextAt: Date().addingTimeInterval(86_400), nextRoomId: UUID(), isHost: true)
        lock.withLock { series[made.id] = made }
        return made
    }

    public func fetchSeries(_ id: UUID) async throws -> RoomSeries {
        try check()
        return lock.withLock { series[id] } ?? RoomSeries(id: id, title: "Tuesday football talk", weekday: 1, followerCount: 12)
    }

    public func setFollowingSeries(_ on: Bool, seriesId: UUID) async throws -> RoomSeries {
        let current = try await fetchSeries(seriesId)
        let next = RoomSeries(id: current.id, title: current.title, topic: current.topic, starterQuestion: current.starterQuestion,
                              host: current.host, weekday: current.weekday, localTime: current.localTime, timezone: current.timezone,
                              nextAt: current.nextAt, nextRoomId: current.nextRoomId,
                              followerCount: current.followerCount + (on ? 1 : -1), following: on, isHost: current.isHost)
        lock.withLock { series[seriesId] = next }
        return next
    }

    public func stopSeries(_ id: UUID) async throws {
        try check()
        _ = lock.withLock { series.removeValue(forKey: id) }
    }
}

public final class PushServiceMock: PushServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var registered: [(token: String, environment: String)] = []
    public private(set) var unregistered: [String] = []
    public private(set) var opened: [String] = []

    public init() {}

    public func register(token: String, environment: String) async throws {
        lock.withLock { registered.append((token, environment)) }
    }

    public func unregister(token: String) async throws {
        lock.withLock { unregistered.append(token) }
    }

    public func markOpened(pushId: String) async throws {
        lock.withLock { opened.append(pushId) }
    }
}
