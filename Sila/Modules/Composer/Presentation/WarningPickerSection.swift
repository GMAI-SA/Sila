import SwiftUI

/// The content-warning picker in the composer.
///
/// Four options and, once one is chosen, a line for the author's own words
/// about what is covered. The hint says what a warning does — readers see a
/// cover and choose to open it — and what the note is for: what is behind the
/// cover, not the thing itself. A note that repeated the spoiler would be the
/// spoiler.
@MainActor
struct WarningPickerSection: View {

    @Bindable var viewModel: ComposerViewModel

    /// The picker's value. `SensitiveKind?` cannot be a `Picker` tag directly,
    /// so "none" is the empty string and the three kinds are their raw values.
    private var selection: Binding<String> {
        Binding(
            get: { viewModel.sensitive?.rawValue ?? "" },
            set: { viewModel.sensitive = SensitiveKind(rawValue: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("composer.sensitive.label"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)

            Picker(L10n.t("composer.sensitive.label"), selection: selection) {
                Text(L10n.t("composer.sensitive.none")).tag("")
                Text(L10n.t("composer.sensitive.spoiler")).tag(SensitiveKind.spoiler.rawValue)
                Text(L10n.t("composer.sensitive.violence")).tag(SensitiveKind.violence.rawValue)
                Text(L10n.t("composer.sensitive.other")).tag(SensitiveKind.other.rawValue)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("composer.sensitive")

            if viewModel.sensitive != nil {
                SLTextField(
                    L10n.t("composer.sensitive.note.label"),
                    text: $viewModel.sensitiveNote,
                    placeholder: L10n.t("composer.sensitive.note.placeholder"),
                    accessibilityHint: L10n.t("composer.sensitive.note.hint")
                )
                .slContentDirection(
                    TextDirection.resolve(languageCode: nil, text: viewModel.sensitiveNote)
                )
                .accessibilityIdentifier("composer.sensitive.note")

                Text(L10n.t("composer.sensitive.hint"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, SLSpacing.xs)
    }
}
