import SwiftUI

/// Feed preferences — and the only place the hidden topic tagging becomes
/// visible to the person it affects.
///
/// The backend labels every post by topic with a model, keeps those labels off
/// the post, and uses them to filter one feed. A control panel that never
/// mentioned any of that would be asking people to tune something they have not
/// been told exists, so the disclosure is the first thing on the screen rather
/// than a footnote under the save button.
///
/// The other rule this screen is built around: it must never imply a control
/// does more than it does. The filter switch turned on with nothing selected
/// narrows nothing — the backend deliberately keeps the feed open — so the
/// screen says so in as many words instead of letting the switch imply
/// otherwise.
@MainActor
public struct PreferencesScreen: View {

    @Bindable private var viewModel: PreferencesViewModel
    private let onClose: (@MainActor () -> Void)?

    @FocusState private var isCountryFieldFocused: Bool

    /// Chips are placed by a custom ``Layout``, and a custom layout is handed
    /// raw coordinates rather than mirrored ones — see ``SLFlowLayout``.
    @Environment(\.layoutDirection) private var layoutDirection

    /// - Parameters:
    ///   - viewModel: Owns the draft, the stored copy and the difference.
    ///   - onClose: Dismisses the screen. `nil` hides the Done button, for a
    ///     presentation that has its own back affordance.
    public init(
        viewModel: PreferencesViewModel,
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
            saveBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("preferences.title"))
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("common.done")) { onClose() }
                        .foregroundStyle(SLColor.primary)
                        .accessibilityLabel(Text(L10n.t("common.done")))
                        .accessibilityHint(Text(L10n.t("preferences.done.hint")))
                }
            }
        }
        .task { await viewModel.load() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            loadingState
        } else if let error = viewModel.loadError, !viewModel.hasLoaded {
            ScrollView {
                SLEmptyState(
                    icon: "wifi.exclamationmark",
                    title: L10n.t("preferences.error.title"),
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: L10n.t("preferences.error.retry"),
                    action: { Task { await viewModel.reload() } }
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl * 2)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.xl) {
                    disclosureCard
                    summaryCard
                    internationalSection
                    topicsSection
                    countriesSection
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.lg)
                .padding(.bottom, SLSpacing.xl)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var loadingState: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<6, id: \.self) { _ in
                SLSkeletonRow(lineCount: 2)
                    .padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text(L10n.t("preferences.loading.accessibility")))
    }

    // MARK: - The disclosure

    /// The plain-language statement of what the tagging is.
    ///
    /// Deliberately at the top, in body type, in two sentences. It is the
    /// reason the rest of the screen exists.
    private var disclosureCard: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack(spacing: SLSpacing.sm) {
                    Image(systemName: "tag")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SLColor.primary)
                        .accessibilityHidden(true)
                    Text(L10n.t("preferences.disclosure.title"))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                }

                Text(Self.taggingDisclosure)
                    // Body-primary, not the muted caption grey the rest of the
                    // screen's explanations use: this is the one paragraph
                    // that must not read as fine print.
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The exact wording of the AI-tagging disclosure.
    ///
    /// Held in one place so it is asserted in tests: this sentence is the
    /// screen's obligation, not decoration, and it must not drift — in either
    /// language. The Arabic says the same four things: labelling is automatic,
    /// it happens on Sila's servers, it is sometimes wrong, and the labels are
    /// used for nothing but this screen.
    static var taggingDisclosure: String { L10n.t("preferences.disclosure.body") }

    // MARK: - The live summary

    private var summaryCard: some View {
        SLCard(isHighlighted: viewModel.hasUnsavedChanges) {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text(L10n.t(viewModel.summaryIsInEffect
                    ? "preferences.summary.inEffect"
                    : "preferences.summary.notSaved"))
                    .font(SLFont.micro)
                    .tracking(0.8)
                    .foregroundStyle(
                        viewModel.summaryIsInEffect ? SLColor.textSecondary : SLColor.warning
                    )

                Text(viewModel.summary)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !viewModel.summaryIsInEffect {
                    Text(L10n.t("preferences.summary.afterSaving"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }

                if !viewModel.unknownTopicIds.isEmpty {
                    Text(
                        L10n.plural(
                            "preferences.summary.unknownTopics",
                            viewModel.unknownTopicIds.count
                        )
                    )
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - International section

    private var internationalSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("preferences.section.international"))

            PreferenceToggleRow(
                title: L10n.t("preferences.filter.title"),
                detail: L10n.t("preferences.filter.detail"),
                accessibilityHint: L10n.t("preferences.filter.hint"),
                isOn: Binding(
                    get: { viewModel.draft.filterInternationalByInterests },
                    set: { viewModel.setFilterEnabled($0) }
                )
            )

            if let warning = viewModel.unusedFilterWarning {
                warningBox(warning)
            }

            PreferenceToggleRow(
                title: L10n.t("preferences.untagged.title"),
                detail: untaggedDetail,
                accessibilityHint: L10n.t("preferences.untagged.hint"),
                isOn: Binding(
                    get: { viewModel.draft.showUntaggedPosts },
                    set: { viewModel.setShowUntaggedPosts($0) }
                )
            )
        }
    }

    private var untaggedDetail: String {
        let base = L10n.t("preferences.untagged.detail")
        guard !viewModel.draft.showUntaggedPostsHasEffect else { return base }
        return base + " " + L10n.t("preferences.untagged.detail.noEffect")
    }

    private func warningBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: SLSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SLColor.warning)
                .accessibilityHidden(true)

            Text(text)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Topics

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("preferences.section.topics"))

            Text(L10n.t("preferences.topics.explanation"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SLSegmentedControl(
                items: TopicListFilter.allCases,
                selection: $viewModel.listFilter,
                accessibilityHint: { $0.accessibilityHint },
                title: { viewModel.title(for: $0) }
            )

            if viewModel.visibleTopics.isEmpty {
                Text(L10n.t("preferences.topics.emptySlice"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .padding(.vertical, SLSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.visibleTopics) { topic in
                        TopicStanceRow(
                            topic: topic,
                            stance: viewModel.draft.stance(for: topic.id),
                            onSelect: { viewModel.setStance($0, for: topic.id) }
                        )
                        if topic.id != viewModel.visibleTopics.last?.id {
                            SLDivider()
                        }
                    }
                }
                .padding(.vertical, SLSpacing.sm)
                .background(SLColor.surface1)
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: SLRadius.lg)
                        .strokeBorder(SLColor.stroke, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Muted countries

    private var countriesSection: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("preferences.section.mutedCountries"))

            Text(L10n.t("preferences.countries.explanation"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: SLSpacing.sm) {
                SLTextField(
                    L10n.t("preferences.countries.field.label"),
                    text: $viewModel.countryDraft,
                    // An ISO code, not a word: the same two letters in both
                    // languages, so it is not translated.
                    placeholder: "JP",
                    autocapitalization: .characters,
                    error: viewModel.countryError,
                    accessibilityHint: L10n.t("preferences.countries.field.hint"),
                    submitLabel: .done,
                    onSubmit: { viewModel.addCountry() }
                )
                .focused($isCountryFieldFocused)

                SLButton(
                    L10n.t("preferences.countries.add"),
                    variant: .secondary,
                    size: .compact,
                    accessibilityHint: L10n.t("preferences.countries.add.hint"),
                    action: {
                        viewModel.addCountry()
                        isCountryFieldFocused = false
                    }
                )
                .frame(width: 88)
                // Keeps the button off the field's error line.
                .padding(.bottom, viewModel.countryError == nil ? 0 : 22)
            }

            if viewModel.draft.mutedCountries.isEmpty {
                Text(L10n.t("preferences.countries.emptyList"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                SLFlowLayout(spacing: SLSpacing.sm) {
                    ForEach(viewModel.draft.mutedCountries, id: \.self) { code in
                        SLChip(
                            countryChipTitle(code),
                            isSelected: false,
                            accessibilityHint: L10n.t("preferences.countries.chip.hint"),
                            onRemove: { viewModel.removeCountry(code) }
                        )
                    }
                }
            }
        }
    }

    private func countryChipTitle(_ code: String) -> String {
        guard let flag = CountryCode.flag(code) else { return MutedCountries.displayName(code) }
        return "\(flag) \(MutedCountries.displayName(code))"
    }

    // MARK: - Save bar

    @ViewBuilder
    private var saveBar: some View {
        if viewModel.hasLoaded {
            VStack(spacing: SLSpacing.sm) {
                if let error = viewModel.saveError {
                    Text(error)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(L10n.t("preferences.save.failed.a11yLabel", error)))
                }

                HStack(spacing: SLSpacing.md) {
                    Text(statusText)
                        .font(SLFont.caption)
                        .foregroundStyle(
                            viewModel.hasUnsavedChanges ? SLColor.warning : SLColor.textSecondary
                        )
                        .accessibilityLabel(Text(statusText))

                    Spacer(minLength: 0)

                    if viewModel.hasUnsavedChanges {
                        SLButton(
                            L10n.t("preferences.discard"),
                            variant: .ghost,
                            size: .compact,
                            isEnabled: !viewModel.isSaving,
                            accessibilityHint: L10n.t("preferences.discard.hint"),
                            action: { viewModel.discardChanges() }
                        )
                        .frame(width: 96)
                    }

                    SLButton(
                        L10n.t("common.save"),
                        variant: .primary,
                        size: .compact,
                        isLoading: viewModel.isSaving,
                        isEnabled: viewModel.hasUnsavedChanges,
                        accessibilityHint: L10n.t("preferences.save.hint"),
                        asyncAction: { await viewModel.save() }
                    )
                    .frame(width: 110)
                }
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.md)
            .background(SLColor.surface1)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(SLColor.stroke)
                    .frame(height: 1)
            }
        }
    }

    /// Never says "saved" for something that is not stored on the server.
    private var statusText: String {
        if viewModel.isSaving { return L10n.t("preferences.status.saving") }
        if viewModel.hasUnsavedChanges { return L10n.t("preferences.status.unsaved") }
        if viewModel.saveError != nil { return L10n.t("preferences.status.notSaved") }
        return L10n.t("preferences.status.saved")
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(SLFont.micro)
            .tracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Toggle row

/// One labelled switch with its explanation underneath.
@MainActor
struct PreferenceToggleRow: View {

    let title: String
    let detail: String
    let accessibilityHint: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(SLColor.primary)
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(accessibilityHint))

            Text(detail)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(detail))
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.lg)
                .strokeBorder(SLColor.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Topic row

/// One topic, its server-written description, and a three-way stance control.
@MainActor
struct TopicStanceRow: View {

    let topic: TopicOption
    let stance: TopicStance
    let onSelect: @MainActor (TopicStance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.label)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)

                Text(topic.detail)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: SLSpacing.sm) {
                // Neutral in the middle, so the row reads as a scale rather
                // than as two options and an afterthought.
                ForEach([TopicStance.interested, TopicStance.none, TopicStance.muted]) { option in
                    SLChip(
                        option.title,
                        icon: icon(for: option),
                        isSelected: stance == option,
                        accessibilityHint: option.accessibilityHint,
                        onTap: { onSelect(option) }
                    )
                    .accessibilityLabel(Text("\(topic.label): \(option.title)"))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
    }

    private func icon(for stance: TopicStance) -> String? {
        switch stance {
        case .interested: return "hand.thumbsup"
        case .muted: return "speaker.slash"
        case .none: return nil
        }
    }
}

// MARK: - Flow layout

/// Wraps chips onto as many lines as they need.
///
/// A `Layout` rather than a `LazyVGrid` because muted-country chips are all
/// different widths — a grid would leave ragged gaps between "Japan (JP)" and
/// "Saudi Arabia (SA)".
struct SLFlowLayout: Layout {

    let spacing: CGFloat

    init(spacing: CGFloat = SLSpacing.sm) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map { $0.width }.max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var width: CGFloat
        var items: [Item]
    }

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, width: 0, items: [])
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing, height: 0, width: 0, items: [])
                x = 0
            }
            current.items.append(Item(index: index, x: x, size: size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
            current.width = x - spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Preferences — populated") {
    NavigationStack {
        PreferencesScreen(
            viewModel: PreferencesViewModel(
                service: PreferencesServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Preferences — nothing chosen") {
    NavigationStack {
        PreferencesScreen(
            viewModel: PreferencesViewModel(
                service: PreferencesServiceMock(scenario: .empty),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Preferences — offline") {
    NavigationStack {
        PreferencesScreen(
            viewModel: PreferencesViewModel(
                service: PreferencesServiceMock(scenario: .offline),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}
