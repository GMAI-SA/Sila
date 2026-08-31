import Foundation

/// Scripted ``SafetyServiceProtocol`` for tests, previews and the `-mockSafety`
/// launch argument.
///
/// Like ``AccountServiceMock`` it enforces the rules rather than saying yes to
/// everything, because on this surface the interesting behaviour is entirely in
/// the refusals and in the two answers that are not receipts:
///
/// * **A suspended account is refused everywhere except the two endpoints that
///   still work.** ``MockScenario/suspended`` reproduces `get_current_user`'s
///   `403 account_suspended` on every call except `GET /me/suspension` and
///   `POST /me/appeal`. That is the only way to walk the routing without
///   suspending a real account.
/// * **A `self_harm` report answers with `support`.** The one report whose
///   response is a page of help rather than a reference number. A mock that
///   returned a bare receipt for it would demo the exact screen the product
///   must not show.
///
/// The cast is ``FeedServiceMock``'s, so somebody blocked from a mocked feed is
/// the same person who wrote the post that was tapped.
public actor SafetyServiceMock: SafetyServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Two accounts already blocked, one muted, two reports on file.
        case populated
        /// Nothing blocked, nothing muted, nothing reported.
        case empty
        /// Every call fails with a transport error.
        case offline
        /// The account is suspended for a fixed period, with no appeal yet.
        case suspended
        /// Suspended with **no end date** — the case whose copy must not read as
        /// "expires today".
        case suspendedIndefinite
        /// Suspended, and the one appeal has already been used.
        case suspendedAppealed
        /// Every write is throttled with `429`.
        case rateLimited
    }

    /// The handle the mock treats as the signed-in viewer — the one that earns
    /// `self_block`, `self_mute` and `self_report`.
    public static let viewerHandle = "aziz"

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    private let latency: Double

    /// Blocked handles, mutated by accepted writes.
    private var blocked: Set<String> = []
    /// Muted handles.
    private var muted: Set<String> = []
    /// Reports filed so far, newest last.
    private var reports: [Report] = []
    /// The appeal on file, if any.
    private var appeal: SuspensionAppeal?

    /// Calls recorded for test assertions, e.g. `"setBlocked:true:yuki"`.
    public private(set) var recordedCalls: [String] = []
    /// Report bodies received, in order — the assertion surface for the form.
    public private(set) var receivedReports: [ReportRequest] = []
    /// Appeal messages received, in order.
    public private(set) var receivedAppeals: [String] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay. Tests pass `0`.
    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
        if scenario == .populated {
            blocked = ["noor"]
            muted = ["maria"]
            reports = Self.existingReports
        }
        if scenario == .suspendedAppealed {
            appeal = SuspensionAppeal(
                submittedAt: Date().addingTimeInterval(-2 * 86_400),
                status: .reviewing
            )
        }
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    /// Pre-seeds the blocked set.
    public func setBlockedHandles(_ handles: [String]) {
        blocked = Set(handles.map(Handle.normalised))
    }

    /// Pre-seeds the muted set.
    public func setMutedHandles(_ handles: [String]) {
        muted = Set(handles.map(Handle.normalised))
    }

    // MARK: - Blocking

    public func setBlocked(_ blocked: Bool, handle: String) async throws -> Bool {
        let key = Handle.normalised(handle)
        record("setBlocked:\(blocked):\(key)")
        try await delay()
        try failIfOffline()
        try failIfSuspended()
        try failIfRateLimited()
        try checkNotSelf(key, code: .selfBlock, message: "You cannot block yourself")
        _ = try person(key)

        if blocked {
            self.blocked.insert(key)
            // A block severs any follow in both directions, which is why the
            // confirmation says so — the mock drops the mute too, because a
            // blocked account is already invisible and a mute on top of it would
            // be a second row saying the same thing.
            muted.remove(key)
        } else {
            self.blocked.remove(key)
        }
        return blocked
    }

    public func fetchBlocked() async throws -> [SafetyRelation] {
        record("fetchBlocked")
        try await delay()
        try failIfOffline()
        try failIfSuspended()
        return relations(for: blocked)
    }

    // MARK: - Muting

    public func setMuted(_ muted: Bool, handle: String) async throws -> Bool {
        let key = Handle.normalised(handle)
        record("setMuted:\(muted):\(key)")
        try await delay()
        try failIfOffline()
        try failIfSuspended()
        try failIfRateLimited()
        try checkNotSelf(key, code: .selfMute, message: "You cannot mute yourself")
        _ = try person(key)

        if muted {
            self.muted.insert(key)
        } else {
            self.muted.remove(key)
        }
        return muted
    }

    public func fetchMuted() async throws -> [SafetyRelation] {
        record("fetchMuted")
        try await delay()
        try failIfOffline()
        try failIfSuspended()
        return relations(for: muted)
    }

    // MARK: - Reporting

    public func submitReport(_ request: ReportRequest) async throws -> ReportReceipt {
        receivedReports.append(request)
        record("submitReport:\(request.reason.rawValue)")
        try await delay()
        try failIfOffline()
        try failIfSuspended()
        try failIfRateLimited()

        if let handle = request.userHandle {
            let key = Handle.normalised(handle)
            try checkNotSelf(key, code: .selfReport, message: "You cannot report yourself")
            _ = try person(key)
        }

        let receipt = ReportReceipt(
            id: "rpt_\(String(format: "%04d", reports.count + 1))",
            status: "open",
            // The server attaches resources when the reason is about somebody's
            // safety rather than about content coming down.
            support: request.reason.isCareFirst ? Self.supportResources : nil
        )
        reports.append(
            Report(
                id: receipt.id,
                status: "open",
                reason: request.reason,
                createdAt: Date(),
                postId: request.postId,
                userHandle: request.userHandle
            )
        )
        return receipt
    }

    public func fetchReports() async throws -> [Report] {
        record("fetchReports")
        try await delay()
        try failIfOffline()
        try failIfSuspended()
        return reports.reversed()
    }

    // MARK: - Suspension

    /// Deliberately **not** gated on suspension: this is one of the two
    /// endpoints a suspended account may call, and the whole screen depends on
    /// it answering.
    public func fetchSuspension() async throws -> Suspension {
        record("fetchSuspension")
        try await delay()
        try failIfOffline()
        guard isSuspendedScenario else { return Suspension(suspended: false) }
        return Suspension(
            suspended: true,
            reason: Self.suspensionReason,
            until: scenario == .suspendedIndefinite
                ? nil
                : Date().addingTimeInterval(6 * 86_400),
            appeal: appeal
        )
    }

    /// The other endpoint that survives a suspension.
    public func submitAppeal(message: String) async throws -> SuspensionAppeal {
        receivedAppeals.append(message)
        record("submitAppeal")
        try await delay()
        try failIfOffline()

        guard appeal == nil else {
            throw APIError.api(
                code: .alreadyAppealed,
                message: "You have already appealed this suspension",
                status: 409
            )
        }
        let submitted = SuspensionAppeal(submittedAt: Date(), status: .pending)
        appeal = submitted
        return submitted
    }

    // MARK: - Fixture world

    /// The reason the mock's suspension carries. Written the way a real one
    /// would be: specific enough to answer, not a category name.
    public static let suspensionReason =
        "Repeated replies to the same account after being asked to stop. Reviewed by a "
            + "moderator on 26 August."

    /// The `support` object a `self_harm` report comes back with.
    ///
    /// The numbers here are the ones the **server** would supply. The client
    /// never invents a helpline — see ``SafetyCopy/supportFallbackMessage``.
    public static let supportResources = SupportResources(
        title: "Help is available",
        message: "You did the right thing by telling us. A reviewer is looking at this "
            + "now, and these people can help in the meantime — including if the person "
            + "you are worried about is you.",
        resources: [
            SupportResource(
                name: "Saudi National Centre for Mental Health",
                detail: "Arabic and English, free, 24 hours",
                phone: "920033360"
            ),
            SupportResource(
                name: "Befrienders Worldwide",
                detail: "Find a helpline in your own country",
                url: URL(string: "https://befrienders.org")
            ),
            SupportResource(
                name: "Emergency services",
                detail: "If someone is in immediate danger, call your local emergency number now."
            )
        ]
    )

    /// Two reports already on file, so the receipts list has something to show.
    static let existingReports: [Report] = [
        Report(
            id: "rpt_0001",
            status: "reviewed",
            reason: .spam,
            createdAt: Date().addingTimeInterval(-9 * 86_400),
            userHandle: "newcomer"
        ),
        Report(
            id: "rpt_0002",
            status: "open",
            reason: .harassment,
            createdAt: Date().addingTimeInterval(-2 * 86_400),
            postId: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")
        )
    ]

    /// The people a handle can resolve to — ``FeedServiceMock``'s cast.
    static var people: [UserSummary] { ProfileServiceMock.people }

    // MARK: - Internals

    private var isSuspendedScenario: Bool {
        scenario == .suspended || scenario == .suspendedIndefinite || scenario == .suspendedAppealed
    }

    private func relations(for handles: Set<String>) -> [SafetyRelation] {
        Self.people
            .filter { handles.contains($0.handle) }
            .map { SafetyRelation(user: $0, createdAt: Date().addingTimeInterval(-3 * 86_400)) }
    }

    private func person(_ handle: String) throws -> UserSummary {
        guard let match = Self.people.first(where: { $0.handle == handle }) else {
            throw APIError.api(
                code: .userNotFound,
                message: "No account with that handle",
                status: 404
            )
        }
        return match
    }

    private func checkNotSelf(_ handle: String, code: APIErrorCode, message: String) throws {
        guard handle == Self.viewerHandle else { return }
        throw APIError.api(code: code, message: message, status: 400)
    }

    private func record(_ call: String) {
        recordedCalls.append(call)
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }

    /// Reproduces `get_current_user` for a suspended account: refused
    /// everywhere, with a 403 carrying a code the client is expected to act on
    /// rather than display.
    private func failIfSuspended() throws {
        if isSuspendedScenario {
            throw APIError.api(
                code: .accountSuspended,
                message: "This account is suspended.",
                status: 403
            )
        }
    }

    private func failIfRateLimited() throws {
        if scenario == .rateLimited {
            throw APIError.api(
                code: .rateLimited,
                message: "Too many requests",
                status: 429
            )
        }
    }
}
