import Foundation
import Observation

/// A relationship that just changed, so the screen holding the person's content
/// can react to it.
public enum SafetyChange: Equatable, Sendable {
    case blocked(SafetyTarget)
    case unblocked(SafetyTarget)
    case muted(SafetyTarget)
    case unmuted(SafetyTarget)

    /// Who it was about.
    public var target: SafetyTarget {
        switch self {
        case let .blocked(target), let .unblocked(target),
             let .muted(target), let .unmuted(target):
            return target
        }
    }

    /// `true` when the person's content must leave the screen now.
    ///
    /// Only a block. A mute takes somebody out of the *feeds*; it does not
    /// pretend they stopped existing, and clearing a profile somebody
    /// deliberately opened would be the app overriding a decision the user just
    /// made.
    public var removesContent: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// Everything a `…` menu needs to draw itself, for one person.
///
/// A value rather than a pile of closures on the card's action set, so the menu
/// is built once and rendered identically wherever it appears — the post card
/// and the profile header must not drift into offering different verbs for the
/// same person.
public struct SafetyMenuActions {

    /// Who the menu is about.
    public let target: SafetyTarget
    /// Whether the viewer has already blocked them.
    public let isBlocked: Bool
    /// Whether the viewer has already muted them.
    public let isMuted: Bool
    /// `true` while a write for this person is in flight.
    public let isBusy: Bool
    /// Opens the block confirmation. **Never blocks.**
    public let onBlock: @MainActor () -> Void
    /// Lifts a block. No confirmation — undoing is not the destructive half.
    public let onUnblock: @MainActor () -> Void
    /// Mutes, in one tap.
    public let onMute: @MainActor () -> Void
    /// Unmutes, in one tap.
    public let onUnmute: @MainActor () -> Void
    /// Opens the reason picker.
    public let onReport: @MainActor () -> Void

    public init(
        target: SafetyTarget,
        isBlocked: Bool,
        isMuted: Bool,
        isBusy: Bool,
        onBlock: @escaping @MainActor () -> Void,
        onUnblock: @escaping @MainActor () -> Void,
        onMute: @escaping @MainActor () -> Void,
        onUnmute: @escaping @MainActor () -> Void,
        onReport: @escaping @MainActor () -> Void
    ) {
        self.target = target
        self.isBlocked = isBlocked
        self.isMuted = isMuted
        self.isBusy = isBusy
        self.onBlock = onBlock
        self.onUnblock = onUnblock
        self.onMute = onMute
        self.onUnmute = onUnmute
        self.onReport = onReport
    }
}

/// Drives every block, mute and report in the app.
///
/// One instance lives above the tab bar, which is what makes the three actions
/// behave identically wherever they are started from and lets a block taken on a
/// post card immediately correct the menu on that author's profile.
///
/// Three rules shape it, and they are the reason the three actions do not share
/// a code path:
///
/// **A block is confirmed, always.** There is deliberately no public method that
/// blocks. ``requestBlock(_:origin:)`` only puts the consequences on screen;
/// ``confirmBlock()`` is the only thing that calls the endpoint, and it does
/// nothing unless a confirmation is open. Nobody can weaken that by editing a
/// `.disabled(…)` modifier, because there is no button to weaken.
///
/// **A mute is one tap, and it is silent.** No dialog, no undo prompt, and every
/// message about it says the other person is not told — because the thing that
/// stops people using a mute is a suspicion that it might be announced.
///
/// **`403 account_suspended` is never an error string.** Every catch block ends
/// at ``SuspensionMonitor``, exactly as ``AccountViewModel``'s ends at
/// `handledDeactivation`.
@MainActor
@Observable
public final class SafetyViewModel {

    // MARK: - Presentation

    /// The block confirmation currently on screen, or `nil`.
    ///
    /// Settable so a dialog binding can clear it. Assigning one directly does
    /// **not** block anything — it only opens the dialog.
    public var pendingBlock: BlockConfirmation?

    /// The report sheet currently on screen, or `nil`.
    public var presentedReport: ReportSubject?

    /// Banner message.
    public var toast: SLToastMessage?

    // MARK: - What the viewer has already done

    /// Handles the viewer has blocked, as far as this client knows.
    public private(set) var blockedHandles: Set<String> = []

    /// Handles the viewer has muted.
    public private(set) var mutedHandles: Set<String> = []

    /// Handles with a write in flight, so a menu can show it and a second tap
    /// cannot double-send.
    public private(set) var busyHandles: Set<String> = []

    /// `true` once the two lists have been read at least once.
    ///
    /// Until then the menus say "Block" and "Mute" rather than the opposite,
    /// which is the safe direction to be wrong in: offering to block somebody
    /// already blocked is idempotent and harmless, and offering to *unblock*
    /// somebody who is not blocked would be a lie about the current state.
    public private(set) var hasLoadedRelationships = false

    // MARK: - Collaborators

    private let service: SafetyServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let viewerHandle: String?
    private let onChange: (@MainActor (SafetyChange) -> Void)?

