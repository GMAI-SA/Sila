import SwiftUI

/// **Screen 1 — Splash.**
///
/// Plays a 1.2s boot animation (opacity + a slight upward slide) while
/// ``AuthSession/restore()`` probes the keychain for a usable token. The
/// animation and the network probe run concurrently; the screen exits when
/// *both* the minimum display time and the probe have finished, so the app
/// never flashes the wordmark for 40ms on a fast connection.
@MainActor
public struct SplashScreen: View {

    private let session: AuthSession

    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkOffset: CGFloat = 16
    @State private var haloScale: CGFloat = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter session: The session to restore.
    public init(session: AuthSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            SLColor.background.ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [SLColor.primary.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 220
                    )
                )
                .frame(width: 440, height: 440)
                .scaleEffect(haloScale)
                .blur(radius: 20)

            VStack(spacing: SLSpacing.md) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(SLColor.brandGradient)

                Text(L10n.t("auth.brand.wordmark"))
                    .font(SLFont.displayXL)
                    .tracking(-0.5)
                    .foregroundStyle(SLColor.textPrimary)

                Text(L10n.t("auth.splash.tagline"))
                    .font(SLFont.caption)
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(SLColor.textMuted)
            }
            .opacity(wordmarkOpacity)
            .offset(y: wordmarkOffset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("auth.splash.a11yLabel")))
        .accessibilityHint(Text(L10n.t("auth.splash.a11yHint")))
        .task {
            startAnimation()
            // Probe the keychain while the wordmark animates in, then hold the
            // screen until at least 1.2s have elapsed.
            async let restore: Void = session.restore()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = await restore
        }
    }

    private func startAnimation() {
        guard !reduceMotion else {
            wordmarkOpacity = 1
            wordmarkOffset = 0
            haloScale = 1
            return
        }
        withAnimation(.easeOut(duration: 0.9)) {
            wordmarkOpacity = 1
            wordmarkOffset = 0
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            haloScale = 1.05
        }
    }

}

#Preview("SplashScreen") {
    SplashScreen(session: AppContainer.preview().session)
}
