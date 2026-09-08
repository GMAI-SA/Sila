import SwiftUI

/// Pick people from the ones you know — followers and following — with a
/// search for everybody else. Multi-select; one button adds them all.
@MainActor
public struct PeoplePickerSheet: View {

    @State private var viewModel: PeoplePickerViewModel
    private let onPick: @MainActor ([UserSummary]) -> Void
    private let onClose: @MainActor () -> Void

    public init(
        viewModel: PeoplePickerViewModel,
        onPick: @escaping @MainActor ([UserSummary]) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onPick = onPick
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: SLSpacing.lg) {
                        SLTextField(
                            L10n.t("people.picker.search.label"),
                            text: $viewModel.query,
                            placeholder: L10n.t("people.picker.search.placeholder"),
                            accessibilityHint: L10n.t("people.picker.search.a11yHint")
                        )
                        .onChange(of: viewModel.query) { _, _ in
                            Task { await viewModel.search() }
                        }

                        if viewModel.isLoading && !viewModel.hasLoaded {
                            SLSkeletonRow(lineCount: 3)
                        } else {
                            knownSection
                            moreSection
                        }
                    }
                    .padding(SLSpacing.lg)
                }

                addBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("people.picker.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.cancel"), action: onClose)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            .task { await viewModel.load() }
            .tnToast($viewModel.toast)
        }
    }

    @ViewBuilder
    private var knownSection: some View {
        let people = viewModel.visibleKnown
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            header(L10n.t("people.picker.known.header"), count: people.count)
            if viewModel.known.isEmpty {
                SLEmptyState(
                    icon: "person.2",
                    title: L10n.t("people.picker.empty.title"),
                    subtitle: L10n.t("people.picker.empty.message"),
                    tint: SLColor.textSecondary
                )
            } else if people.isEmpty {
                Text(L10n.t("people.picker.known.noMatch"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                ForEach(people) { person in
                    row(person)
                }
            }
        }
    }

    @ViewBuilder
    private var moreSection: some View {
        let people = viewModel.more
        if !people.isEmpty || viewModel.isSearching {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                header(L10n.t("people.picker.more.header"), count: people.isEmpty ? nil : people.count)
                if viewModel.isSearching && people.isEmpty {
                    ProgressView().controlSize(.small).tint(SLColor.primary)
                }
                ForEach(people) { person in
                    row(person)
                }
            }
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            if let count {
                Text(SLFormat.number(count))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ person: UserSummary) -> some View {
        let picked = viewModel.isSelected(person)
        return Button {
            viewModel.toggle(person)
        } label: {
            HStack(spacing: SLSpacing.md) {
                SLAvatar(
                    url: person.avatarURL,
                    initials: person.initials,
                    size: .md,
                    isVerified: person.isVerified,
                    displayName: person.displayName
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: person.displayName))
                    HStack(spacing: SLSpacing.xs) {
                        Text(person.atHandle)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .lineLimit(1)
                        SLCountryBadge(countryCode: person.countryCode)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(picked ? SLColor.primary : SLColor.stroke)
            }
            .padding(.vertical, SLSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text("\(person.displayName), \(person.atHandle)"))
    }

    private var addBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(SLColor.stroke).frame(height: 1)
            SLButton(
                L10n.plural("people.picker.add", viewModel.selectedCount),
                variant: .primary,
                icon: "person.badge.plus",
                isEnabled: viewModel.selectedCount > 0,
                action: {
                    onPick(viewModel.selectedPeople)
                    onClose()
                }
            )
            .padding(SLSpacing.lg)
        }
        .background(SLColor.surface1)
    }
}