    /// - Parameters:
    ///   - service: Safety backend.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes. `nil` in tests that
    ///     are not about routing.
    ///   - viewerHandle: The signed-in account's handle, so the menu is absent
    ///     on the viewer's own posts rather than offering three verbs the server
    ///     answers `self_block`, `self_mute` and `self_report` to.
    ///   - onChange: Told after every accepted write, so the screen holding the
    ///     person's content can remove it without waiting for a refresh.
    public init(
        service: SafetyServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        viewerHandle: String? = nil,
        onChange: (@MainActor (SafetyChange) -> Void)? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
        self.viewerHandle = viewerHandle.map(Handle.normalised)
        self.onChange = onChange
    }

    // MARK: - Derived state

    /// Whether the safety menu belongs on screen for this handle at all.
    ///
    /// Absent on your own content rather than disabled: the server answers
    /// `self_block` / `self_mute` / `self_report`, so a greyed-out menu would be
    /// an affordance for three things that cannot happen.
    public func canAct(on handle: String) -> Bool {
        let normalised = Handle.normalised(handle)
        guard !normalised.isEmpty else { return false }
        guard let viewerHandle, !viewerHandle.isEmpty else { return true }
        return normalised != viewerHandle
    }

    /// Whether the viewer has blocked this handle, as far as this client knows.
    public func isBlocked(_ handle: String) -> Bool {
        blockedHandles.contains(Handle.normalised(handle))
    }

    /// Whether the viewer has muted this handle.
    public func isMuted(_ handle: String) -> Bool {
        mutedHandles.contains(Handle.normalised(handle))
    }

    /// Whether a write is in flight for this handle.
    public func isBusy(_ handle: String) -> Bool {
        busyHandles.contains(Handle.normalised(handle))
    }

    // MARK: - Menus

    /// The menu for one person, or `nil` when there should not be one.
    /// - Parameters:
    ///   - target: Who.
    ///   - subject: What a report would be about — the post, or the account.
    ///   - origin: Where the block would have been started from.
    public func menu(
        for target: SafetyTarget,
        reporting subject: ReportSubject,
        origin: BlockConfirmation.Origin
    ) -> SafetyMenuActions? {
        guard canAct(on: target.handle), target.isAddressable else { return nil }
        return SafetyMenuActions(
            target: target,
            isBlocked: isBlocked(target.handle),
            isMuted: isMuted(target.handle),
            isBusy: isBusy(target.handle),
            onBlock: { [weak self] in self?.requestBlock(target, origin: origin) },
            onUnblock: { [weak self] in Task { await self?.setBlocked(false, target: target) } },
            onMute: { [weak self] in Task { await self?.setMuted(true, target: target) } },
            onUnmute: { [weak self] in Task { await self?.setMuted(false, target: target) } },
            onReport: { [weak self] in self?.openReport(subject) }
        )
    }

    /// The menu for a post, reporting the post itself.
    public func menu(for post: Post) -> SafetyMenuActions? {
        menu(
            for: SafetyTarget(user: post.author),
            reporting: ReportSubject(post: post),
            origin: .post
        )
    }

    /// The menu for a profile header, reporting the account.
    ///
    /// Takes a target rather than a ``Profile`` because a blocked account 404s:
    /// on the one page where the Unblock control matters most, there is no
    /// profile object left to build a menu from.
    public func menu(for target: SafetyTarget) -> SafetyMenuActions? {
        menu(for: target, reporting: .account(target), origin: .profile)
    }

    /// The menu for a loaded profile.
    public func menu(for profile: Profile) -> SafetyMenuActions? {
        menu(for: SafetyTarget(profile: profile))
    }

    // MARK: - Blocking

    /// Puts the block confirmation on screen. **Blocks nothing.**
    ///
    /// The whole gate is that this and ``confirmBlock()`` are different methods:
    /// every entry point in the app calls this one, and the endpoint is only
    /// reachable from a dialog that has already stated what a block destroys.
    public func requestBlock(_ target: SafetyTarget, origin: BlockConfirmation.Origin = .post) {
        guard canAct(on: target.handle), target.isAddressable else { return }
        pendingBlock = BlockConfirmation(target: target, origin: origin)
        analytics.track(.blockConfirmationShown, properties: ["origin": origin.rawValue])
    }

    /// Dismisses the confirmation without blocking.
    public func cancelBlock() {
        guard pendingBlock != nil else { return }
        pendingBlock = nil
        analytics.track(.blockCancelled)
    }

    /// Performs the block the open confirmation describes.
    ///
    /// Does nothing when no confirmation is open, which is what makes the gate a
    /// property of the model rather than of whichever view happened to call it.
    public func confirmBlock() async {
        guard let confirmation = pendingBlock else { return }
        pendingBlock = nil
        await setBlocked(true, target: confirmation.target)
    }

