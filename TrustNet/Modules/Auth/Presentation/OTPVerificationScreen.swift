import SwiftUI
import UIKit

/// **Screen 4 — OTP verification.**
///
/// Six independent digit boxes (not a single text field), with auto-advance,
/// backspace-into-previous, full-code paste and a 60-second resend countdown.
///
/// Focus is owned by ``OTPVerificationViewModel/focusedIndex`` rather than by
/// SwiftUI's `@FocusState`: the boxes are `UIViewRepresentable`s, which do not
/// participate in SwiftUI's focus system, so first-responder status is driven
/// explicitly from model state. That also makes the auto-advance rules
/// unit-testable.
///
/// > Note: The spec's "auto-paste from SMS" becomes `.oneTimeCode` on each box
/// > — the same autofill affordance, driven by the emailed code.
@MainActor
public struct OTPVerificationScreen: View {

    @State private var viewModel: OTPVerificationViewModel
    private let onVerified: (TokenPair) -> Void

    /// - Parameters:
    ///   - email: Address the code went to.
    ///   - purpose: Register / login / reset.
    ///   - service: Auth backend.
    ///   - onVerified: Called with the issued session on success.
    public init(
        email: String,
        purpose: OTPPurpose,
        service: AuthServiceProtocol,
        onVerified: @escaping (TokenPair) -> Void
    ) {
        _viewModel = State(
            initialValue: OTPVerificationViewModel(email: email, purpose: purpose, service: service)
        )
        self.onVerified = onVerified
    }

