import Foundation

/// Scripted ``RoomsServiceProtocol`` for tests, previews and the `-mockRooms`
/// launch argument.
///
/// It behaves like the server rather than saying yes to everything: a promotion
/// changes a role and the *next* join hands back a different token, an ended
/// room stops being joinable, and a removed viewer is refused at the door with
/// ``APIErrorCode/removedFromRoom`` rather than being quietly let in muted.
/// Those three are the only interesting behaviours on this surface, and a mock
/// that shortcut any of them would make the tests above it worthless.
///
/// The cast is ``FeedServiceMock``'s, so a room opened in a mocked build is
/// hosted by somebody whose profile exists.
public actor RoomsServiceMock: RoomsServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Three live rooms and two scheduled. The viewer may speak in one.
        case populated
        /// Nothing live, nothing scheduled.
        case empty
        /// The viewer is a listener everywhere — every room refuses the mic
        /// with a scope reason.
        case listenerOnly
        /// The viewer hosts the first room, so the host controls are reachable.
        case hosting
        /// The viewer has been removed from the first room.
        case removed
        /// Every call fails with a transport error.
        case offline
        /// Reads fine; every write is throttled with `429`.
        case writesFail
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    private let latency: Double

    /// The stored rooms, live first.
    private var stored: [VoiceRoom]
    /// Who is in which room.
    private var rosters: [UUID: [RoomParticipant]] = [:]
    /// Calls recorded for test assertions, e.g. `"join:…"`.
    public private(set) var recordedCalls: [String] = []
    /// The viewer's own handle, for the host-only refusals.
    private let viewerHandle: String

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay. Tests pass `0`.
    ///   - viewerHandle: Who the caller is.
    public init(
        scenario: MockScenario = .populated,
        latency: Double = 0,
        viewerHandle: String = "aziz"
    ) {
        self.scenario = scenario
        self.latency = latency
        self.viewerHandle = viewerHandle
        switch scenario {
        case .empty, .offline:
            stored = []
        case .listenerOnly:
            stored = Self.cast.map { Self.asListener($0) }
        case .hosting:
            stored = Self.cast.enumerated().map { index, room in
                index == 0 ? Self.asHost(room) : room
            }
        case .removed:
            stored = Self.cast.enumerated().map { index, room in
                index == 0 ? Self.asRemoved(room) : room
            }
        case .populated, .writesFail:
            stored = Self.cast
        }
        rosters = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, Self.roster(for: $0)) })
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - Reading

    public func fetchRooms(status: RoomStatus?, topic: String?, limit: Int) async throws -> [VoiceRoom] {
        recordedCalls.append("fetchRooms:\(status?.rawValue ?? "all"):\(topic ?? "any")")
        try await delay()
        try failIfOffline()
        var rows = stored
        if let status { rows = rows.filter { $0.status == status } }
        if let topic, !topic.isEmpty { rows = rows.filter { $0.topic == topic } }
        return Array(rows.prefix(max(1, min(limit, RoomConstants.maximumLimit))))
    }

    public func fetchRoom(id: UUID) async throws -> VoiceRoom {
        recordedCalls.append("fetchRoom")
        try await delay()
        try failIfOffline()
        guard let room = stored.first(where: { $0.id == id }) else { throw Self.notFound }
        return room
    }

    public func fetchParticipants(roomId: UUID) async throws -> RoomParticipantList {
        recordedCalls.append("participants")
        try await delay()
        try failIfOffline()
        return RoomParticipantList(participants: rosters[roomId] ?? [])
    }

    public func searchRooms(query: String, limit: Int) async throws -> [VoiceRoom] {
        recordedCalls.append("search:\(query)")
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RoomConstants.isSearchable(trimmed) else { return [] }
        try await delay()
        try failIfOffline()
        return stored.filter { room in
            room.title.localizedCaseInsensitiveContains(trimmed)
                || (room.topicLabel?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    // MARK: - Creating

    public func createRoom(_ request: CreateRoomRequest) async throws -> VoiceRoom {
        recordedCalls.append("create:\(request.scope)")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        let room = VoiceRoom(
            id: UUID(),
            title: request.title,
            topic: request.topic,
            scope: PostScope(rawValue: request.scope) ?? .international,
            scopeCountry: request.scopeCountry,
            scopeRegion: request.scopeRegion,
            status: request.scheduledFor == nil ? .live : .scheduled,
            host: FeedServiceMock.aziz,
            speakerCount: 1,
            listenerCount: 0,
            scheduledFor: request.scheduledFor,
            startedAt: request.scheduledFor == nil ? Date() : nil,
            createdAt: Date(),
            canSpeak: true,
            speakRefusal: nil,
            isHost: true,
            isRemoved: false
        )
        stored.insert(room, at: 0)
        rosters[room.id] = [RoomParticipant(role: .host, user: FeedServiceMock.aziz, joinedAt: Date())]
        return room
    }

    // MARK: - Joining and leaving

    public func join(roomId: UUID) async throws -> RoomJoin {
        recordedCalls.append("join")
        try await delay()
        try failIfOffline()

        let room = try await fetchRoom(id: roomId)
        // The two refusals that exist at the door. Neither is about listening
        // in general — one is this room only, the other is this room being over.
        guard !room.isRemoved else {
            throw APIError.api(code: .removedFromRoom, message: "Removed from room", status: 403)
        }
        guard room.status == .live else {
            throw APIError.api(code: .roomEnded, message: "Room ended", status: 409)
        }

        // The role, and therefore the token's grant, follows the server's
        // `can_speak` — never a client-side reading of the scope.
        let role: RoomRole = room.isHost ? .host : (room.canSpeak ? .speaker : .listener)
        return RoomJoin(
            room: room,
            url: "wss://sila.gmai.sa/rtc",
            // A token shaped like a JWT so nothing downstream can accidentally
            // depend on its contents; the mock's grant is `role`.
            token: "mock.\(role.rawValue).\(roomId.uuidString.prefix(8))",
            role: role
        )
    }

    public func leave(roomId: UUID) async throws {
        recordedCalls.append("leave")
        try await delay()
        try failIfOffline()
    }

    // MARK: - Host controls

    public func endRoom(id: UUID) async throws -> VoiceRoom {
        recordedCalls.append("end")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        let room = try await fetchRoom(id: id)
        try requireHost(room)
        let ended = Self.copy(room, status: .ended)
        replace(ended)
        return ended
    }

    public func promote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        recordedCalls.append("promote:\(Handle.normalised(handle))")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        let room = try await fetchRoom(id: roomId)
        try requireHost(room)
        setRole(.speaker, handle: handle, in: roomId)
        let updated = Self.copy(room, speakerCount: room.speakerCount + 1, listenerCount: max(0, room.listenerCount - 1))
        replace(updated)
        return updated
    }

    public func demote(roomId: UUID, handle: String) async throws -> VoiceRoom {
        recordedCalls.append("demote:\(Handle.normalised(handle))")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        let room = try await fetchRoom(id: roomId)
        try requireHost(room)
        guard Handle.normalised(handle) != room.host.handle else {
            throw APIError.api(code: .cannotDemoteHost, message: "Cannot demote host", status: 400)
        }
        setRole(.listener, handle: handle, in: roomId)
        let updated = Self.copy(room, speakerCount: max(0, room.speakerCount - 1), listenerCount: room.listenerCount + 1)
        replace(updated)
        return updated
    }

    public func remove(roomId: UUID, handle: String) async throws -> VoiceRoom {
        recordedCalls.append("remove:\(Handle.normalised(handle))")
        try await delay()
        try failIfOffline()
        try failIfWritesFail()

        let room = try await fetchRoom(id: roomId)
        try requireHost(room)
        let target = Handle.normalised(handle)
        rosters[roomId] = (rosters[roomId] ?? []).filter { $0.user.handle != target }
        let updated = Self.copy(room, listenerCount: max(0, room.listenerCount - 1))
        replace(updated)
        return updated
    }

    // MARK: - Internals

    private func requireHost(_ room: VoiceRoom) throws {
        guard room.isHost else {
            throw APIError.api(code: .notRoomHost, message: "Not the host", status: 403)
        }
    }

    private func replace(_ room: VoiceRoom) {
        guard let index = stored.firstIndex(where: { $0.id == room.id }) else { return }
        stored[index] = room
    }

    private func setRole(_ role: RoomRole, handle: String, in roomId: UUID) {
        let target = Handle.normalised(handle)
        rosters[roomId] = (rosters[roomId] ?? []).map { row in
            row.user.handle == target
                ? RoomParticipant(role: role, user: row.user, joinedAt: row.joinedAt)
                : row
        }
    }

    private static let notFound = APIError.api(code: .notFound, message: "Room not found", status: 404)

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }

    private func failIfWritesFail() throws {
        if scenario == .writesFail {
            throw APIError.api(code: .rateLimited, message: "Too many requests", status: 429)
        }
    }

    // MARK: - Fixture world

    private static func id(_ suffix: Int) -> UUID {
        let padded = String(format: "%012d", suffix)
        return UUID(uuidString: "00000000-0000-4000-8000-\(padded)") ?? UUID()
    }

    private static func minutesAgo(_ minutes: Double) -> Date {
        Date().addingTimeInterval(-minutes * 60)
    }

    private static func minutesAhead(_ minutes: Double) -> Date {
        Date().addingTimeInterval(minutes * 60)
    }

    /// The one country room the demo viewer cannot speak in, plus the refusal
    /// the server would send — which the UI renders verbatim.
    static let cast: [VoiceRoom] = [
        VoiceRoom(
            id: id(701),
            title: "What verification actually changes",
            topic: "technology",
            scope: .international,
            status: .live,
            host: FeedServiceMock.yuki,
            speakerCount: 3,
            listenerCount: 41,
            startedAt: minutesAgo(18),
            createdAt: minutesAgo(22),
            canSpeak: true
        ),
        VoiceRoom(
            id: id(702),
            title: "قهوة الصباح — Riyadh morning",
            topic: "culture",
            scope: .country,
            scopeCountry: "SA",
            status: .live,
            host: FeedServiceMock.noor,
            speakerCount: 5,
            listenerCount: 112,
            startedAt: minutesAgo(64),
            createdAt: minutesAgo(70),
            canSpeak: false,
            speakRefusal: "Only 🇸🇦 Saudi Arabia-verified accounts can speak in this room. You can still listen."
        ),
        VoiceRoom(
            id: id(703),
            title: "Founders in the Gulf: raising in 2026",
            topic: "business",
            scope: .region,
            scopeRegion: "GCC",
            status: .live,
            host: FeedServiceMock.maria,
            speakerCount: 2,
            listenerCount: 9,
            startedAt: minutesAgo(4),
            createdAt: minutesAgo(6),
            canSpeak: false,
            speakRefusal: "Only accounts verified in the GCC region can speak in this room. You can still listen."
        ),
        VoiceRoom(
            id: id(704),
            title: "Weekly science reading group",
            topic: "science",
            scope: .international,
            status: .scheduled,
            host: FeedServiceMock.maria,
            speakerCount: 0,
            listenerCount: 0,
            scheduledFor: minutesAhead(180),
            createdAt: minutesAgo(400),
            canSpeak: true
        ),
        VoiceRoom(
            id: id(705),
            title: "Match review, live after the whistle",
            topic: "sports",
            scope: .international,
            status: .scheduled,
            host: FeedServiceMock.yuki,
            speakerCount: 0,
            listenerCount: 0,
            scheduledFor: minutesAhead(60 * 26),
            createdAt: minutesAgo(90),
            canSpeak: true
        )
    ]

    private static func copy(
        _ room: VoiceRoom,
        status: RoomStatus? = nil,
        speakerCount: Int? = nil,
        listenerCount: Int? = nil,
        canSpeak: Bool? = nil,
        speakRefusal: String?? = nil,
        isHost: Bool? = nil,
        isRemoved: Bool? = nil
    ) -> VoiceRoom {
        VoiceRoom(
            id: room.id,
            title: room.title,
            topic: room.topic,
            scope: room.scope,
            scopeCountry: room.scopeCountry,
            scopeRegion: room.scopeRegion,
            status: status ?? room.status,
            host: room.host,
            speakerCount: speakerCount ?? room.speakerCount,
            listenerCount: listenerCount ?? room.listenerCount,
            scheduledFor: room.scheduledFor,
            startedAt: room.startedAt,
            createdAt: room.createdAt,
            canSpeak: canSpeak ?? room.canSpeak,
            speakRefusal: speakRefusal ?? room.speakRefusal,
            isHost: isHost ?? room.isHost,
            isRemoved: isRemoved ?? room.isRemoved
        )
    }

    private static func asListener(_ room: VoiceRoom) -> VoiceRoom {
        copy(
            room,
            canSpeak: false,
            speakRefusal: room.speakRefusal
                ?? "Only accounts verified in this room's audience can speak here. You can still listen.",
            isHost: false
        )
    }

    private static func asHost(_ room: VoiceRoom) -> VoiceRoom {
        VoiceRoom(
            id: room.id,
            title: room.title,
            topic: room.topic,
            scope: room.scope,
            scopeCountry: room.scopeCountry,
            scopeRegion: room.scopeRegion,
            status: room.status,
            host: FeedServiceMock.aziz,
            speakerCount: room.speakerCount,
            listenerCount: room.listenerCount,
            scheduledFor: room.scheduledFor,
            startedAt: room.startedAt,
            createdAt: room.createdAt,
            canSpeak: true,
            speakRefusal: nil,
            isHost: true,
            isRemoved: false
        )
    }

    private static func asRemoved(_ room: VoiceRoom) -> VoiceRoom {
        copy(room, canSpeak: false, speakRefusal: .some(nil), isHost: false, isRemoved: true)
    }

    private static func roster(for room: VoiceRoom) -> [RoomParticipant] {
        var rows = [RoomParticipant(role: .host, user: room.host, joinedAt: room.startedAt ?? room.createdAt)]
        let others: [UserSummary] = [
            FeedServiceMock.yuki, FeedServiceMock.maria, FeedServiceMock.noor, FeedServiceMock.pending
        ].filter { $0.handle != room.host.handle }
        for (index, user) in others.enumerated() {
            rows.append(
                RoomParticipant(
                    role: index == 0 && room.speakerCount > 1 ? .speaker : .listener,
                    user: user,
                    joinedAt: minutesAgo(Double(index) * 3 + 1)
                )
            )
        }
        return rows
    }
}
