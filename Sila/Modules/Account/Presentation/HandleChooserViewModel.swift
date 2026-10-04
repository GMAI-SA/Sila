import Foundation
import Observation

/// Drives ``HandleChooserScreen`` — "Choose your @handle" (contract v33).
///
/// A new account is given a random handle (`user` and eight characters) on
/// purpose: handles used to be made from the email or the phone number, and a
/// handle is on every post. This is the step that lets the person replace it,
/// right after sign-up and once more for an account that never chose, and the
/// sheet behind "Change" in account settings.
///
/// Three things shape it:
///
/// **What the field shows is what would be stored.** Spaces and a leading `@`
/// go as they are typed and letters are lowered, so nobody is surprised by
/// the handle they get.
///
/// **The rules the phone knows are said at once; the rest is asked.** Too
/// short, too long or a character outside `a–z 0–9 _` is "invalid" without a
/// request. Taken and reserved are the server's to say, a third of a second
/// after the typing stops — never once per keystroke.
///
/// **Nothing here blocks.** "Keep @user… for now" takes the handle the
/// account already has (so the step is not offered again), and if even that
/// fails the person goes on regardless; settings can change it later.
@MainActor
@Observable
public final class HandleChooserViewModel {

    /// Where the chooser was opened from.
    public enum Context: String, Sendable {
        /// Right after the account was created.
        case signUp = "signup"
        /// An older account that never chose, offered once.
        case existing
        /// "Change" beside the handle in account settings.
        case settings
    }

    /// What the line under the field says.
    public enum Status: Equatable, Sendable {
        /// Nothing typed.
        case idle
        /// Waiting for the server.
        case checking
        /// Free: Save takes it.
        case available
        /// The account's own handle.
        case current
        /// Not to be had, and why.
        case unavailable(HandleProblem)
        /// The server could not be asked — no connection, too many checks.
        case failed(String)
    }

    // MARK: Outputs

    /// The handle as it will be stored. Set through ``update(_:)``.
    public private(set) var text = ""
    public private(set) var status: Status = .idle
    /// Up to three handles the server says are free, as chips.
    public private(set) var suggestions: [String] = []
    /// The first read of suggestions is in flight.
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var isKeeping = false
    /// Why the last save did not go, when the reason is not about the
    /// handle itself (no connection, too many changes).
    public private(set) var saveError: String?

    /// The handle the account has now — the random one, or the one chosen
    /// before.
    public let currentHandle: String?
    public let context: Context

    private let service: HandleServiceProtocol
    private let analytics: AnalyticsClient
    private let debounce: Duration
    private let onChosen: @MainActor (AuthUser) async -> Void
    private let onDismiss: @MainActor () -> Void
    private var checkTask: Task<Void, Never>?
    private var hasLoaded = false

    /// - Parameters:
    ///   - service: Checks and takes handles.
    ///   - analytics: Event sink. Never carries a handle.
    ///   - currentHandle: The account's handle now.
    ///   - context: Where the chooser was opened.
    ///   - debounce: How long typing must stop before the server is asked.
    ///   - onChosen: The server took a handle (or kept the current one); the
    ///     caller adopts the account it answered.
    ///   - onDismiss: The person went on without one — "Keep" that could not
    ///     reach the server, or Cancel in settings.
    public init(
        service: HandleServiceProtocol,
        analytics: AnalyticsClient,
        currentHandle: String?,
        context: Context,
        debounce: Duration = .milliseconds(350),
        onChosen: @escaping @MainActor (AuthUser) async -> Void,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.analytics = analytics
        self.currentHandle = currentHandle.map(Handle.normalised).flatMap { $0.isEmpty ? nil : $0 }
        self.context = context
        self.debounce = debounce
        self.onChosen = onChosen
        self.onDismiss = onDismiss
    }

    // MARK: Derived

    /// `true` when Save would take the handle in the field.
    public var canSave: Bool {
        guard !isSaving, !isKeeping else { return false }
        switch status {
        case .available: return true
        // The handle they already have: keeping it is a choice too, except
        // in settings, where it would change nothing.
        case .current: return context != .settings
        default: return false
        }
    }

    /// "Keep @user… for now" is offered — never in settings.
    public var offersKeep: Bool { context != .settings && currentHandle != nil }

