import SwiftUI

/// A transient message shown by ``TNToast``.
public struct TNToastMessage: Identifiable, Equatable, Sendable {

    /// Semantic kind of a toast, which drives its icon and tint.
    public enum Kind: Sendable {
        case success, error, warning, info

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return TNColor.secondary
            case .error: return TNColor.danger
            case .warning: return TNColor.warning
            case .info: return TNColor.primary
            }
        }

        var spokenPrefix: String {
            switch self {
            case .success: return "Success"
            case .error: return "Error"
            case .warning: return "Warning"
            case .info: return "Notice"
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    public let text: String
    /// Seconds the toast stays on screen before auto-dismissing.
    public let duration: TimeInterval

    /// Creates a toast message.
    public init(kind: Kind, text: String, duration: TimeInterval = 3) {
        self.kind = kind
        self.text = text
        self.duration = duration
    }

    /// Convenience constructor for a success toast.
    public static func success(_ text: String) -> TNToastMessage { .init(kind: .success, text: text) }
    /// Convenience constructor for an error toast.
    public static func error(_ text: String) -> TNToastMessage { .init(kind: .error, text: text) }
    /// Convenience constructor for a warning toast.
    public static func warning(_ text: String) -> TNToastMessage { .init(kind: .warning, text: text) }
    /// Convenience constructor for an informational toast.
    public static func info(_ text: String) -> TNToastMessage { .init(kind: .info, text: text) }

    public static func == (lhs: TNToastMessage, rhs: TNToastMessage) -> Bool { lhs.id == rhs.id }
}

/// A slide-up overlay banner. **Component 9 of 13.**
///
/// Attach once near the root of a screen with ``SwiftUI/View/tnToast(_:)`` and
/// publish messages by assigning to the bound optional. The overlay dismisses
/// itself after ``TNToastMessage/duration`` seconds, or immediately on tap.
///
/// ```swift
/// SomeScreen().tnToast($viewModel.toast)
/// ```
public struct TNToast: View {

    private let message: TNToastMessage
    private let onDismiss: () -> Void

    /// Creates a toast view. Prefer ``SwiftUI/View/tnToast(_:)``.
    public init(message: TNToastMessage, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: TNSpacing.md) {
            Image(systemName: message.kind.icon)
                .foregroundStyle(message.kind.tint)
                .font(.system(size: 18, weight: .semibold))
            Text(message.text)
                .font(TNFont.caption)
                .foregroundStyle(TNColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(TNSpacing.md)
        .background(TNColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: TNRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: TNRadius.md)
                .strokeBorder(message.kind.tint.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .padding(.horizontal, TNSpacing.lg)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(message.kind.spokenPrefix). \(message.text)"))
        .accessibilityHint(Text("Double tap to dismiss this message"))
        .accessibilityAddTraits(.isButton)
    }
}

private struct TNToastPresenter: ViewModifier {
    @Binding var message: TNToastMessage?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                TNToast(message: message) { self.message = nil }
                    .padding(.bottom, TNSpacing.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message.id) {
                        let nanos = UInt64(message.duration * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanos)
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            self.message = nil
                        }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: message)
    }
}

extension View {
    /// Presents ``TNToast`` overlays for the bound optional message.
    public func tnToast(_ message: Binding<TNToastMessage?>) -> some View {
        modifier(TNToastPresenter(message: message))
    }
}

#Preview("TNToast") {
    VStack(spacing: TNSpacing.md) {
        TNToast(message: .success("Account created.")) {}
        TNToast(message: .error("That code has expired.")) {}
        TNToast(message: .warning("Too many attempts. Try again in 60 seconds.")) {}
        TNToast(message: .info("A new code is on its way.")) {}
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TNColor.background)
}
