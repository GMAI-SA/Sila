import Foundation
import Observation

/// Drives ``VouchingScreen`` — the voucher's own list (contract v24 §5).
///
/// Everybody they stand behind: claims waiting for "that's who I meant",
/// live vouches, a moderator's question to answer, open links, and the
/// ones that ended; and whether they may vouch now, and why not.
@MainActor
@Observable
public final class VouchingViewModel {

    public enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: LoadState = .loading
    public private(set) var overview: VouchingOverview?
    /// Vouches and links with a request in flight.
    public private(set) var busy: Set<UUID> = []
    /// The row whose in-place question is open, and which question.
    public var confirming: (id: UUID, action: RowAction)?
    /// The written answer to a finding, per vouch, while it is typed.
    public var statements: [UUID: String] = [:]
    public var toast: SLToastMessage?
    public var isMinting = false

    /// A row's action that asks first.
    public enum RowAction: Equatable {
        case confirm, decline, withdraw, burn
    }

    private let service: VouchingServiceProtocol
    private let onChange: (@MainActor (VouchingOverview) -> Void)?

    /// - Parameter onChange: Told every time the list is re-read, so the
    ///   Profile entry's line (and whether it is drawn) stays true.
    public init(service: VouchingServiceProtocol, onChange: (@MainActor (VouchingOverview) -> Void)? = nil) {
        self.service = service
        self.onChange = onChange
    }

    // MARK: - Derived

    /// The flag is off for this account: the screen says "soon" and offers
    /// nothing (contract v24 release order).
    public var isOpen: Bool { overview?.isOpen ?? true }

    /// Why not, in the reader's language.
    public var refusalText: String? {
        guard let overview, !overview.canVouch, let reason = overview.reason else { return nil }
        return VouchCopy.refusal(reason, in: overview)
    }

    /// The right to vouch has ended — one strike is enough.
    public var privilegeLost: Bool { overview.map { !$0.privilege.active } ?? false }

    public var isEmpty: Bool {
        guard let overview else { return true }
        return overview.vouches.isEmpty && overview.ended.isEmpty && overview.invites.isEmpty
    }

    public func isConfirming(_ id: UUID, _ action: RowAction) -> Bool {
        confirming?.id == id && confirming?.action == action
    }

    // MARK: - Loading

    public func load() async {
        if overview == nil { state = .loading }
        do {
            let fresh = try await service.overview()
            overview = fresh
            state = .loaded
            onChange?(fresh)
        } catch let error as APIError {
            guard !error.isCancellation else { return }
            if overview == nil { state = .failed(error.userMessage) } else { toast = .error(error.userMessage) }
        } catch {
            if overview == nil { state = .failed(L10n.t("common.somethingWentWrong")) }
        }
    }

    /// A link was just minted: the list shows it, and the entry's line moves.
    public func minted() async {
        await load()
    }

    // MARK: - The voucher's answers

    public func confirm(_ vouch: Vouch) async {
        await act(vouch.id, success: L10n.t("vouch.list.confirmed", vouch.vouchee?.handle ?? vouch.voucheeHandle)) {
            _ = try await self.service.confirm(vouchId: vouch.id)
        }
    }

    public func decline(_ vouch: Vouch) async {
        await act(vouch.id, success: L10n.t("vouch.list.declined")) {
            _ = try await self.service.decline(vouchId: vouch.id)
        }
    }

    public func withdraw(_ vouch: Vouch) async {
        await act(vouch.id, success: L10n.t("vouch.list.withdrawn")) {
            _ = try await self.service.withdraw(vouchId: vouch.id)
        }
    }

    public func burn(_ invite: VouchInvite) async {
        await act(invite.id, success: L10n.t("vouch.list.invite.burned")) {
            try await self.service.burnInvite(id: invite.id)
        }
    }

    /// The server's bounds on the written answer, in code points — the way
    /// it counts them.
    public static let statementMinimum = 10
    public static let statementLimit = 1_000

    /// The written answer to a moderator's finding: 10 to 1,000 characters.
    /// Kept in the box unless the server took it — an answer that failed to
    /// send is not one the voucher should have to write again inside the
    /// 48 hours.
    public func answer(_ vouch: Vouch, _ action: VouchAnswer) async {
        let statement = (statements[vouch.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard statement.serverLength >= Self.statementMinimum else {
            toast = .warning(L10n.t("vouch.summons.tooShort"))
            return
        }
        let sent = await act(vouch.id, success: L10n.t("vouch.summons.sent")) {
            _ = try await self.service.answer(vouchId: vouch.id, action: action,
                                              statement: statement.clamped(toServerLength: Self.statementLimit))
        }
        if sent { statements[vouch.id] = nil }
    }

    /// One request per row at a time; the list is re-read afterwards, so
    /// what shows is the server's answer, not a guess at it.
    /// - Returns: Whether the server took the request.
    @discardableResult
    private func act(_ id: UUID, success: String, _ request: @escaping () async throws -> Void) async -> Bool {
        guard !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }
        var succeeded = false
        do {
            try await request()
            succeeded = true
            confirming = nil
            toast = .success(success)
        } catch let error as APIError {
            guard !error.isCancellation else { return false }
            confirming = nil
            toast = .error(error.userMessage)
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
        }
        await load()
        return succeeded
    }
}
