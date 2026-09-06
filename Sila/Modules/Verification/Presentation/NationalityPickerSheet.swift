import SwiftUI

/// The first step of verification: what the person says their nationality is.
///
/// Every country, searchable, flagged. This is a **claim** — the badge is
/// written only from evidence, and every route compares the evidence with
/// what was chosen here. A person who picks the wrong one by mistake can
/// change it until they verify; a person who picks a wrong one on purpose is
/// rejected the moment a document says otherwise. The copy says so.
@MainActor
public struct NationalityPickerSheet: View {

    /// One row: an ISO alpha-2 code and its name in the interface language.
    public struct Country: Identifiable, Equatable, Sendable {
        public let code: String
        public let name: String
        public var id: String { code }
    }

    private let selected: String?
    private let isSaving: Bool
    private let onPick: (String) -> Void

    @State private var query = ""

    /// - Parameters:
    ///   - selected: The claim already on the account, if any.
    ///   - isSaving: `true` while the choice is being sent.
    ///   - onPick: Called with the chosen alpha-2 code.
    public init(selected: String?, isSaving: Bool = false, onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.isSaving = isSaving
        self.onPick = onPick
    }

    /// Every real country, named for the current locale, sorted by name.
    public static func allCountries(locale: Locale = .current) -> [Country] {
        Locale.Region.isoRegions
            .compactMap { region -> Country? in
                guard let code = CountryCode.normalised(region.identifier),
                      let name = CountryCode.name(code, locale: locale) else { return nil }
                return Country(code: code, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var countries: [Country] {
        let all = Self.allCountries()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.code.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.t("nationality.picker.message"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(countries) { country in
                        Button {
                            guard !isSaving else { return }
                            onPick(country.code)
                        } label: {
                            HStack(spacing: SLSpacing.md) {
                                Text(CountryCode.flag(country.code) ?? "")
                                    .font(.system(size: 24))
                                    .accessibilityHidden(true)
                                Text(country.name)
                                    .font(SLFont.body)
                                    .foregroundStyle(SLColor.textPrimary)
                                Spacer(minLength: 0)
                                if country.code == selected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(SLColor.primary)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityLabel(Text(country.name))
                        .accessibilityHint(Text(L10n.t("nationality.picker.row.hint")))
                        .accessibilityAddTraits(country.code == selected ? .isSelected : [])
                        .listRowBackground(SLColor.surface1)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .tnScreenBackground()
            .searchable(text: $query, prompt: L10n.t("nationality.picker.search"))
            .navigationTitle(L10n.t("nationality.picker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView().tint(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("nationality.picker.saving")))
                }
            }
        }
        .tint(SLColor.primary)
    }
}

#Preview("Nationality picker") {
    NationalityPickerSheet(selected: "SA") { _ in }
        .preferredColorScheme(.dark)
}
