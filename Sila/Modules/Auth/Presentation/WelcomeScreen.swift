import SwiftUI

/// **Screen 2 — Welcome.**
///
/// Full-bleed dark canvas with a slowly breathing dot grid behind the pitch.
///
/// > Note: The spec calls for a `CADisplayLink`-driven grid. `TimelineView`
/// > with an `.animation` schedule *is* the SwiftUI-native display-link, and
/// > unlike a raw `CADisplayLink` it pauses automatically when the view leaves
/// > the screen and respects Low Power Mode. Reduce Motion pins it to a static
/// > frame.
@MainActor
public struct WelcomeScreen: View {

    private let onCreateAccount: () -> Void
    private let onSignIn: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - onCreateAccount: Pushes the register screen.
    ///   - onSignIn: Pushes the sign-in screen.
    public init(onCreateAccount: @escaping () -> Void, onSignIn: @escaping () -> Void) {
        self.onCreateAccount = onCreateAccount
        self.onSignIn = onSignIn
    }

    public var body: some View {
        ZStack {
            SLColor.background.ignoresSafeArea()
            AnimatedDotGrid(isAnimated: !reduceMotion)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            LinearGradient(
                colors: [.clear, SLColor.background.opacity(0.85), SLColor.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer(minLength: SLSpacing.xxl)

                VStack(spacing: SLSpacing.lg) {
                    SLVerifiedBadge(size: 56)

                    Text("Sila")
                        .font(SLFont.displayXL)
                        .tracking(-0.5)
                        .foregroundStyle(SLColor.textPrimary)

                    Text("The only social network where every human is real.")
                        .font(SLFont.displayM)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SLSpacing.lg)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Sila. The only social network where every human is real."))

                Spacer()

                VStack(spacing: SLSpacing.md) {
                    SLButton(
                        "Create Account",
                        variant: .primary,
                        accessibilityHint: "Starts registration with your email address",
                        action: onCreateAccount
                    )

                    SLButton(
                        "Sign In",
                        variant: .secondary,
                        accessibilityHint: "Signs in to an existing Sila account",
                        action: onSignIn
                    )

                    Text("Requires government ID verification")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                        .padding(.top, SLSpacing.xs)
                        .accessibilityLabel(Text("Fine print: creating an account requires government ID verification"))
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.bottom, SLSpacing.xl)
            }
        }
    }
}

/// A breathing dot lattice used as the welcome screen's backdrop.
///
/// Driven by `TimelineView(.animation)`, which ticks with the display refresh
/// and stops when the view leaves the screen — the SwiftUI-native equivalent
/// of a `CADisplayLink`, without the manual invalidation.
///
/// Cost matters here: a naive implementation issues one `fill` per dot, which
/// is several hundred draw calls every frame and is enough to saturate the
/// main thread on a simulator. Dots are therefore quantised into a handful of
/// opacity buckets and drawn as one `Path` per bucket — 6 fills a frame
/// instead of ~500, for a difference nobody can see.
struct AnimatedDotGrid: View {

    let isAnimated: Bool

    private let spacing: CGFloat = 28
    private let dotSize: CGFloat = 2.2
    private let bucketCount = 6
    private let frameInterval: Double = 1.0 / 24.0

    var body: some View {
        if isAnimated {
            TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { context in
                canvas(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: 0)
        }
    }

    private func canvas(time: TimeInterval) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: context, size: size, time: time)
        }
        .drawingGroup()
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        guard spacing > 0, size.width > 0, size.height > 0 else { return }

        let columns = Int(size.width / spacing) + 2
        let rows = Int(size.height / spacing) + 2

        var buckets = [Path](repeating: Path(), count: bucketCount)

        for row in 0..<rows {
            for column in 0..<columns {
                let wave = sin(time * 0.8 + Double(column) * 0.32 + Double(row) * 0.18)
                let normalised = (wave + 1) / 2
                let bucket = min(bucketCount - 1, Int(normalised * Double(bucketCount)))
                let rect = CGRect(
                    x: CGFloat(column) * spacing - dotSize / 2,
                    y: CGFloat(row) * spacing - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                buckets[bucket].addEllipse(in: rect)
            }
        }

        for (index, path) in buckets.enumerated() where !path.isEmpty {
            let alpha = 0.06 + 0.16 * (Double(index) / Double(bucketCount - 1))
            context.fill(path, with: .color(SLColor.primary.opacity(alpha)))
        }
    }
}

#Preview("WelcomeScreen") {
    WelcomeScreen(onCreateAccount: {}, onSignIn: {})
}
