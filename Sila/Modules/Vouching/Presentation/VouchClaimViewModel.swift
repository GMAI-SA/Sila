import Foundation
import Observation

/// Drives ``VouchClaimScreen`` — a vouch link, opened.
///
/// Reads the landing (who is vouching, until when), and — for somebody
/// signed in — takes their own full name, nationality and date of birth
/// and the four promises, and claims. A mismatch names *which* fields
/// differ and never what the voucher wrote; the form keeps what the person
/// typed, marks those fields, and says how many tries the link has left.
/// The third closes the link for good.
@MainActor
@Observable
public final class VouchClaimViewModel {

    /// Where the claim stands.
    public enum Phase: Equatable {
        case loading
        /// The link works: the form (or, signed out, the way to join).
        case open(VouchInviteLanding)
        /// One state for every link that cannot be used — unknown, used,
        /// expired, burned, a voucher who can no longer vouch. Only the
        /// server's own answer lands here (`404 invite_unavailable`).
        case unavailable
        /// The landing could not be read at all — offline, a timeout, a
        /// server error. Not an answer about the link, so never "ask for a
        /// new one": the way on is to try again.
        case failed(String)
        /// Three tries did not match; the link is closed for good.
        case closed
        /// Accepted: now the voucher confirms it is them.
        case claimed(VouchState?)
        /// The server will not take this account's claim at all — already
        /// verified, already vouched for, too soon, twice already, not
        /// eligible, under age. The sentence says which.
        case refused(String)
    }

    public private(set) var phase: Phase = .loading
    public var draft = VouchDetailsDraft()
    public var adult = false
    public var realName = false
    public var singleAccount = false
    public var terms = false
    /// The fields the last try did not match, in the server's order.
    public private(set) var mismatched: [VouchDetailField] = []
    public private(set) var attemptsLeft: Int?
    /// Counts the mismatches this screen has shown, so each one can be
    /// announced — the banner appears above the fields, away from the
    /// button VoiceOver is on.
    public private(set) var mismatchSerial = 0
    /// A detail the server refused as impossible (not a mismatch).
    public private(set) var fieldErrors: [VouchDetailField: String] = [:]
    public private(set) var isSubmitting = false
    public var errorMessage: String?
    /// The two plain warnings were read and accepted (contract v24 §12):
    /// shown before the details form every time the link is opened.
    public var hasAcknowledgedWarnings = false

    public let token: String
    /// `false` for a guest or somebody on the welcome screen: they read the
    /// landing and are asked to join first; the link waits for them.
    public let isSignedIn: Bool
    /// Where the signed-in account stands. A verified or vouched one is told
    /// at once that the link is not for it, rather than after the form.
    private let standing: Standing
    /// A claim this account already made and its voucher has not answered:
    /// one live vouch at a time (`409 already_vouched`), said before the
    /// warnings and the form rather than after them.
    private let pendingClaim: VouchState?
    private let service: VouchingServiceProtocol
    private let onClaimed: @MainActor (VouchState?) async -> Void

    public init(
        token: String,
        isSignedIn: Bool,
        standing: Standing = .noStanding,
        pendingClaim: VouchState? = nil,
        service: VouchingServiceProtocol,
        onClaimed: @escaping @MainActor (VouchState?) async -> Void
    ) {
        self.token = token
        self.isSignedIn = isSignedIn
        self.standing = isSignedIn ? standing : .noStanding
        self.pendingClaim = isSignedIn ? pendingClaim : nil
        self.service = service
        self.onClaimed = onClaimed
    }

    /// The voucher, once the landing has been read.
    public var voucher: UserSummary? {
        if case let .open(landing) = phase { return landing.voucher }
        return nil
    }

    /// All four promises made.
    public var hasAttested: Bool { adult && realName && singleAccount && terms }

    /// Everything filled in, every box ticked, nothing in flight.
    public var canSubmit: Bool {
        isSignedIn && hasAcknowledgedWarnings && draft.details != nil && hasAttested && !isSubmitting && voucher != nil
    }

