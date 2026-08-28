import Foundation
import Observation

/// Drives ``OTPVerificationScreen``.
///
/// Holds the six digits as an array of single characters (not one string), so
/// the view can render independent boxes and the model can implement
/// auto-advance, backspace-into-previous and paste without the view knowing
/// any of those rules.
@MainActor
@Observable
public final class OTPVerificationViewModel {

    /// The address the code was sent to.
    public let email: String
    /// Why the code was sent.
    public let purpose: OTPPurpose

    /// One entry per digit box; empty string means "not filled".
    public private(set) var digits: [String]
    /// Which box should hold focus, or `nil` when the field is complete.
    public private(set) var focusedIndex: Int?
    /// Seconds remaining before Resend becomes available. `0` means available.
    public private(set) var resendCountdown: Int
    /// `true` while `/auth/otp/verify` is in flight.
    public private(set) var isVerifying = false
    /// `true` while `/auth/otp/request` is in flight.
    public private(set) var isResending = false
    /// Inline error under the digit boxes.
    public private(set) var errorMessage: String?
    /// Banner message.
    public var toast: TNToastMessage?
    /// Set on success; the screen hands this to ``AuthSession``.
    public private(set) var verifiedPair: TokenPair?

    private let service: AuthServiceProtocol
    private var countdownTask: Task<Void, Never>?

    /// - Parameters:
    ///   - email: Address the code was sent to.
    ///   - purpose: Register / login / reset.
    ///   - service: Auth backend.
    ///   - initialCountdown: Seconds to start the resend timer at.
    public init(
        email: String,
        purpose: OTPPurpose,
        service: AuthServiceProtocol,
        initialCountdown: Int = AppConfig.defaultOTPResendSeconds
    ) {
        self.email = email
        self.purpose = purpose
        self.service = service
        self.digits = Array(repeating: "", count: AppConfig.otpLength)
        self.focusedIndex = 0
        self.resendCountdown = max(0, initialCountdown)
    }

    // MARK: Derived state

    /// The digits joined into the code that will be submitted.
    public var code: String { digits.joined() }

    /// `true` when all six boxes are filled.
    public var isComplete: Bool {
        digits.allSatisfy { $0.count == 1 }
    }

    /// `true` when the Resend control should be tappable.
    public var canResend: Bool { resendCountdown == 0 && !isResending && !isVerifying }

    /// Label for the resend control, including the countdown when running.
    public var resendTitle: String {
        resendCountdown > 0 ? "Resend in \(resendCountdown)s" : "Resend code"
    }

    /// Address with the local part partly masked, for on-screen display.
    public var maskedEmail: String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return email }
        let local = String(parts[0])
        let domain = String(parts[1])
        guard local.count > 2 else { return email }
        let head = local.prefix(1)
        let tail = local.suffix(1)
        return "\(head)\(String(repeating: "•", count: max(1, local.count - 2)))\(tail)@\(domain)"
    }

    // MARK: Digit entry

    /// Handles the text a single box now contains.
    ///
    /// Accepts a full pasted code in any box: non-digits are stripped, the
    /// first six digits are distributed across the boxes, and verification
    /// fires automatically when the field fills.
    /// - Parameters:
    ///   - text: Raw new contents of the box.
    ///   - index: Which box changed.
    public func input(_ text: String, at index: Int) {
        guard digits.indices.contains(index) else { return }
        errorMessage = nil

        let filtered = text.filter(\.isNumber)

        if filtered.count > 1 {
            paste(filtered, startingAt: index)
            return
        }

        if filtered.isEmpty {
            // The user deleted the box's contents.
            digits[index] = ""
            focusedIndex = index
            return
        }

        digits[index] = String(filtered.prefix(1))
        advanceFocus(from: index)
    }

    /// Handles a backspace on an already-empty box by clearing the previous one.
    public func backspace(at index: Int) {
        guard digits.indices.contains(index) else { return }
        errorMessage = nil
        if digits[index].isEmpty, index > 0 {
            digits[index - 1] = ""
            focusedIndex = index - 1
        } else {
            digits[index] = ""
            focusedIndex = index
        }
    }

    /// Distributes a pasted string across the boxes from `start`.
    public func paste(_ raw: String, startingAt start: Int = 0) {
        let characters = Array(raw.filter(\.isNumber).prefix(AppConfig.otpLength))
        guard !characters.isEmpty else { return }

        // A full-length paste always fills from the first box, whichever box
        // the system happened to deliver it to.
        let origin = characters.count == AppConfig.otpLength ? 0 : start

        for offset in 0..<characters.count {
            let index = origin + offset
            guard digits.indices.contains(index) else { break }
            digits[index] = String(characters[offset])
        }

        let nextEmpty = digits.firstIndex(where: { $0.isEmpty })
        focusedIndex = nextEmpty
    }

    /// Moves focus to `index` (a box was tapped).
    public func focus(_ index: Int) {
        guard digits.indices.contains(index) else { return }
        focusedIndex = index
    }

    /// Clears every box and returns focus to the first.
    public func reset() {
        digits = Array(repeating: "", count: AppConfig.otpLength)
        focusedIndex = 0
    }

    private func advanceFocus(from index: Int) {
        if index + 1 < AppConfig.otpLength {
            focusedIndex = index + 1
        } else {
            focusedIndex = nil
        }
    }

    // MARK: Countdown

    /// Starts (or restarts) the resend countdown.
    ///
    /// Uses a cancellable `Task` rather than a `Timer`, so it stops the moment
    /// the screen goes away and never leaks a run-loop source.
    public func startCountdown(from seconds: Int? = nil) {
        countdownTask?.cancel()
        if let seconds { resendCountdown = max(0, seconds) }
        guard resendCountdown > 0 else { return }

        countdownTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.tickCountdown() else { return }
            }
        }
    }

    /// Decrements the countdown by one second.
    /// - Returns: `false` once the countdown has reached zero.
    @discardableResult
    public func tickCountdown() -> Bool {
        guard resendCountdown > 0 else { return false }
        resendCountdown -= 1
        return resendCountdown > 0
    }

    /// Stops the countdown task (called from `onDisappear`).
    public func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    // MARK: Actions

    /// Submits the entered code.
    public func verify() async {
        guard isComplete, !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        errorMessage = nil

        do {
            let pair = try await service.verifyOTP(email: email, code: code, purpose: purpose)
            verifiedPair = pair
        } catch let error as APIError {
            errorMessage = error.userMessage
            reset()
            if error.code == .otpAttemptsExceeded || error.code == .otpExpired {
                resendCountdown = 0
                stopCountdown()
            }
        } catch {
            errorMessage = "Something went wrong. Please try again."
            reset()
        }
    }

    /// Requests a fresh code and restarts the countdown.
    public func resend() async {
        guard canResend else { return }
        isResending = true
        defer { isResending = false }
        errorMessage = nil

        do {
            let result = try await service.sendOTP(email: email, purpose: purpose)
            reset()
            startCountdown(from: result.resendAfterSeconds)
            toast = .success("A new code is on its way to \(maskedEmail).")
        } catch let error as APIError {
            toast = .error(error.userMessage)
        } catch {
            toast = .error("We couldn't send a new code. Please try again.")
        }
    }

    /// Consumes ``verifiedPair`` so the screen only navigates once.
    public func consumeVerifiedPair() -> TokenPair? {
        defer { verifiedPair = nil }
        return verifiedPair
    }
}
