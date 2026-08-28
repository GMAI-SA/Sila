import SwiftUI

/// Brand navigation chrome. **Component 13 of 13.**
///
/// SwiftUI's stock navigation bar is white-ish and rounded; TrustNet wants a
/// flat terminal header on the brand canvas. ``TNNavigationBarModifier``
/// forces the bar background to ``TNColor/surface1``, tints titles with
/// ``TNColor/textPrimary``, and optionally swaps in a custom back button.
///
/// ```swift
/// SomeScreen().tnNavigationBar(title: "Verify email", onBack: { router.pop() })
/// ```
public struct TNNavigationBarModifier: ViewModifier {

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
            .toolbarBackground(TNColor.surface1, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarBackButtonHidden(onBack != nil || !showsBackButton)
            .toolbar {
                if let onBack, showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TNColor.primary)
                        }
                        .accessibilityLabel(Text("Back"))
                        .accessibilityHint(Text("Returns to the previous screen"))
                    }
                }
            }
            .tint(TNColor.primary)
    }
}

extension View {
    /// Applies TrustNet's navigation bar styling.
    /// - Parameters:
    ///   - title: Bar title.
    ///   - displayMode: `.inline` by default.
    ///   - onBack: Supply to replace the system back button with a branded one.
    public func tnNavigationBar(
        title: String,
        displayMode: NavigationBarItem.TitleDisplayMode = .inline,
        onBack: (() -> Void)? = nil
    ) -> some View {
        modifier(TNNavigationBarModifier(title: title, displayMode: displayMode, onBack: onBack))
    }

    /// Fills the safe area with the TrustNet canvas gradient.
    public func tnScreenBackground() -> some View {
        background(TNColor.canvasGradient.ignoresSafeArea())
    }
}

#Preview("NavigationBarModifier") {
    NavigationStack {
        VStack {
            Text("Screen body")
                .font(TNFont.body)
                .foregroundStyle(TNColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: "Verify email", onBack: {})
    }
}