    /// "These don't match what @noura entered: name, date of birth".
    public var mismatchText: String? {
        guard !mismatched.isEmpty, let voucher else { return nil }
        return VouchCopy.mismatch(voucher: voucher.handle, fields: mismatched)
    }

    // MARK: - Loading

    public func load() async {
        // The server would say the same at the claim (`409 already_verified`
        // / `already_vouched`); nothing is asked of it that it would refuse.
        switch standing {
        case .verified:
            phase = .refused(L10n.t("vouch.claim.member.verified"))
            return
        case .vouched:
            phase = .refused(L10n.t("vouch.error.alreadyVouched"))
            return
        case .noStanding:
            break
        }
        if let pendingClaim {
            phase = .refused(L10n.t("vouch.claim.member.pending", pendingClaim.voucher?.handle ?? pendingClaim.voucherHandle))
            return
        }
        phase = .loading
        do {
            phase = .open(try await service.landing(token: token))
        } catch let error as APIError where error.isCancellation {
            return
        } catch {
            // The server's one answer for every link that cannot be used is
            // one state, so a token cannot be probed. Anything else — no
            // connection, a timeout, a server error — said nothing about the
            // link, and must not send the voucher off to burn a good one.
            phase = Self.isUnusableLink(error) ? .unavailable : .failed(APIError.wrapping(error).userMessage)
        }
    }

    /// `404 invite_unavailable` (or a bare 404 from the same route).
    nonisolated static func isUnusableLink(_ error: Error) -> Bool {
        switch APIError.wrapping(error) {
        case let .api(code, _, status): return code == .inviteUnavailable || status == 404
        case let .http(status, _): return status == 404
        default: return false
        }
    }

    // MARK: - Claiming

    public func submit() async {
        errorMessage = nil
        guard isSignedIn, hasAcknowledgedWarnings, voucher != nil else { return }
        guard let details = draft.details else {
            errorMessage = L10n.t("vouch.error.detailsRequired.own")
            return
        }
        guard hasAttested else {
            errorMessage = L10n.t("vouch.error.attestationsRequired.own")
            return
        }
        if draft.isUnderAge() {
            // Said here rather than spent as a try: nobody under 18 can be
            // vouched for, and the server does not count it as a mismatch.
            fieldErrors = [.dateOfBirth: L10n.t("vouch.error.underAge.own")]
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let vouch = try await service.claim(token: token, details: details)
            mismatched = []
            fieldErrors = [:]
            phase = .claimed(vouch)
            await onClaimed(vouch)
        } catch APIError.detailsMismatch(let fields, let left, _) {
            mismatched = VouchDetailField.parse(fields)
            attemptsLeft = left
            fieldErrors = [:]
            mismatchSerial += 1
        } catch let error as APIError {
            apply(error)
        } catch {
            errorMessage = L10n.t("common.somethingWentWrong")
        }
    }

    private func apply(_ error: APIError) {
        guard !error.isCancellation else { return }
        mismatched = []
        switch error.code {
        case .inviteClosed:
            phase = .closed
        case .inviteUnavailable:
            phase = .unavailable
        case .detailsRequired:
            errorMessage = L10n.t("vouch.error.detailsRequired.own")
        case .invalidFullName:
            fieldErrors = [.fullName: L10n.t("vouch.error.invalidFullName.own")]
        case .invalidCountry:
            fieldErrors = [.nationality: L10n.t("vouch.error.invalidCountry")]
        case .invalidDateOfBirth:
            fieldErrors = [.dateOfBirth: L10n.t("vouch.error.invalidDateOfBirth")]
        case .attestationsRequired:
            errorMessage = L10n.t("vouch.error.attestationsRequired.own")
        case .vouchUnderAge:
            phase = .refused(L10n.t("vouch.error.underAge.own"))
        case .alreadyVerified:
            phase = .refused(L10n.t("vouch.claim.member.verified"))
        case .alreadyVouched, .vouchTooSoon, .vouchLifetimeReached, .vouchNotEligible:
            phase = .refused(error.userMessage)
        case .signInRequired, .unauthorized:
            errorMessage = L10n.t("vouch.error.signInRequired")
        default:
            errorMessage = error.userMessage
        }
    }
}
