import Foundation
import Observation

/// Drives ``RoomInvitesSheet``.
///
/// The guest list is the server's, always: every call answers with the whole
/// list rather than a delta, and this adopts it. That is deliberate — a host
/// invites from one device and revokes from another, and a client that
/// patched its own copy would drift from the room people are actually
/// entering.
@MainActor
@Observable
public final class RoomInvitesViewModel {

    /// Everybody holding an invitation, oldest first.
    public private(set) var invited: [UserSummary] = []
    /// `true` while the list is being read.
    public private(set) var isLoading = false
    /// `true` while an invitation is being sent.
    public private(set) var isAdding = false
    /// Whose invitation is being withdrawn, while it is.
    public private(set) var revokingHandle: String?
    /// Handles typed into the add field, as typed.
    public var handlesText = ""
    /// Banner message.
    public var toast: SLToastMessage?

    private let roomId: UUID
    private let service: RoomsServiceProtocol
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - roomId: The closed room whose guests these are.
    ///   - service: Rooms backend.
    ///   - analytics: Event sink. Counts only — never a handle, because who a
    ///     host invited is the room's business and not telemetry's.
    /// Where a picker gets its people, when the screen offers one.
    public let people: PeopleDirectory?
    public let viewerHandle: String

    public init(
        roomId: UUID,
        service: RoomsServiceProtocol,
        analytics: AnalyticsClient,
        people: PeopleDirectory? = nil,
        viewerHandle: String = ""
    ) {
        self.roomId = roomId
        self.service = service
        self.analytics = analytics
        self.people = people
        self.viewerHandle = viewerHandle
    }

    /// Invites the people a picker chose. Same call as the typed field.
    public func invite(people chosen: [UserSummary]) async {
        let wanted = chosen.map(\.handle)
        guard !wanted.isEmpty, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        do {
            invited = try await service.invite(roomId: roomId, handles: wanted).invited
            toast = .success(L10n.plural("rooms.invites.added", wanted.count))
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// The handles the add field currently names, tidied.
    public var handles: [String] { RoomInviteHandles.clean(handlesText) }

    /// Whether the add button does anything.
    public var canAdd: Bool { !handles.isEmpty && !isAdding }

    /// Reads the guest list.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            invited = try await service.fetchInvites(roomId: roomId).invited
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Sends the invitations named in the field.
    ///
    /// The field is cleared only on success: a handle the server refused is
    /// one the host needs to see in order to correct it.
    public func add() async {
        let wanted = handles
        guard !wanted.isEmpty, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        do {
            invited = try await service.invite(roomId: roomId, handles: wanted).invited
            handlesText = ""
            toast = .success(L10n.plural("rooms.invites.added", wanted.count))
        } catch {
            let wrapped = APIError.wrapping(error)
            // `user_not_found` names the first handle nobody holds, and the
            // server wrote nothing — so the whole field stands, uncorrected.
            toast = .error(wrapped.userMessage)
        }
    }

    /// Withdraws one invitation.
    public func revoke(_ handle: String) async {
        guard revokingHandle == nil else { return }
        revokingHandle = handle
        defer { revokingHandle = nil }
        do {
            invited = try await service.revokeInvite(roomId: roomId, handle: handle).invited
            toast = .info(L10n.t("rooms.invites.revoked", handle))
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }
}