    public var body: some View {
        VStack(spacing: TNSpacing.xl) {
            header
            digitBoxes
            errorSlot

            TNButton(
                "Verify",
                variant: .primary,
                isLoading: viewModel.isVerifying,
                isEnabled: viewModel.isComplete,
                accessibilityHint: "Submits the six digit code"
            ) {
                Task { await verify() }
            }

            resendRow

            Spacer()
        }
        .padding(.horizontal, TNSpacing.lg)
        .padding(.top, TNSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tnScreenBackground()
        .tnNavigationBar(title: viewModel.purpose.screenTitle)
        .tnToast($viewModel.toast)
        .onAppear { viewModel.startCountdown() }
        .onDisappear { viewModel.stopCountdown() }
        .onChange(of: viewModel.isComplete) { _, isComplete in
            guard isComplete else { return }
            Task { await verify() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: TNSpacing.sm) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(TNColor.primary)

            Text("Enter your code")
                .font(TNFont.displayL)
                .foregroundStyle(TNColor.textPrimary)

            Text("We sent a \(AppConfig.otpLength)-digit code to \(viewModel.maskedEmail).")
                .font(TNFont.bodyLight)
                .foregroundStyle(TNColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("Enter your code. We sent a \(AppConfig.otpLength) digit code to \(viewModel.maskedEmail).")
        )
    }

    private var digitBoxes: some View {
        HStack(spacing: TNSpacing.sm) {
            ForEach(0..<AppConfig.otpLength, id: \.self) { index in
                OTPDigitBoxView(
                    digit: viewModel.digits[index],
                    isFocused: viewModel.focusedIndex == index,
                    hasError: viewModel.errorMessage != nil,
                    onInput: { viewModel.input($0, at: index) },
                    onBackspace: { viewModel.backspace(at: index) },
                    onTap: { viewModel.focus(index) }
                )
                .accessibilityLabel(Text("Digit \(index + 1) of \(AppConfig.otpLength)"))
                .accessibilityHint(Text("Enter one digit of your emailed confirmation code"))
                .accessibilityValue(Text(viewModel.digits[index].isEmpty ? "Empty" : viewModel.digits[index]))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var errorSlot: some View {
        Text(viewModel.errorMessage ?? " ")
            .font(TNFont.caption)
            .foregroundStyle(TNColor.danger)
            .multilineTextAlignment(.center)
            .frame(height: 32)
            .opacity(viewModel.errorMessage == nil ? 0 : 1)
            .accessibilityHidden(viewModel.errorMessage == nil)
    }

    private var resendRow: some View {
        VStack(spacing: TNSpacing.xs) {
            TNButton(
                viewModel.resendTitle,
                variant: .ghost,
                size: .compact,
                isLoading: viewModel.isResending,
                isEnabled: viewModel.canResend,
                accessibilityHint: viewModel.canResend
                    ? "Sends a fresh six digit code to your email"
                    : "Available once the countdown reaches zero"
            ) {
                Task { await viewModel.resend() }
            }

            Text("Check your spam folder if it doesn't arrive.")
                .font(TNFont.caption)
                .foregroundStyle(TNColor.textMuted)
        }
    }

    private func verify() async {
        await viewModel.verify()
        if let pair = viewModel.consumeVerifiedPair() {
            onVerified(pair)
        }
    }
}

// MARK: - Digit box

/// One styled digit box: chrome in SwiftUI, first-responder handling in UIKit.
@MainActor
struct OTPDigitBoxView: View {

    let digit: String
    let isFocused: Bool
    let hasError: Bool
    let onInput: (String) -> Void
    let onBackspace: () -> Void
    let onTap: () -> Void

    var body: some View {
        OTPDigitField(
            digit: digit,
            isFocused: isFocused,
            onInput: onInput,
            onBackspace: onBackspace
        )
        .frame(height: 60)
        .frame(maxWidth: .infinity)
        .background(TNColor.surface1)
        .clipShape(RoundedRectangle(cornerRadius: TNRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: TNRadius.md)
                .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: TNRadius.md))
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: hasError)
    }

    private var borderColor: Color {
        if hasError { return TNColor.danger }
        if isFocused { return TNColor.primary }
        if !digit.isEmpty { return TNColor.secondary.opacity(0.6) }
        return TNColor.stroke
    }
}

/// `UITextField` bridge for a single digit.
///
/// Every edit is rejected (`return false`) and forwarded to the view model
/// instead, so the model — not UIKit — is the single source of truth for what
/// each box contains.
struct OTPDigitField: UIViewRepresentable {

    let digit: String
    let isFocused: Bool
    let onInput: (String) -> Void
    let onBackspace: () -> Void

    func makeUIView(context: Context) -> BackspaceTextField {
        let field = BackspaceTextField()
        field.delegate = context.coordinator
        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.textAlignment = .center
        field.tintColor = UIColor(TNColor.primary)
        field.textColor = UIColor(TNColor.textPrimary)
        field.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        field.backgroundColor = .clear
        field.borderStyle = .none
        return field
    }

    func updateUIView(_ field: BackspaceTextField, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onBackspace = onBackspace
        field.onBackspaceWhenEmpty = onBackspace

        if field.text != digit {
            field.text = digit
        }

        // First-responder changes must not happen inside a layout pass.
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onBackspace: onBackspace)
    }

    /// Forwards `UITextFieldDelegate` edits to the view model.
    final class Coordinator: NSObject, UITextFieldDelegate {
        var onInput: (String) -> Void
        var onBackspace: () -> Void

        init(onInput: @escaping (String) -> Void, onBackspace: @escaping () -> Void) {
            self.onInput = onInput
            self.onBackspace = onBackspace
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                onBackspace()
            } else {
                // `string` may be a whole pasted or autofilled code; the view
                // model spreads it across the boxes.
                onInput(string)
            }
            return false
        }
    }
}

/// `UITextField` that reports a backspace received while already empty —
/// the hook SwiftUI's `TextField` does not provide, and without which
/// deleting back through the code feels broken.
final class BackspaceTextField: UITextField {

    /// Called when the user hits delete on an empty field.
    var onBackspaceWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        let wasEmpty = (text ?? "").isEmpty
        super.deleteBackward()
        if wasEmpty { onBackspaceWhenEmpty?() }
    }
}

#Preview("OTPVerificationScreen") {
    let container = AppContainer.preview()
    return NavigationStack {
        OTPVerificationScreen(
            email: "aziz@example.com",
            purpose: .register,
            service: container.authService,
            onVerified: { _ in }
        )
    }
}