    /// The line under the field, in the reader's language; `nil` when there
    /// is nothing to say.
    public var statusLine: String? {
        switch status {
        case .idle: return nil
        case .checking: return L10n.t("account.handle.status.checking")
        case .available: return L10n.t("account.handle.status.available")
        case .current: return L10n.t("account.handle.status.current")
        case let .unavailable(problem): return problem.message
        case let .failed(message): return message
        }
    }

    // MARK: Actions

    /// Reads the server's suggestions and, outside settings, puts the first
    /// one in the field: a good handle is one tap away.
    public func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        analytics.track(.handleOffered, properties: ["source": context.rawValue])
        if context == .settings, let currentHandle {
            text = currentHandle
            status = .current
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let answer = try await service.check("")
            suggestions = answer.suggestions
            // Typing that started while this was in flight wins.
            if context != .settings, text.isEmpty, let first = answer.suggestions.first {
                text = first
                status = .available
            }
        } catch {
            // No suggestions is not a failure: the field still works, and
            // the first check will say what is wrong.
        }
    }

    /// The field changed. The rules the phone knows answer at once; the
    /// server is asked once the typing stops.
    public func update(_ typed: String) {
        let value = Handle.normalised(typed)
        guard value != text else { return }
        text = value
        saveError = nil
        checkTask?.cancel()
        if value.isEmpty {
            status = .idle
        } else if value == currentHandle {
            status = .current
        } else if !Handle.isValid(value) {
            status = .unavailable(.invalid)
        } else {
            status = .checking
            let wait = debounce
            checkTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                await self?.check(value)
            }
        }
    }

    /// A suggestion chip: free when the server offered it, so no question.
    public func pick(_ suggestion: String) {
        checkTask?.cancel()
        text = Handle.normalised(suggestion)
        saveError = nil
        status = text == currentHandle ? .current : .available
    }

    /// Takes the handle in the field.
    public func save() async {
        guard canSave else { return }
        let wanted = text
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let account = try await service.choose(wanted)
            analytics.track(.handleChosen, properties: [
                "source": context.rawValue,
                "result": wanted == currentHandle ? "kept" : suggestions.contains(wanted) ? "suggestion" : "typed"
            ])
            await onChosen(account)
        } catch let error as APIError {
            refused(error, wanted: wanted)
        } catch {
            saveError = L10n.t("common.somethingWentWrong")
        }
    }

    /// "Keep @user… for now": the handle the account has, taken as its
    /// choice so the step is not offered again. Never a dead end — if the
    /// server cannot be reached the person goes on anyway.
    public func keep() async {
        guard offersKeep, let currentHandle, !isSaving, !isKeeping else { return }
        checkTask?.cancel()
        isKeeping = true
        defer { isKeeping = false }
        do {
            let account = try await service.choose(currentHandle)
            analytics.track(.handleChosen, properties: ["source": context.rawValue, "result": "kept"])
            await onChosen(account)
        } catch {
            analytics.track(.handleChosen, properties: ["source": context.rawValue, "result": "skipped"])
            onDismiss()
        }
    }

    /// Cancel, in settings.
    public func dismiss() {
        checkTask?.cancel()
        onDismiss()
    }

    // MARK: Internals

    private func check(_ value: String) async {
        do {
            let answer = try await service.check(value)
            // The field moved on while this was asked.
            guard value == text else { return }
            if !answer.suggestions.isEmpty { suggestions = answer.suggestions }
            status = answer.available ? .available : .unavailable(answer.reason ?? .taken)
        } catch let error as APIError {
            guard value == text, !error.isCancellation else { return }
            status = .failed(error.userMessage)
        } catch {
            guard value == text else { return }
            status = .failed(L10n.t("common.somethingWentWrong"))
        }
    }

    /// A refusal from `POST /me/handle`. About the handle: said on its line,
    /// with fresh suggestions — somebody may have taken it a moment ago.
    /// About anything else: said under the button.
    private func refused(_ error: APIError, wanted: String) {
        switch error.code {
        case .handleTaken:
            status = .unavailable(.taken)
            Task { await refreshSuggestions(after: wanted) }
        case .handleReserved:
            status = .unavailable(.reserved)
            Task { await refreshSuggestions(after: wanted) }
        case .invalidHandle:
            status = .unavailable(.invalid)
        default:
            if !error.isCancellation { saveError = error.userMessage }
        }
    }

    private func refreshSuggestions(after wanted: String) async {
        guard let answer = try? await service.check(wanted), wanted == text else { return }
        if !answer.suggestions.isEmpty { suggestions = answer.suggestions }
        if !answer.available { status = .unavailable(answer.reason ?? .taken) }
    }
}
