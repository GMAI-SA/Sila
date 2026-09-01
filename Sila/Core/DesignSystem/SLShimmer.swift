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
    /// The sweep travels along the reading direction, so it has to know which
    /// one is in force — neither `offset(x:)` nor a gradient's unit points
    /// mirror themselves.
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var phase: CGFloat = -1

    /// - Parameter isActive: When `false` the modifier is a no-op.
    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        if !isActive {
            content
        } else if reduceMotion {
            content.opacity(0.6).accessibilityLabel(Text(L10n.t("ds.shimmer.loading")))
        } else {
            content
                .overlay { sweep.mask { content } }
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 2
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L10n.t("ds.shimmer.loading")))
                .accessibilityHint(Text(L10n.t("ds.shimmer.hint")))
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
                startPoint: gradientStart,
                endPoint: gradientEnd
            )
            .frame(width: geo.size.width * 0.7)
            .offset(x: isRightToLeft ? -phase * geo.size.width : phase * geo.size.width)
        }
    }

    private var isRightToLeft: Bool { layoutDirection == .rightToLeft }

    /// Explicit unit points rather than `.leading` / `.trailing`: the gradient's
    /// stops are asymmetric (the bright band sits near the start), so the whole
    /// sweep — band and travel alike — has to be mirrored together.
    private var gradientStart: UnitPoint {
        isRightToLeft ? UnitPoint(x: 1, y: 0.5) : UnitPoint(x: 0, y: 0.5)
    }

    private var gradientEnd: UnitPoint {
        isRightToLeft ? UnitPoint(x: 0, y: 0.5) : UnitPoint(x: 1, y: 0.5)
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
