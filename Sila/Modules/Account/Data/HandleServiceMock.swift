import Foundation

/// Scripted ``HandleServiceProtocol`` for tests, previews and mocked runs.
///
/// It keeps the server's rules rather than saying yes to everything, because
/// the chooser is all refusals: `taken`, `noura` and `aziz_sa` are taken,
/// `admin`, `sila`, `moh` and `absher` are reserved, and anything that is not
/// 3–20 characters of `a–z`, `0–9` and `_` is invalid. A taken answer comes
/// with fresh suggestions, as the server's does.
public actor HandleServiceMock: HandleServiceProtocol {

    /// Handles another account holds.
    public static let takenHandles: Set<String> = ["taken", "noura", "aziz_sa"]
    /// Handles nobody may take.
    public static let reservedHandles: Set<String> = ["admin", "sila", "moh", "absher"]
    /// What an empty check suggests: free, never the random shape.
    public static let suggestions = ["aziz_alwakeel", "azizalwakeel", "aziz482"]

    /// The account the answer describes: the session's own, so a mocked
    /// choice changes nothing about the account but its handle.
    private let account: @Sendable () async -> AuthUser?
    /// Told about every handle taken, so a mocked `/auth/me` agrees.
    private let onChosen: @Sendable (AuthUser) async -> Void
    private let latency: Double
    private var offline: Bool

    /// Handles checked, in order — the assertion surface for tests.
    public private(set) var checked: [String] = []
    /// Handles taken, in order.
    public private(set) var chosen: [String] = []
    /// What the next `choose` throws instead of answering, once.
    private var nextChooseError: APIError?

    public init(
        latency: Double = 0,
        offline: Bool = false,
        account: @escaping @Sendable () async -> AuthUser? = { nil },
        onChosen: @escaping @Sendable (AuthUser) async -> Void = { _ in }
    ) {
        self.latency = latency
        self.offline = offline
        self.account = account
        self.onChosen = onChosen
    }

    /// Makes the next `choose` fail — somebody took the handle a moment
    /// earlier, say.
    public func failNextChoose(with error: APIError) {
        nextChooseError = error
    }

    public func setOffline(_ value: Bool) {
        offline = value
    }

    public func check(_ handle: String) async throws -> HandleCheck {
        let wanted = Handle.normalised(handle)
        checked.append(wanted)
        try await delay()
        try failIfOffline()
        let own = await account()?.handle
        let fresh = Self.suggestions.filter { $0 != wanted && $0 != own }
        if wanted.isEmpty || !Handle.isValid(wanted) {
            return HandleCheck(handle: wanted, available: false, reason: .invalid, suggestions: fresh)
        }
        if wanted == own {
            return HandleCheck(handle: wanted, available: true, suggestions: fresh)
        }
        if Self.reservedHandles.contains(wanted) {
            return HandleCheck(handle: wanted, available: false, reason: .reserved, suggestions: fresh)
        }
        if Self.takenHandles.contains(wanted) {
            return HandleCheck(handle: wanted, available: false, reason: .taken, suggestions: fresh)
        }
        return HandleCheck(handle: wanted, available: true, suggestions: fresh)
    }

    public func choose(_ handle: String) async throws -> AuthUser {
        let wanted = Handle.normalised(handle)
        chosen.append(wanted)
        try await delay()
        try failIfOffline()
        if let error = nextChooseError {
            nextChooseError = nil
            throw error
        }
        let current = await account()
        guard Handle.isValid(wanted) else {
            throw APIError.api(code: .invalidHandle, message: "Handles are 3–20 characters of a–z, 0–9 and underscore", status: 400)
        }
        if wanted != current?.handle {
            if Self.reservedHandles.contains(wanted) {
                throw APIError.api(code: .handleReserved, message: "That handle is reserved", status: 409)
            }
            if Self.takenHandles.contains(wanted) {
                throw APIError.api(code: .handleTaken, message: "That handle is already taken", status: 409)
            }
        }
        guard let current else { throw APIError.unauthenticated }
        var updated = AuthUser(
            id: current.id, email: current.email, displayName: current.displayName,
            emailVerified: current.emailVerified, verificationStatus: current.verificationStatus,
            createdAt: current.createdAt, handle: wanted, countryCode: current.countryCode,
            avatarURL: current.avatarURL, phone: current.phone, verifiedName: current.verifiedName,
            hideVerifiedName: current.hideVerifiedName, needsInterestPrompt: current.needsInterestPrompt,
            experimentBucket: current.experimentBucket
        )
        updated.guidelinesVersion = current.guidelinesVersion
        updated.currentGuidelinesVersion = current.currentGuidelinesVersion
        updated.standing = current.standing
        updated.vouch = current.vouch
        updated.features = current.features
        updated.handleChosen = true
        await onChosen(updated)
        return updated
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }
}
