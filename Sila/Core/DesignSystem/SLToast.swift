import SwiftUI

/// A transient message shown by ``SLToast``.
public struct SLToastMessage: Identifiable, Equatable, Sendable {

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
            case .success: return SLColor.secondary
            case .error: return SLColor.danger
            case .warning: return SLColor.warning
            case .info: return SLColor.primary
            }
        }

        var spokenPrefix: String {
            switch self {
            case .success: return L10n.t("ds.toast.success")
            case .error: return L10n.t("ds.toast.error")
            case .warning: return L10n.t("ds.toast.warning")
            case .info: return L10n.t("ds.toast.info")
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
    public static func success(_ text: String) -> SLToastMessage { .init(kind: .success, text: text) }
    /// Convenience constructor for an error toast.
    public static func error(_ text: String) -> SLToastMessage { .init(kind: .error, text: text) }
    /// Convenience constructor for a warning toast.
    public static func warning(_ text: String) -> SLToastMessage { .init(kind: .warning, text: text) }
    /// Convenience constructor for an informational toast.
    public static func info(_ text: String) -> SLToastMessage { .init(kind: .info, text: text) }

    public static func == (lhs: SLToastMessage, rhs: SLToastMessage) -> Bool { lhs.id == rhs.id }
}

/// A slide-up overlay banner. **Component 9 of 13.**
///
/// Attach once near the root of a screen with ``SwiftUI/View/tnToast(_:)`` and
/// publish messages by assigning to the bound optional. The overlay dismisses
/// itself after ``SLToastMessage/duration`` seconds, or immediately on tap.
///
/// ```swift
/// SomeScreen().tnToast($viewModel.toast)
/// ```
public struct SLToast: View {

    private let message: SLToastMessage
    private let onDismiss: () -> Void

    /// Creates a toast view. Prefer ``SwiftUI/View/tnToast(_:)``.
    public init(message: SLToastMessage, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: SLSpacing.md) {
            Image(systemName: message.kind.icon)
                .foregroundStyle(message.kind.tint)
                .font(.system(size: 18, weight: .semibold))
            Text(message.text)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SLSpacing.md)
        .background(SLColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.md)
                .strokeBorder(message.kind.tint.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .padding(.horizontal, SLSpacing.lg)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("ds.toast.spoken", message.kind.spokenPrefix, message.text)))
        .accessibilityHint(Text(L10n.t("ds.toast.dismissHint")))
        .accessibilityAddTraits(.isButton)
    }
}

private struct SLToastPresenter: ViewModifier {
    @Binding var message: SLToastMessage?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                SLToast(message: message) { self.message = nil }
                    .padding(.bottom, SLSpacing.xxl)
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
    /// Presents ``SLToast`` overlays for the bound optional message.
    public func tnToast(_ message: Binding<SLToastMessage?>) -> some View {
        modifier(SLToastPresenter(message: message))
    }
}

#Preview("SLToast") {
    VStack(spacing: SLSpacing.md) {
        SLToast(message: .success("Account created.")) {}
        SLToast(message: .error("That code has expired.")) {}
        SLToast(message: .warning("Too many attempts. Try again in 60 seconds.")) {}
        SLToast(message: .info("A new code is on its way.")) {}
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
