import Foundation
import Observation

/// Who is typing where, right now (contract v30 §3.4).
///
/// One board for the app, fed by the socket, read by the thread ("typing…")
/// and by the inbox row ("Noura is typing…"), so the two can never disagree.
/// Conversations are between two people, so a thread has at most one typist:
/// the other person. Nothing here is ever stored — like the server's key, an
/// entry lives a few seconds and is gone.
///
/// An entry ends when its `expires_in` runs out without a renewal, when
/// `active: false` arrives, when that person's message arrives, and when the
/// socket goes away (nobody would say it stopped).
@MainActor
@Observable
public final class TypingBoard {

    public struct Entry: Equatable, Sendable {
        public let userId: UUID
        public let until: Date
    }

    public private(set) var entries: [UUID: Entry] = [:]

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var expiries: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - now: The clock entries expire against.
    ///   - sleep: Waits for an entry to run out. Injectable so tests decide
    ///     when time passes.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Whether somebody — `userId`, when given — is typing in the thread.
    public func isTyping(in conversationId: UUID, by userId: UUID? = nil) -> Bool {
        guard let entry = entries[conversationId], entry.until > now() else { return false }
        return userId == nil || entry.userId == userId
    }

    /// Applies a `typing` event.
    public func apply(_ event: RealtimeTyping) {
        guard event.active, event.expiresIn > 0 else {
            end(in: event.conversationId, by: event.userId)
            return
        }
        set(event.conversationId, userId: event.userId, seconds: TimeInterval(event.expiresIn))
    }

    /// What `GET /conversations/{id}/typing` said, for a thread just opened
    /// or after a reconnect.
    public func seed(conversationId: UUID, userId: UUID, status: TypingStatus) {
        if status.typing, let seconds = status.expiresIn, seconds > 0 {
            set(conversationId, userId: userId, seconds: TimeInterval(seconds))
        } else {
            end(in: conversationId, by: userId)
        }
    }

    /// That person's message arrived: they are not typing it any more.
    public func messageArrived(conversationId: UUID, from senderId: UUID) {
        end(in: conversationId, by: senderId)
    }

    /// The socket went away; nothing will say when anybody stops.
    public func clearAll() {
        for task in expiries.values { task.cancel() }
        expiries = [:]
        entries = [:]
    }

    /// Drops every entry whose time has run out.
    public func prune() {
        let moment = now()
        for (conversation, entry) in entries where entry.until <= moment {
            entries[conversation] = nil
            expiries[conversation]?.cancel()
            expiries[conversation] = nil
        }
    }

    private func set(_ conversationId: UUID, userId: UUID, seconds: TimeInterval) {
        entries[conversationId] = Entry(userId: userId, until: now().addingTimeInterval(seconds))
        expiries[conversationId]?.cancel()
        let sleep = sleep
        expiries[conversationId] = Task { [weak self] in
            await sleep(seconds)
            guard !Task.isCancelled else { return }
            self?.prune()
        }
    }

    private func end(in conversationId: UUID, by userId: UUID) {
        guard let entry = entries[conversationId], entry.userId == userId else { return }
        entries[conversationId] = nil
        expiries[conversationId]?.cancel()
        expiries[conversationId] = nil
    }
}

/// `GET /conversations/{id}/typing`.
public struct TypingStatus: Equatable, Sendable, Decodable {
    public let typing: Bool
    public let expiresIn: Int?

    public init(typing: Bool, expiresIn: Int?) {
        self.typing = typing
        self.expiresIn = expiresIn
    }

    public static let notTyping = TypingStatus(typing: false, expiresIn: nil)

    private enum CodingKeys: String, CodingKey { case typing, expiresIn }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typing = try container.decodeIfPresent(Bool.self, forKey: .typing) ?? false
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
    }
}

/// When the viewer's own typing is said, and when it stops being said.
///
/// Contract v30 §2.1: at most one `typing` every two seconds while somebody
/// types (the frames in between would be dropped by the server anyway, but
/// they count toward its limit of thirty in ten seconds), and
/// `active: false` once when the field is cleared. Sending a message ends it
/// on the server by itself, so that sends nothing.
public struct TypingThrottle: Equatable, Sendable {

    /// The contract's two seconds.
    public static let interval: TimeInterval = 2

    public private(set) var announcedAt: Date?

    public init() {}

    /// The field changed. Returns what to send: `true` for "typing", `false`
    /// for "stopped", `nil` for nothing.
    public mutating func draftChanged(isEmpty: Bool, at moment: Date) -> Bool? {
        if isEmpty {
            guard announcedAt != nil else { return nil }
            announcedAt = nil
            return false
        }
        if let last = announcedAt, moment.timeIntervalSince(last) < Self.interval { return nil }
        return true
    }

    /// The "typing" frame went out.
    public mutating func announced(at moment: Date) {
        announcedAt = moment
    }

    /// The message was sent — the server ends the typing itself — or the
    /// "stopped" frame went out some other way.
    public mutating func reset() {
        announcedAt = nil
    }

    /// Whether leaving the thread should say "stopped".
    public var isAnnounced: Bool { announcedAt != nil }
}
