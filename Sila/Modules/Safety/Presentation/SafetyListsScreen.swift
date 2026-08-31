import SwiftUI

/// Settings → Safety: who you have blocked, who you have muted, and what you
/// have reported.
///
/// The screen exists because a safety action nobody can find again is a safety
/// action nobody trusts. Somebody who blocked a person in a bad week has to be
/// able to look, later, at exactly who that was — and undo it from the row it is
/// on, without a second confirmation. They already decided; the app recorded it
/// for them; asking them to justify the reversal would be the wrong way round.
///
/// The captions above each list are load-bearing rather than decorative. Two of
/// them say the accounts were never told, which is the fact that decides whether
/// people use these tools at all, and the blocked one repeats that unblocking
/// does not bring a severed follow back.
@MainActor
public struct SafetyListsScreen: View {

    @Bindable private var viewModel: SafetyListsViewModel
    private let onClose: (@MainActor () -> Void)?
    private let onOpenProfile: (@MainActor (String) -> Void)?

    /// - Parameters:
    ///   - viewModel: Owns the three lists.
    ///   - onClose: Dismisses the screen. `nil` hides the Done button.
    ///   - onOpenProfile: Opens somebody's page from a row. `nil` makes the rows
    ///     inert, which is the honest state when profiles are switched off.
    public init(
        viewModel: SafetyListsViewModel,
        onClose: (@MainActor () -> Void)? = nil,
        onOpenProfile: (@MainActor (String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
        self.onOpenProfile = onOpenProfile
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLSegmentedControl(
                items: SafetyListTab.allCases,
                selection: $viewModel.tab,
                accessibilityHint: { $0.accessibilityHint },
                title: { $0.title }
            )

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: "Safety")
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                        .foregroundStyle(SLColor.primary)
                        .accessibilityLabel(Text("Done"))
                        .accessibilityHint(Text("Closes your safety lists"))
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
        } else if let error = viewModel.loadError {
            ScrollView {
                SLEmptyState(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load your safety lists",
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: "Try again",
                    action: { Task { await viewModel.reload() } }
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.md) {
                    caption

                    switch viewModel.tab {
                    case .blocked: blockedList
                    case .muted: mutedList
                    case .reports: reportsList
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.lg)
            }
            .refreshable { await viewModel.reload() }
        }
    }

    private var loadingState: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<4, id: \.self) { _ in
                SLSkeletonRow(lineCount: 2).padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Loading your safety lists"))
    }

    /// The line under the tab that says what this list is — and, for two of the
    /// three, what it is not.
    private var caption: some View {
        Text(viewModel.tab.caption)
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, SLSpacing.xs)
    }

    // MARK: - Blocked

    @ViewBuilder
    private var blockedList: some View {
        if viewModel.blocked.isEmpty {
            SLEmptyState(
                icon: "hand.raised",
                title: "Nobody is blocked",
                subtitle: "When you block someone they appear here, and you can undo it "
                    + "from this list at any time.",
                tint: SLColor.textSecondary
            )
        } else {
            ForEach(viewModel.blocked) { relation in
                personRow(
                    relation,
                    actionTitle: "Unblock",
                    hint: "Lets you and \(relation.user.displayName) see each other again. "
                        + "It does not restore any follow that was severed.",
                    action: { await viewModel.unblock(relation) }
                )
            }
        }
    }

    // MARK: - Muted

    @ViewBuilder
    private var mutedList: some View {
        if viewModel.muted.isEmpty {
            SLEmptyState(
                icon: "speaker.slash",
                title: "Nobody is muted",
                subtitle: SafetyCopy.muteEffect,
                tint: SLColor.textSecondary
            )
        } else {
            ForEach(viewModel.muted) { relation in
                personRow(
                    relation,
                    actionTitle: "Unmute",
                    hint: "Lets \(relation.user.displayName)'s posts back into your feeds. "
                        + "They are not told either way.",
                    action: { await viewModel.unmute(relation) }
                )
            }
        }
    }

    /// One account, with its undo button on the row.
    private func personRow(
        _ relation: SafetyRelation,
        actionTitle: String,
        hint: String,
        action: @escaping () async -> Void
    ) -> some View {
        SLCard(padding: SLSpacing.md) {
            HStack(spacing: SLSpacing.md) {
                Button {
                    onOpenProfile?(relation.user.handle)
                } label: {
                    HStack(spacing: SLSpacing.md) {
                        SLAvatar(
                            url: relation.user.avatarURL,
                            initials: relation.user.initials,
                            size: .md,
                            isVerified: relation.user.isVerified,
                            displayName: relation.user.displayName
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: SLSpacing.xs) {
                                Text(relation.user.displayName)
                                    .font(SLFont.bodyEmphasis)
                                    .foregroundStyle(SLColor.textPrimary)
                                    .lineLimit(1)

                                if relation.user.isVerified {
                                    SLVerifiedBadge(size: 13, isPulsing: false)
                                }
                                SLCountryBadge(countryCode: relation.user.countryCode)
                            }

                            Text(relation.user.atHandle)
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpenProfile == nil)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(relation.user.displayName), \(relation.user.atHandle)"))

                Spacer(minLength: 0)

                SLButton(
                    actionTitle,
                    variant: .secondary,
                    size: .compact,
                    isLoading: viewModel.isBusy(relation.user.handle),
                    accessibilityHint: hint,
                    asyncAction: action
                )
                .frame(width: 104)
            }
        }
    }

    // MARK: - Reports

    @ViewBuilder
    private var reportsList: some View {
        if viewModel.reports.isEmpty {
            SLEmptyState(
                icon: "flag",
                title: "You haven't reported anything",
                subtitle: "Reports you file show up here with their status, so you can see "
                    + "what happened to each one.",
                tint: SLColor.textSecondary
            )
        } else {
            ForEach(viewModel.reports) { report in
                reportRow(report)
            }
        }
    }

    private func reportRow(_ report: Report) -> some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                HStack(spacing: SLSpacing.sm) {
                    Text(report.reason?.title ?? "Reported")
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    SLBadge(report.statusLabel, style: badgeStyle(for: report.status))
                }

                Text(report.subjectDescription)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)

                HStack(spacing: SLSpacing.sm) {
                    if let created = report.createdAt {
                        Text(RelativeTime.short(created))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                    }
                    if !report.id.isEmpty {
                        Text(report.id)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "\(report.reason?.title ?? "Report") about \(report.subjectDescription). "
                + "\(report.statusLabel)."
        ))
    }

    /// A colour for a status this client does not own the vocabulary of.
    ///
    /// Anything unrecognised is neutral rather than guessed at: a status that
    /// happens to be new must not be coloured as though somebody's report had
    /// been thrown out.
    private func badgeStyle(for status: String) -> SLBadge.Style {
        switch status.lowercased() {
        case "open", "pending": return .warning
        case "actioned", "upheld", "resolved": return .verified
        case "dismissed", "rejected": return .neutral
        default: return .neutral
        }
    }
}

#Preview("Safety lists — populated") {
    NavigationStack {
        SafetyListsScreen(
            viewModel: SafetyListsViewModel(
                service: SafetyServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Safety lists — empty") {
    NavigationStack {
        SafetyListsScreen(
            viewModel: SafetyListsViewModel(
                service: SafetyServiceMock(scenario: .empty),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}
