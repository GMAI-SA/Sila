import SwiftUI

/// The invitation a guest meets when they reach for something.
///
/// Shown at the moment somebody tried to reply, or like, or enter a room —
/// which is the only moment the answer to "why should I sign up" is obvious.
/// It names that thing, gives the honest reason this place asks at all, and
/// leaves without argument if they would rather keep reading.
@MainActor
public struct JoinPromptSheet: View {

    private let prompt: JoinPrompt
    private let onCreateAccount: @MainActor () -> Void
    private let onSignIn: @MainActor () -> Void
    private let onDismiss: @MainActor () -> Void

    public init(
        prompt: JoinPrompt,
        onCreateAccount: @escaping @MainActor () -> Void,
        onSignIn: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.prompt = prompt
        self.onCreateAccount = onCreateAccount
        self.onSignIn = onSignIn
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: SLSpacing.lg) {
            ZStack {
                Circle()
                    .fill(SLColor.primary.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: prompt.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(SLColor.primary)
            }
            .padding(.top, SLSpacing.xl)
            .accessibilityHidden(true)

            VStack(spacing: SLSpacing.sm) {
                Text(prompt.title)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(prompt.detail)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SLSpacing.lg)

            Spacer(minLength: 0)

            VStack(spacing: SLSpacing.sm) {
                SLButton(
                    L10n.t("guest.join.create"),
                    variant: .primary,
                    action: onCreateAccount
                )
                .accessibilityIdentifier("guest.join.create")

                SLButton(
                    L10n.t("guest.join.signIn"),
                    variant: .secondary,
                    action: onSignIn
                )
                .accessibilityIdentifier("guest.join.signIn")

                // Never a dead end: reading is genuinely open, and somebody
                // who is not ready is somebody who might be later.
                Button(L10n.t("guest.join.later"), action: onDismiss)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .padding(.top, SLSpacing.xs)
                    .accessibilityIdentifier("guest.join.later")
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.bottom, SLSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }
}

/// The strip along the top of a guest's feed.
///
/// Quiet on purpose: one line saying what is going on, and a way in. A guest
/// who is reading is doing the thing that might convince them, and a banner
/// that interrupts that is a banner that loses them.
@MainActor
struct GuestBanner: View {

    let onJoin: @MainActor () -> Void

    var body: some View {
        HStack(spacing: SLSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("guest.banner.title"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textPrimary)
                Text(L10n.t("guest.banner.detail"))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            SLButton(L10n.t("guest.banner.action"), variant: .primary, size: .compact, action: onJoin)
                .frame(width: 84)
                .accessibilityIdentifier("guest.banner.join")
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
        .background(SLColor.surface1)
        .overlay(alignment: .bottom) { SLDivider() }
    }
}
