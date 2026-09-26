import Foundation
import Observation

/// A vouch link somebody opened, held until they can act on it.
///
/// A link usually arrives before its person has an account: they tap it,
/// sign up, leave for their email to read the code, and come back — maybe
/// after the system has closed the app. So the link is kept on the device
/// (the token only: it names nobody) until it is claimed, let go, or old
/// enough that it could no longer work (72 hours).
///
/// **Parked** is the one moment the landing steps aside: a signed-out person
/// chose "Create an account" or "Sign in", and the forms need the screen.
/// The landing comes back, as the claim form, once they are signed in.
@MainActor
@Observable
public final class VouchInviteInbox {

    public private(set) var pending: PendingVouchInvite?
    public private(set) var isParked = false

    private let storage: StorageClient
    static let storageKey = StorageKey("com.socialsa.sila.pendingVouchInvite")

    public init(storage: StorageClient) {
        self.storage = storage
        if let kept = storage.value(for: Self.storageKey, as: PendingVouchInvite.self) {
            if kept.isStale() {
                storage.remove(Self.storageKey)
            } else {
                pending = kept
            }
        }
    }

    /// A link was tapped. The newest one wins; the landing shows at once.
    public func receive(token: String) {
        let invite = PendingVouchInvite(token: token)
        pending = invite
        isParked = false
        storage.set(invite, for: Self.storageKey)
    }

    /// The landing steps aside for the sign-up or sign-in forms.
    public func park() {
        isParked = true
    }

    /// Signed in: the landing may show again, as the form.
    public func unpark() {
        isParked = false
    }

    /// Claimed: nothing to come back to after a relaunch, though the screen
    /// that says so stays up until it is closed.
    public func settle() {
        storage.remove(Self.storageKey)
    }

    /// Let go — closed, or the account signed out.
    public func forget() {
        pending = nil
        isParked = false
        storage.remove(Self.storageKey)
    }
}
