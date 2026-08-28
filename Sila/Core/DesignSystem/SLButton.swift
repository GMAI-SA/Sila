import SwiftUI

/// The Sila button. **Component 1 of 13.**
///
/// Four visual variants plus a loading state that swaps the label for a
/// spinner while keeping the button's footprint identical, so nothing on the
/// screen shifts when an async action starts.
///
/// ```swift
/// SLButton("Send Code", variant: .primary, isLoading: vm.isSending) {
///     await vm.sendCode()
/// }
/// ```
public struct SLButton: View {

    /// Visual weight of a ``SLButton``.
    public enum Variant {
        /// Filled brand gradient — the single most important action on a screen.
        case primary
        /// Outlined — the secondary path (e.g. "Sign In" next to "Create Account").
        case secondary
        /// Filled danger — irreversible actions.
        case destructive
        /// Text-only — tertiary affordances such as "Resend" or "Cancel".
        case ghost
    }

    /// Vertical footprint of a ``SLButton``.
    public enum Size {
        case regular, compact

        var height: CGFloat { self == .regular ? 52 : 40 }
        var font: Font { self == .regular ? SLFont.bodyEmphasis : SLFont.caption }
    }

    private let title: String
    private let variant: Variant
    private let size: Size
    private let icon: String?
    private let isLoading: Bool
    private let isEnabled: Bool
    private let accessibilityHintText: String?
    private let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    /// Creates a button with a synchronous action.
    /// - Parameters:
    ///   - title: The visible label; also the default accessibility label.
    ///   - variant: Visual weight. Defaults to ``Variant/primary``.
    ///   - size: Vertical footprint. Defaults to ``Size/regular``.
    ///   - icon: Optional SF Symbol drawn before the title.
    ///   - isLoading: When `true` the label is replaced by a spinner and taps are ignored.
    ///   - isEnabled: When `false` the button dims and taps are ignored.
    ///   - accessibilityHint: What happens when the user activates the button.
    ///   - action: Work to perform on tap.
    public init(
        _ title: String,
        variant: Variant = .primary,
        size: Size = .regular,
        icon: String? = nil,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.icon = icon
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.accessibilityHintText = accessibilityHint
        self.action = action
    }

    /// Creates a button whose action is an async throwing task.
    ///
    /// The task is launched on the main actor; errors are intentionally not
    /// swallowed here — the caller's view model owns error presentation.
    public init(
        _ title: String,
        variant: Variant = .primary,
        size: Size = .regular,
        icon: String? = nil,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        accessibilityHint: String? = nil,
        asyncAction: @escaping () async -> Void
    ) {
        self.init(
            title,
            variant: variant,
            size: size,
            icon: icon,
            isLoading: isLoading,
            isEnabled: isEnabled,
            accessibilityHint: accessibilityHint,
            action: { Task { await asyncAction() } }
        )
    }

    private var isInteractive: Bool { isEnabled && !isLoading }

    public var body: some View {
        Button(action: { if isInteractive { action() } }) {
            ZStack {
                label.opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foreground)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .strokeBorder(strokeColor, lineWidth: variant == .secondary ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isInteractive ? 1 : 0.45)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isPressed)
            .animation(.easeInOut(duration: 0.2), value: isLoading)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isInteractive { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(accessibilityHintText ?? "Activates \(title)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isLoading ? Text("Working") : Text(""))
    }

    @ViewBuilder
    private var label: some View {
        HStack(spacing: SLSpacing.sm) {
            if let icon {
                Image(systemName: icon).font(size.font.weight(.semibold))
            }
            Text(title).font(size.font)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, SLSpacing.lg)
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary:
            SLColor.brandGradient
        case .secondary:
            SLColor.surface2.opacity(colorScheme == .dark ? 0.6 : 1)
        case .destructive:
            SLColor.danger
        case .ghost:
            Color.clear
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary: return Color(tnHex: 0x02121C)
        case .secondary: return SLColor.textPrimary
        case .destructive: return .white
        case .ghost: return SLColor.primary
        }
    }

    private var strokeColor: Color {
        variant == .secondary ? SLColor.primary.opacity(0.45) : .clear
    }
}

#Preview("SLButton") {
    VStack(spacing: SLSpacing.md) {
        SLButton("Create Account", variant: .primary) {}
        SLButton("Sign In", variant: .secondary) {}
        SLButton("Delete Account", variant: .destructive) {}
        SLButton("Resend code", variant: .ghost, size: .compact) {}
        SLButton("Sending…", variant: .primary, isLoading: true) {}
        SLButton("Disabled", variant: .primary, isEnabled: false) {}
        SLButton("Face ID", variant: .secondary, icon: "faceid") {}
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
