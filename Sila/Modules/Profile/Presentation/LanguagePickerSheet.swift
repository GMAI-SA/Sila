import SwiftUI

/// The app-language picker: System / English / العربية.
///
/// Each option is written in the language it names — somebody stranded in the
/// wrong language has to be able to find their own without reading the one on
/// screen. The choice applies immediately, layout direction included: the root
/// view rebuilds on the preference, so there is no restart and no half-applied
/// state to explain away.
@MainActor
public struct LanguagePickerSheet: View {

    @Bindable private var preference: LanguagePreference
    private let analytics: AnalyticsClient
    private let onClose: @MainActor () -> Void

    /// - Parameters:
    ///   - preference: The app-wide language store.
    ///   - analytics: Event sink.
    ///   - onClose: Dismisses the sheet.
    public init(
        preference: LanguagePreference,
        analytics: AnalyticsClient,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.preference = preference
        self.analytics = analytics
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: SLSpacing.md) {
                Text(L10n.t("profile.language.sheet.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SLSpacing.sm)

                VStack(spacing: SLSpacing.sm) {
                    ForEach(AppLanguageChoice.allCases, id: \.rawValue) { choice in
                        option(choice)
                    }
                }
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.lg)
        }
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("profile.language.sheet.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("common.done"), action: onClose)
                    .foregroundStyle(SLColor.primary)
                    .accessibilityHint(Text(L10n.t("profile.language.done.hint")))
            }
        }
    }

    private func option(_ choice: AppLanguageChoice) -> some View {
        let isSelected = preference.choice == choice
        return SLCard(
            accessibilityLabel: choice.title,
            accessibilityHint: L10n.t("profile.language.option.hint"),
            onTap: {
                guard !isSelected else { return }
                preference.select(choice)
                analytics.track(.languageChanged, properties: ["language": choice.rawValue])
            }
        ) {
            HStack(spacing: SLSpacing.md) {
                Text(choice.title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    // "English" reads left-to-right and "العربية" right-to-left
                    // whatever the interface is doing around them.
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: choice.title))

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SLColor.primary)
                        .accessibilityLabel(Text(L10n.t("profile.language.selected.accessibility")))
                }
            }
        }
    }
}

#Preview("Language picker") {
    NavigationStack {
        LanguagePickerSheet(
            preference: LanguagePreference(storage: InMemoryStorageClient()),
            analytics: RecordingAnalyticsClient(),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}
