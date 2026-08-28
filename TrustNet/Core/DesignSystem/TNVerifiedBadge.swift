import SwiftUI

/// The permanent TrustNet checkmark. **Component 6 of 13.**
///
/// This mark means one thing and one thing only: a human being presented a
/// government ID and passed a liveness challenge. It pulses gently on appear
/// so it reads as *alive* rather than as a static sticker — and it honours
/// `accessibilityReduceMotion`, in which case the pulse is skipped entirely.
///
/// ```swift
/// TNVerifiedBadge(size: 18)
/// ```
public struct TNVerifiedBadge: View {

    private let size: CGFloat
    private let isPulsing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// Creates a verified checkmark.
    /// - Parameters:
    ///   - size: Diameter in points. Defaults to 16.
    ///   - isPulsing: Whether the halo animates. Ignored when Reduce Motion is on.
    public init(size: CGFloat = 16, isPulsing: Bool = true) {
        self.size = size
        self.isPulsing = isPulsing
    }

    private var animates: Bool { isPulsing && !reduceMotion }

    public var body: some View {
        ZStack {
            Circle()
                .fill(TNColor.primary.opacity(0.35))
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 1.9 : 1)
                .opacity(pulse ? 0 : 0.9)

            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(TNColor.primary)
                .shadow(color: TNColor.primary.opacity(0.6), radius: size / 4)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animates else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Verified human"))
        .accessibilityHint(Text("This account passed government ID and liveness verification"))
    }
}

#Preview("TNVerifiedBadge") {
    HStack(spacing: TNSpacing.xl) {
        TNVerifiedBadge(size: 14)
        TNVerifiedBadge(size: 22)
        TNVerifiedBadge(size: 40)
        TNVerifiedBadge(size: 40, isPulsing: false)
    }
    .padding(TNSpacing.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TNColor.background)
}
