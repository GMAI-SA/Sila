import Foundation

// MARK: - Choosing a handle (contract v33)

/// Why a handle cannot be taken, as `GET /handles/check` says it.
///
/// The same three refusals `POST /me/handle` and `PATCH /me/profile` make:
/// checking first and taking afterwards can never disagree about the rules.
public enum HandleProblem: String, Equatable, Sendable {
    /// Not 3–20 characters of `a–z`, `0–9` and `_` (empty included).
    case invalid
    /// On the server's reserved list: platform and government names.
    case reserved
    /// Another account holds it, compared without case.
    case taken

    /// The one line the chooser shows, in the reader's language.
    public var message: String {
        switch self {
        case .invalid: return L10n.t("account.handle.reason.invalid")
        case .reserved: return L10n.t("account.handle.reason.reserved")
        case .taken: return L10n.t("account.handle.reason.taken")
        }
    }
}

/// `GET /handles/check` — whether this account could take a handle right
/// now, and up to three it could take instead.
public struct HandleCheck: Decodable, Equatable, Sendable {
    /// The handle as the server read it: trimmed, lower case, no `@`.
    public let handle: String
    public let available: Bool
    /// `nil` exactly when ``available``.
    public let reason: HandleProblem?
    /// Free right now, never reserved, never the random `user…` shape,
    /// never this account's own. Different on every call.
    public let suggestions: [String]

    public init(handle: String, available: Bool, reason: HandleProblem? = nil, suggestions: [String] = []) {
        self.handle = handle
        self.available = available
        self.reason = available ? nil : (reason ?? .taken)
        self.suggestions = suggestions
    }

    private enum CodingKeys: String, CodingKey {
        case handle, available, reason, suggestions
    }

    /// Tolerant: a reason this build does not know reads as "taken" — the
    /// handle is not to be had, which is all the chooser needs to say.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = (try? container.decode(String.self, forKey: .handle)) ?? ""
        available = (try? container.decode(Bool.self, forKey: .available)) ?? false
        let raw = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        reason = available ? nil : (raw.flatMap(HandleProblem.init(rawValue:)) ?? .taken)
        let listed = (try? container.decodeIfPresent([String].self, forKey: .suggestions)) ?? nil
        suggestions = (listed ?? []).filter(Handle.isValid)
    }
}

/// Asking whether a handle is free, and taking one (contract v33).
///
/// Both answer an account that has not verified yet: a handle is chosen right
/// after sign-up, before anything else.
public protocol HandleServiceProtocol: Sendable {

    /// `GET /handles/check?handle=` — `""` asks for suggestions alone.
    /// - Throws: ``APIErrorCode/rateLimited`` (429) after 120 checks in ten
    ///   minutes; the chooser waits a third of a second after typing, so a
    ///   person never comes near it.
    func check(_ handle: String) async throws -> HandleCheck

    /// `POST /me/handle` — takes `handle`, and answers the account exactly
    /// as `GET /auth/me` does, `handle_chosen` now `true`. Sending the handle
    /// the account already has keeps it, and counts as a choice.
    /// - Throws: ``APIErrorCode/invalidHandle`` (400),
    ///   ``APIErrorCode/handleReserved`` and ``APIErrorCode/handleTaken`` (409
    ///   — also when somebody took it a moment earlier),
    ///   ``APIErrorCode/rateLimited`` (429, ten changes an hour).
    func choose(_ handle: String) async throws -> AuthUser
}
