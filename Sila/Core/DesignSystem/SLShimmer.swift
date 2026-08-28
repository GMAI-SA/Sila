import SwiftUI

/// A loading-skeleton shimmer modifier. **Component 8 of 13.**
///
/// Apply to any placeholder shape while content loads. The sweep is disabled
/// under Reduce Motion, where the placeholder simply sits at a static opacity.
///
/// ```swift
/// RoundedRectangle(cornerRadius: 8)
///     .fill(SLColor.surface2)
///     .frame(height: 18)
///     .tnShimmer(isActive: vm.isLoading)
/// ```
public struct SLShimmer: ViewModifier {

    private let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    /// - Parameter isActive: When `false` the modifier is a no-op.
    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        if !isActive {
            content
        } else if reduceMotion {
            content.opacity(0.6).accessibilityLabel(Text("Loading"))
        } else {
            content
                .overlay { sweep.mask { content } }
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 2
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Loading"))
                .accessibilityHint(Text("Content is still being fetched"))
        }
    }

    private var sweep: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    .clear,
                    SLColor.textPrimary.opacity(0.18),
                    SLColor.textPrimary.opacity(0.05),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.7)
            .offset(x: phase * geo.size.width)
        }
    }
}

extension View {
    /// Applies the Sila skeleton shimmer.
    /// - Parameter isActive: Pass the view model's loading flag.
    public func tnShimmer(isActive: Bool = true) -> some View {
        modifier(SLShimmer(isActive: isActive))
    }
}

/// A ready-made skeleton row used while lists load.
public struct SLSkeletonRow: View {
    private let lineCount: Int

    /// - Parameter lineCount: Number of placeholder lines. Defaults to 3.
    public init(lineCount: Int = 3) {
        self.lineCount = lineCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            ForEach(0..<lineCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: SLRadius.sm)
                    .fill(SLColor.surface2)
                    .frame(height: 14)
                    .frame(maxWidth: index == lineCount - 1 ? 160 : .infinity, alignment: .leading)
            }
        }
        .tnShimmer()
    }
}

#Preview("SLShimmer") {
    VStack(spacing: SLSpacing.xl) {
        SLSkeletonRow()
        SLSkeletonRow(lineCount: 2)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SLColor.background)
}
