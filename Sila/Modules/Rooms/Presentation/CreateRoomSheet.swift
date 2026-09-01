import SwiftUI

/// Opens a room: a title, a topic, and the audience that decides who may speak.
///
/// The audience picker is the composer's, unchanged. That is deliberate: the
/// rule about country rooms is the same rule as the one about country threads —
/// you may only open one for the country your identity was verified in — and a
/// second picker with a second implementation of it is a second place for it to
/// be wrong. Unavailable audiences are shown and explained here for the same
/// reason they are in the composer: a blank space teaches nobody what
/// verification is for.
///
/// The sentence at the top states the asymmetry once, plainly. Everyone can
/// listen to every room; the picker below is about the microphone.
@MainActor
public struct CreateRoomSheet: View {

    @Bindable private var viewModel: CreateRoomViewModel
    private let onClose: @MainActor () -> Void
    private let onCreated: (@MainActor (VoiceRoom) -> Void)?

    @FocusState private var isTitleFocused: Bool

    /// - Parameters:
    ///   - viewModel: Owns the draft and the create call.
    ///   - onClose: Dismisses the sheet.
    ///   - onCreated: Called with the created room so the caller can walk
    ///     straight into it.
    public init(
        viewModel: CreateRoomViewModel,
        onClose: @escaping @MainActor () -> Void,
        onCreated: (@MainActor (VoiceRoom) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
        self.onCreated = onCreated
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                explanation
                titleField
                topicPicker
                audiencePicker
                schedule
                stageSize
                notRecorded

                if let error = viewModel.createError {
                    Text(error)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SLButton(
                    viewModel.isScheduled
                        ? L10n.t("rooms.create.scheduleButton")
                        : L10n.t("rooms.create.startButton"),
                    isLoading: viewModel.isCreating,
                    isEnabled: viewModel.canCreate,
                    accessibilityHint: viewModel.isScheduled
                        ? L10n.t("rooms.create.scheduleButton.a11yHint")
                        : L10n.t("rooms.create.startButton.a11yHint"),
                    asyncAction: { await create() }
                )
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: RoomCopy.createTitle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.t("common.cancel"), action: onClose)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
        .task { await viewModel.loadTopics() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Sections

    private var explanation: some View {
        Text(RoomCopy.createExplanation)
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            SLTextField(
                L10n.t("rooms.create.titleFieldLabel"),
                text: $viewModel.title,
                placeholder: RoomCopy.titlePlaceholder,
                autocapitalization: .sentences,
                error: viewModel.titleError,
                accessibilityHint: L10n.t("rooms.create.titleField.a11yHint")
            )
            .focused($isTitleFocused)
            // The title is the host's own words; the field follows what they
            // are typing rather than the interface's language.
            .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.title))

            Text(L10n.plural(
                "rooms.create.charactersLeft",
                max(0, viewModel.remainingTitleCharacters)
            ))
                .font(SLFont.micro)
                .foregroundStyle(
                    viewModel.remainingTitleCharacters < 0 ? SLColor.danger : SLColor.textMuted
                )
        }
    }

    /// The taxonomy, as chips. Tapping the selected one clears it — a room
    /// without a topic is a perfectly good room, and there is no "none" chip to
    /// hunt for.
    private var topicPicker: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("rooms.create.topicHeader"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)

            if viewModel.isLoadingTopics {
                SLSkeletonRow(lineCount: 1)
            } else if viewModel.topics.isEmpty {
                // Says what is missing rather than pretending there is nothing
                // to choose. The room can still be opened.
                Text(L10n.t("rooms.create.topicsFailed"))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                FlowLayout(spacing: SLSpacing.sm) {
                    ForEach(viewModel.topics) { topic in
                        SLChip(
                            topic.label,
                            isSelected: viewModel.topic == topic.id,
                            accessibilityHint: topic.detail,
                            onTap: { viewModel.select(topic: topic.id) }
                        )
                    }
                }
            }
        }
    }

    private var audiencePicker: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.sm) {
                Text(L10n.t("rooms.create.whoCanSpeak"))
                    .font(SLFont.micro)
                    .tracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)
                Spacer(minLength: 0)
                Text(L10n.t("rooms.create.everyoneCanListen"))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L10n.t("rooms.create.audience.a11yLabel")))

            VStack(spacing: SLSpacing.sm) {
                ForEach(viewModel.scopeOptions) { option in
                    // The composer's own row, so the two pickers cannot drift
                    // apart about what an unavailable audience looks like.
                    ScopeOptionRow(
                        option: option,
                        isSelected: option.scope == viewModel.scope,
                        onTap: { viewModel.select(option) }
                    )
                }
            }
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Toggle(isOn: $viewModel.isScheduled) {
                Text(L10n.t("rooms.create.scheduleToggle"))
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
            }
            .tint(SLColor.primary)
            .accessibilityHint(Text(RoomCopy.scheduleExplanation))

            if viewModel.isScheduled {
                DatePicker(
                    L10n.t("rooms.create.startsLabel"),
                    selection: $viewModel.scheduledFor,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .tint(SLColor.primary)
                .foregroundStyle(SLColor.textPrimary)
            }

            Text(RoomCopy.scheduleExplanation)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stageSize: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("rooms.create.stageSizeHeader"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)

            HStack(spacing: SLSpacing.sm) {
                ForEach(RoomConstants.speakerLimits, id: \.self) { limit in
                    SLChip(
                        SLFormat.number(limit),
                        isSelected: viewModel.maxSpeakers == limit,
                        accessibilityHint: L10n.plural("rooms.create.stageSize.a11yHint", limit),
                        onTap: { viewModel.maxSpeakers = limit }
                    )
                }
                Spacer(minLength: 0)
            }

            Text(L10n.t("rooms.create.stageSize.explanation"))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Said before the room exists, not after somebody has spoken in it.
    private var notRecorded: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SLColor.secondary)
            Text(RoomCopy.neverRecorded)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(RoomCopy.neverRecorded))
    }

    private func create() async {
        isTitleFocused = false
        guard let room = await viewModel.create() else { return }
        onClose()
        onCreated?(room)
    }
}

// MARK: - Layout

/// A wrapping row of chips.
///
/// Hand-rolled because `LazyVGrid` cannot do variable-width items and a
/// horizontal `ScrollView` would hide half the taxonomy behind a swipe nobody
/// discovers.
struct FlowLayout: Layout {

    let spacing: CGFloat

    init(spacing: CGFloat = SLSpacing.sm) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height + spacing }
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width,
                      height: max(0, height - spacing))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.width + (current.indices.isEmpty ? 0 : spacing) + size.width
            if !current.indices.isEmpty, projected > width {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width += (current.indices.count == 1 ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Create room — verified in SA") {
    NavigationStack {
        CreateRoomSheet(
            viewModel: CreateRoomViewModel(
                author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
                service: RoomsServiceMock(),
                preferences: PreferencesServiceMock(),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}
