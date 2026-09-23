import SwiftUI

/// Brand navigation chrome. **Component 13 of 13.**
///
/// SwiftUI's stock navigation bar is white-ish and rounded; Sila wants a
/// flat terminal header on the brand canvas. ``SLNavigationBarModifier``
/// forces the bar background to ``SLColor/surface1``, tints titles with
/// ``SLColor/textPrimary``, and optionally swaps in a custom back button.
///
/// ```swift
/// SomeScreen().tnNavigationBar(title: "Verify email", onBack: { router.pop() })
/// ```
public struct SLNavigationBarModifier: ViewModifier {

    private let title: String
    private let displayMode: NavigationBarItem.TitleDisplayMode
    private let showsBackButton: Bool
    private let onBack: (() -> Void)?

    /// Creates the modifier. Prefer ``SwiftUI/View/tnNavigationBar(title:displayMode:onBack:)``.
    public init(
        title: String,
        displayMode: NavigationBarItem.TitleDisplayMode = .inline,
        showsBackButton: Bool = true,
        onBack: (() -> Void)? = nil
    ) {
        self.title = title
        self.displayMode = displayMode
        self.showsBackButton = showsBackButton
        self.onBack = onBack
    }

    public func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(displayMode)
            .toolbarBackground(SLColor.surface1, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .modifier(HidesSystemBack(hidden: onBack != nil || !showsBackButton))
            .toolbar {
                if let onBack, showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SLColor.primary)
                        }
                        .accessibilityLabel(Text(L10n.t("common.back")))
                        .accessibilityHint(Text(L10n.t("ds.navigationBar.backHint")))
                    }
                }
            }
            .tint(SLColor.primary)
    }
}

/// Hides the system back button when asked — and otherwise says nothing.
///
/// Writing `.navigationBarBackButtonHidden(false)` is not neutral: it is a
/// value, and it overrode a screen that had hidden the button itself to put
/// its own there. The live room hides it for its "Leave" arrow, then applied
/// this modifier, and the system arrow came back beside "Leave" — two back
/// arrows next to each other (reported 2026-09-23). So the modifier only ever
/// hides; it never un-hides.
private struct HidesSystemBack: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.navigationBarBackButtonHidden(true)
        } else {
            content
        }
    }
}

extension View {
    /// Applies Sila's navigation bar styling.
    /// - Parameters:
    ///   - title: Bar title.
    ///   - displayMode: `.inline` by default.
    ///   - onBack: Supply to replace the system back button with a branded one.
    public func tnNavigationBar(
        title: String,
        displayMode: NavigationBarItem.TitleDisplayMode = .inline,
        onBack: (() -> Void)? = nil
    ) -> some View {
        modifier(SLNavigationBarModifier(title: title, displayMode: displayMode, onBack: onBack))
    }

    /// Fills the safe area with the Sila canvas gradient.
    public func tnScreenBackground() -> some View {
        background(SLColor.canvasGradient.ignoresSafeArea())
    }
}

#Preview("NavigationBarModifier") {
    NavigationStack {
        VStack {
            Text("Screen body")
                .font(SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: "Verify email", onBack: {})
    }
}
