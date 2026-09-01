import SwiftUI

/// A labelled text input with an inline error slot. **Component 2 of 13.**
///
/// The error slot is always laid out (as a fixed-height row) so revealing a
/// validation message never pushes the rest of the form down.
///
/// ```swift
/// SLTextField(
///     "Email",
///     text: $vm.email,
///     placeholder: "you@example.com",
///     keyboard: .emailAddress,
///     error: vm.emailError
/// )
/// ```
public struct SLTextField: View {

    private let label: String
    @Binding private var text: String
    private let placeholder: String
    private let isSecure: Bool
    private let keyboard: UIKeyboardType
    private let contentType: UITextContentType?
    private let autocapitalization: TextInputAutocapitalization
    private let error: String?
    private let accessibilityHintText: String?
    private let submitLabel: SubmitLabel
    private let onSubmit: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    /// Creates a text field.
    /// - Parameters:
    ///   - label: Caption drawn above the field. Also the accessibility label.
    ///   - text: Two-way binding to the entered value.
    ///   - placeholder: Ghost text shown when `text` is empty.
    ///   - isSecure: Renders as a password field with a reveal toggle.
    ///   - keyboard: Keyboard type presented on focus.
    ///   - contentType: `UITextContentType` used for autofill / one-time codes.
    ///   - autocapitalization: Defaults to `.never`, which is correct for emails.
    ///   - error: When non-`nil`, the field turns red and this message is shown.
    ///   - accessibilityHint: What the field is for.
    ///   - submitLabel: Return-key label.
    ///   - onSubmit: Called when the user hits return.
    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil,
        autocapitalization: TextInputAutocapitalization = .never,
        error: String? = nil,
        accessibilityHint: String? = nil,
        submitLabel: SubmitLabel = .return,
        onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.keyboard = keyboard
        self.contentType = contentType
        self.autocapitalization = autocapitalization
        self.error = error
        self.accessibilityHintText = accessibilityHint
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    private var hasError: Bool { !(error ?? "").isEmpty }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(label.uppercased())
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(hasError ? SLColor.danger : SLColor.textSecondary)
                .accessibilityHidden(true)

            HStack(spacing: SLSpacing.sm) {
                field
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled()
                    .submitLabel(submitLabel)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
                    .accessibilityLabel(Text(label))
                    .accessibilityHint(Text(accessibilityHintText ?? L10n.t("ds.textField.defaultHint", label.lowercased())))

                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(SLColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isRevealed ? L10n.t("ds.textField.hide", label) : L10n.t("ds.textField.show", label)))
                    .accessibilityHint(Text(L10n.t("ds.textField.revealHint", label.lowercased())))
                }
            }
            .padding(.horizontal, SLSpacing.md)
            .frame(height: 52)
            .background(SLColor.surface1)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .strokeBorder(borderColor, lineWidth: isFocused || hasError ? 1.5 : 1)
            )
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeInOut(duration: 0.18), value: hasError)

            Text(error ?? " ")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.danger)
                .opacity(hasError ? 1 : 0)
                .frame(height: 16, alignment: .leading)
                .accessibilityHidden(!hasError)
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure && !isRevealed {
            SecureField("", text: $text, prompt: promptText)
        } else {
            TextField("", text: $text, prompt: promptText)
        }
    }

    private var promptText: Text {
        Text(placeholder).foregroundColor(SLColor.textMuted)
    }

    private var borderColor: Color {
        if hasError { return SLColor.danger }
        if isFocused { return SLColor.primary }
        return SLColor.stroke
    }
}

private struct SLTextFieldPreviewHost: View {
    @State private var email = ""
    @State private var password = "hunter2"

    var body: some View {
        VStack(spacing: SLSpacing.md) {
            SLTextField("Email", text: $email, placeholder: "you@example.com", keyboard: .emailAddress, contentType: .emailAddress)
            SLTextField("Password", text: $password, placeholder: "At least 8 characters", isSecure: true, contentType: .password)
            SLTextField("Email", text: $email, placeholder: "you@example.com", error: "That email is already registered.")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SLColor.background)
    }
}

#Preview("SLTextField") {
    SLTextFieldPreviewHost()
}
