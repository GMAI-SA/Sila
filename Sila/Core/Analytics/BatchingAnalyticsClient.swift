import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The ``AnalyticsClient`` that actually sends events somewhere: `POST
/// /telemetry/events` (contract v19), on Sila's own server.
///
/// Before this, 150-odd events were recorded and sent nowhere. The rules:
///
/// - **An in-memory queue**, flushed every 30 seconds and when the app goes to
///   the background. Nothing is written to disk: a queue that outlives the app
///   is a log of somebody's behaviour sitting on their phone.
/// - **Events older than 24 hours are dropped**, not sent late — a day-old
///   event says more about the phone being offline than about the product.
/// - **A refused or failed batch stays queued** (429, no network, 5xx) and is
///   tried again next time; the queue is capped so an offline week cannot grow
///   it without bound.
/// - **Only allow-listed property keys leave the device.** The server drops
///   anything else, but a key that is never sent cannot leak. Never text a
///   person typed.
/// - A random per-install id (`anon_id`) is kept so a guest's first session
///   and the account it becomes can be joined. It identifies an install, not a
///   person, and is not derived from anything on the device.
public final class BatchingAnalyticsClient: AnalyticsClient, @unchecked Sendable {

    /// One event waiting to go.
    struct Pending: Equatable {
        let name: String
        let occurredAt: Date
        let props: [String: String]
    }

    /// Keys the server accepts (contract v19). Anything else is dropped here.
    public static let allowedKeys: Set<String> = [
        "screen", "tab", "source", "kind", "feed", "step", "method", "variant",
        "result", "reason", "topic", "position", "count", "duration_ms",
        "post_id", "room_id", "community_id", "poll_id", "prompt_id", "clip_id",
        "has_media", "is_reply", "is_guest", "first_session"
    ]

    static let maxBatch = 100
    static let maxQueue = 1_000
    static let maxAge: TimeInterval = 24 * 60 * 60
    static let flushInterval: TimeInterval = 30

    static let anonIdKey = StorageKey("com.socialsa.sila.telemetryInstallId")

    private let network: NetworkClient
    private let downstream: AnalyticsClient
    private let now: @Sendable () -> Date
    private let appVersion: String
    /// The per-install random id.
    public let anonId: String

    /// Supplies the bearer token when somebody is signed in, `nil` otherwise.
    /// Set by the container once the session exists; events recorded before
    /// then simply go as a guest's.
    public var tokenProvider: (@Sendable () async -> String?)?

    private let lock = NSLock()
    private var queue: [Pending] = []
    private var isFlushing = false
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - network: Transport.
    ///   - storage: Holds the per-install id.
    ///   - downstream: Also told every event (the debug log).
    ///   - appVersion: `"1.0.0 (14)"`-style label.
    ///   - now: Clock, injectable for tests.
    public init(
        network: NetworkClient,
        storage: StorageClient,
        downstream: AnalyticsClient = ConsoleAnalyticsClient(),
        appVersion: String = BatchingAnalyticsClient.bundleVersion,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.network = network
        self.downstream = downstream
        self.appVersion = appVersion
        self.now = now
        if let stored = storage.value(for: Self.anonIdKey, as: String.self), !stored.isEmpty {
            anonId = stored
        } else {
            let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            storage.set(fresh, for: Self.anonIdKey)
            anonId = fresh
        }
    }

    deinit {
        timer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// `"1.0.0 (14)"` from the bundle.
    public static var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return String("\(short) (\(build))".prefix(20))
    }

    // MARK: - AnalyticsClient

    public func track(_ event: AnalyticsEvent, properties: [String: String]) {
        downstream.track(event, properties: properties)
        let props = properties.filter { Self.allowedKeys.contains($0.key) }
            .mapValues { String($0.prefix(64)) }
        lock.lock(); defer { lock.unlock() }
        queue.append(Pending(name: event.rawValue, occurredAt: now(), props: props))
        if queue.count > Self.maxQueue {
            queue.removeFirst(queue.count - Self.maxQueue)
        }
    }

    // MARK: - Delivery

    /// Starts the 30-second timer and the background flush. Idempotent.
    public func start() {
        lock.lock()
        let started = timer != nil
        lock.unlock()
        guard !started else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.flushInterval * 1_000_000_000))
                await self?.flush()
            }
        }
        lock.lock(); timer = task; lock.unlock()
        #if canImport(UIKit)
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.flush() }
        }
        lock.lock(); observers.append(token); lock.unlock()
        #endif
    }

    /// Events waiting, for tests.
    var pending: [Pending] {
        lock.lock(); defer { lock.unlock() }
        return queue
    }

    /// Sends up to one batch. Returns how many events left the queue as sent.
    @discardableResult
    public func flush() async -> Int {
        let batch: [Pending]
        lock.lock()
        if isFlushing { lock.unlock(); return 0 }
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        queue.removeAll { $0.occurredAt < cutoff }
        batch = Array(queue.prefix(Self.maxBatch))
        isFlushing = !batch.isEmpty
        lock.unlock()
        guard !batch.isEmpty else { return 0 }

        defer { lock.lock(); isFlushing = false; lock.unlock() }
        let token = await tokenProvider?()
        do {
            let request = APIRequest(
                path: "/telemetry/events",
                method: .post,
                body: try body(for: batch),
                accessToken: token
            )
            try await network.send(request)
        } catch {
            // Kept for the next attempt: a 429, a timeout and a dropped
            // connection all mean "later", never "lose them".
            return 0
        }
        lock.lock()
        let sent = batch.count
        if queue.count >= sent, Array(queue.prefix(sent)) == batch {
            queue.removeFirst(sent)
        } else {
            queue.removeAll { batch.contains($0) }
        }
        lock.unlock()
        return sent
    }

    func body(for batch: [Pending]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let events: [[String: Any]] = batch.map { item in
            var event: [String: Any] = ["event": item.name, "occurred_at": formatter.string(from: item.occurredAt)]
            if !item.props.isEmpty { event["props"] = item.props }
            return event
        }
        let payload: [String: Any] = [
            "platform": "ios",
            "app_version": appVersion,
            "anon_id": anonId,
            "events": events
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