    /// Writes a block state and adopts what the server says.
    ///
    /// Public for `false` only in spirit: unblocking needs no confirmation
    /// because it destroys nothing. Blocking arrives here through
    /// ``confirmBlock()``.
    public func setBlocked(_ blocked: Bool, target: SafetyTarget) async {
        guard canAct(on: target.handle), !isBusy(target.handle) else { return }
        busyHandles.insert(target.handle)
        defer { busyHandles.remove(target.handle) }

        do {
            let state = try await service.setBlocked(blocked, handle: target.handle)
            apply(blocked: state, target: target)
            if state {
                // A block already made them invisible; a mute underneath it is a
                // second row claiming to do something that is no longer doing
                // anything.
                mutedHandles.remove(target.handle)
                toast = .success(SafetyCopy.blocked(target))
                onChange?(.blocked(target))
            } else {
                toast = .info(SafetyCopy.unblocked(target))
                onChange?(.unblocked(target))
            }
        } catch {
            report(failure: error, action: blocked ? "block" : "unblock")
        }
    }

    // MARK: - Muting

    /// Mutes or unmutes. One tap, no confirmation, reversible.
    public func setMuted(_ muted: Bool, target: SafetyTarget) async {
        guard canAct(on: target.handle), !isBusy(target.handle) else { return }
        busyHandles.insert(target.handle)
        defer { busyHandles.remove(target.handle) }

        do {
            let state = try await service.setMuted(muted, handle: target.handle)
            apply(muted: state, target: target)
            // Both messages say it out loud. Somebody who suspects a mute might
            // be announced will simply not use one, and then they are stuck with
            // a feed they cannot bear and a block they did not want.
            toast = .success(state ? SafetyCopy.muted(target) : SafetyCopy.unmuted(target))
            onChange?(state ? .muted(target) : .unmuted(target))
        } catch {
            report(failure: error, action: muted ? "mute" : "unmute")
        }
    }

    // MARK: - Reporting

    /// Opens the reason picker.
    public func openReport(_ subject: ReportSubject) {
        presentedReport = subject
        analytics.track(.reportOpened, properties: [
            "subject": subject.postId == nil ? "user" : "post"
        ])
    }

    /// Closes the report sheet.
    public func closeReport() {
        presentedReport = nil
    }

    /// Builds the view model for a presented report sheet.
    ///
    /// Fresh each time so a sheet never opens holding the last report's text —
    /// and so the block and mute offered *after* a report route back through the
    /// same gates as everywhere else.
    public func reportViewModel(for subject: ReportSubject) -> ReportViewModel {
        ReportViewModel(
            subject: subject,
            service: service,
            analytics: analytics,
            suspension: suspension,
            onClose: { [weak self] in self?.closeReport() },
            onBlock: { [weak self] target in
                self?.closeReport()
                self?.requestBlock(target, origin: .list)
            },
            onMute: { [weak self] target in
                Task { await self?.setMuted(true, target: target) }
            }
        )
    }

    // MARK: - Loading what is already true

    /// Reads the blocked and muted lists so the menus say the right verb.
    ///
    /// Failures are swallowed on purpose. These two lists are a *label*
    /// optimisation; a network problem while fetching them must not put an error
    /// banner in front of somebody who has not asked for anything, and the
    /// fallback — "Block" and "Mute" on an already-blocked account — is
    /// idempotent and harmless.
    public func loadRelationships() async {
        guard !hasLoadedRelationships else { return }
        await reloadRelationships()
    }

    /// Reads them unconditionally.
    public func reloadRelationships() async {
        async let blocks = service.fetchBlocked()
        async let mutes = service.fetchMuted()

        if let rows = try? await blocks {
            blockedHandles = Set(rows.map { Handle.normalised($0.user.handle) })
            hasLoadedRelationships = true
        }
        if let rows = try? await mutes {
            mutedHandles = Set(rows.map { Handle.normalised($0.user.handle) })
            hasLoadedRelationships = true
        }
    }

    /// Adopts a change made somewhere else — the safety lists screen, say — so
    /// the menus everywhere agree with it without a round trip.
    public func adopt(_ change: SafetyChange) {
        switch change {
        case let .blocked(target):
            apply(blocked: true, target: target)
            mutedHandles.remove(target.handle)
        case let .unblocked(target):
            apply(blocked: false, target: target)
        case let .muted(target):
            apply(muted: true, target: target)
        case let .unmuted(target):
            apply(muted: false, target: target)
        }
    }

    // MARK: - Plumbing

    private func apply(blocked: Bool, target: SafetyTarget) {
        if blocked {
            blockedHandles.insert(target.handle)
        } else {
            blockedHandles.remove(target.handle)
        }
    }

    private func apply(muted: Bool, target: SafetyTarget) {
        if muted {
            mutedHandles.insert(target.handle)
        } else {
            mutedHandles.remove(target.handle)
        }
    }

    /// Reports a failed write — unless it was a suspension, which is a route.
    private func report(failure error: Error, action: String) {
        if suspension?.notice(error) == true { return }
        let wrapped = APIError.wrapping(error)
        analytics.track(.safetyActionFailed, properties: [
            "action": action,
            "code": wrapped.code?.rawValue ?? "transport"
        ])
        toast = .error(wrapped.userMessage)
    }
}
