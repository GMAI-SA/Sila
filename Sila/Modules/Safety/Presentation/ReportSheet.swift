import SwiftUI

/// The reason picker, and whatever the server answers with.
///
/// Two screens in one sheet, and the second one is the reason the first exists
/// in this shape.
///
/// **The picker asks what is wrong before it does anything.** Report is the
/// heaviest of the three safety actions in effort and the lightest in
/// consequence — it takes something away from nobody, and a human reads it — so
/// it is the one that gets a form rather than a dialog. Every row carries a line
/// of explanation, because two people reading "harassment" differently is how a
/// moderation queue fills with reports nobody can action.
///
/// **The outcome is not always a receipt.** When the server attaches `support`,
/// this sheet leads with those resources and stays on screen. Somebody reporting
/// self-harm is usually trying to keep a person alive, and "Thanks, we'll review
/// this" — or a toast that vanishes after three seconds — is the wrong reply to
/// that. See ``ReportOutcome``.
@MainActor
public struct ReportSheet: View {

    @Bindable private var viewModel: ReportViewModel

    /// - Parameter viewModel: Owns the draft and the outcome.
    public init(viewModel: ReportViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                if let outcome = viewModel.outcome {
                    outcomeContent(outcome)
                } else {
                    form
                }
            }
            .padding(SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .scrollDismissesKeyboard(.immediately)
        .tnNavigationBar(title: viewModel.isShowingSupport ? "Support" : "Report")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(viewModel.isEditing ? "Cancel" : "Done") { viewModel.close() }
                    .foregroundStyle(
                        viewModel.isEditing ? SLColor.textSecondary : SLColor.primary
                    )
                    .accessibilityLabel(Text(viewModel.isEditing ? "Cancel" : "Done"))
                    .accessibilityHint(Text(
                        viewModel.isEditing
                            ? "Closes this without reporting anything"
                            : "Closes this screen"
                    ))
            }
        }
    }

    // MARK: - The form

    private var form: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            subjectCard

            Text(SafetyCopy.reportIntro)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            reasonPicker

            if viewModel.reason != nil {
                detailField
            }

            if let error = viewModel.submissionError {
                errorBox(error)
            }

            // Said next to the button, every time. The suspicion that a report
            // gets back to the person reported is the single biggest reason
            // people watch something happen and say nothing.
            Text(SafetyCopy.reportIsSilent)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(SafetyCopy.reportOutcome)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let blocking = viewModel.blockingReason {
                Text(blocking)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Not ready yet. \(blocking)"))
            }

            SLButton(
                "Submit report",
                variant: .primary,
                isLoading: viewModel.isSubmitting,
                isEnabled: viewModel.canSubmit,
                accessibilityHint: "Sends this to a Sila reviewer. "
                    + "\(viewModel.target.name) is not told.",
                asyncAction: { await viewModel.submit() }
            )
        }
    }

    /// What is being reported, quoted so nobody files a report against the wrong
    /// post after scrolling away from it.
    private var subjectCard: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text("REPORTING")
                    .font(SLFont.micro)
                    .tracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)

                Text(viewModel.subject.headline)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let excerpt = viewModel.subject.excerpt {
                    Text(excerpt)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SLSpacing.xs)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var reasonPicker: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text("WHAT IS WRONG?")
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(viewModel.reasons) { reason in
                reasonRow(reason)
            }
        }
    }

    private func reasonRow(_ reason: ReportReason) -> some View {
        let isSelected = viewModel.reason == reason
        return SLCard(
            padding: SLSpacing.md,
            isHighlighted: isSelected,
            accessibilityLabel: "\(reason.title). \(reason.detail)",
            accessibilityHint: isSelected
                ? "Selected. Tap again to clear it."
                : "Chooses this as the reason",
            onTap: { viewModel.select(reason) }
        ) {
            HStack(alignment: .top, spacing: SLSpacing.md) {
                Image(systemName: reason.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? SLColor.primary : SLColor.textSecondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reason.title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)

                    Text(reason.detail)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? SLColor.primary : SLColor.textMuted)
                    .accessibilityHidden(true)
            }
        }
    }

    private var detailField: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            SLTextField(
                viewModel.requiresDetail ? "What is wrong (required)" : "Anything else (optional)",
                text: $viewModel.draft.detail,
                placeholder: viewModel.requiresDetail
                    ? "Describe what you are reporting"
                    : "Only if it helps a reviewer",
                autocapitalization: .sentences,
                error: viewModel.validationError,
                accessibilityHint: viewModel.requiresDetail
                    ? "Required for this reason. Up to \(SafetyLimits.maximumDetailLength) characters."
                    : "Optional. Up to \(SafetyLimits.maximumDetailLength) characters."
            )

            Text("\(viewModel.detailRemaining) characters left")
                .font(SLFont.micro)
                .foregroundStyle(viewModel.detailRemaining < 0 ? SLColor.danger : SLColor.textMuted)
                .accessibilityLabel(Text("\(viewModel.detailRemaining) characters left"))
        }
    }

    // MARK: - Outcomes

    @ViewBuilder
    private func outcomeContent(_ outcome: ReportOutcome) -> some View {
        switch outcome {
        case let .received(receipt):
            received(receipt)
        case let .support(resources, _):
            support(resources)
        }
    }

    /// The ordinary receipt.
    private func received(_ receipt: ReportReceipt) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: "checkmark.shield.fill",
                title: SafetyCopy.reportReceivedTitle,
                subtitle: SafetyCopy.reportReceivedBody(id: receipt.id),
                tint: SLColor.secondary
            )

            Text(SafetyCopy.reportIsSilent)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            nextSteps

            SLButton(
                "Done",
                variant: .primary,
                accessibilityHint: "Closes this screen",
                action: { viewModel.close() }
            )
        }
    }

    /// The care-first outcome.
    ///
    /// Everything about this screen is upside down compared with the receipt.
    /// The resources come first and the reference number is not mentioned at
    /// all; the follow-up actions are phrased as permission to step back rather
    /// than as the obvious next thing to do; and there is no auto-dismiss,
    /// because the person reading it may be copying a phone number down.
    private func support(_ resources: SupportResources?) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(SLColor.secondary)
                    .accessibilityHidden(true)

                Text(resources?.title ?? SafetyCopy.supportTitle)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(resources?.message ?? SafetyCopy.supportFallbackMessage)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            // No numbers are invented when the server sends none. This client
            // does not know which country the person in trouble is in, and a
            // helpline made up on the device is a wrong number handed to
            // somebody in an emergency. The server owns that list; without it
            // the honest screen is the message above and nothing more.
            if let rows = resources?.resources, !rows.isEmpty {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    ForEach(rows) { resource in
                        resourceRow(resource)
                    }
                }
            }

            Text(SafetyCopy.supportPrivacy)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(SafetyCopy.supportNextSteps)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            softNextSteps

            SLButton(
                "Done",
                variant: .primary,
                accessibilityHint: "Closes this screen",
                action: { viewModel.close() }
            )
        }
    }

    private func resourceRow(_ resource: SupportResource) -> some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text(resource.name)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = resource.detail {
                    Text(detail)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: SLSpacing.lg) {
                    if let phone = resource.phone {
                        // The number is rendered exactly as the server sent it.
                        // A `tel:` link is offered when it can be built, and the
                        // text stays selectable either way — somebody may be
                        // passing it to a person on another phone.
                        if let dialable = Self.telURL(phone) {
                            Link(destination: dialable) {
                                Label(phone, systemImage: "phone.fill")
                                    .font(SLFont.bodyEmphasis)
                                    .foregroundStyle(SLColor.secondary)
                            }
                            .accessibilityLabel(Text("Call \(resource.name) on \(phone)"))
                        } else {
                            Text(phone)
                                .font(SLFont.mono)
                                .foregroundStyle(SLColor.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    if let url = resource.url {
                        Link(destination: url) {
                            Label("Open", systemImage: "arrow.up.right.square")
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.primary)
                        }
                        .accessibilityLabel(Text("Open \(resource.name)"))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    /// The two follow-ups on the receipt screen — offered plainly.
    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text("If you would rather not see them")
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)

            SLButton(
                "Mute \(viewModel.target.atHandle)",
                variant: .secondary,
                size: .compact,
                accessibilityHint: SafetyCopy.muteEffect + " " + SafetyCopy.muteIsSilent,
                action: { viewModel.muteFromOutcome() }
            )

            SLButton(
                "Block \(viewModel.target.atHandle)…",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Asks you to confirm first, and says what a block removes.",
                action: { viewModel.blockFromOutcome() }
            )
        }
    }

    /// The same two follow-ups on the care screen, deliberately quieter.
    ///
    /// Mute leads, block is a ghost button underneath, and the heading gives
    /// permission rather than instruction. Somebody who has just reported a
    /// friend for self-harm should not be nudged into cutting contact with them.
    private var softNextSteps: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            SLButton(
                "Mute \(viewModel.target.atHandle)",
                variant: .secondary,
                size: .compact,
                accessibilityHint: SafetyCopy.muteEffect + " " + SafetyCopy.muteIsSilent,
                action: { viewModel.muteFromOutcome() }
            )

            SLButton(
                "Block \(viewModel.target.atHandle)…",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Asks you to confirm first, and says what a block removes.",
                action: { viewModel.blockFromOutcome() }
            )
        }
    }

    /// `tel:` for a number the server sent, or `nil` when it is not dialable.
    ///
    /// Only digits and a leading `+` survive, and nothing is added: a helpline
    /// number is not somewhere a client should be creative.
    nonisolated static func telURL(_ phone: String) -> URL? {
        var digits = phone.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") {
            digits = "+" + digits
        }
        return URL(string: "tel:\(digits)")
    }
}

#Preview("Report — reason picker") {
    NavigationStack {
        ReportSheet(
            viewModel: ReportViewModel(
                subject: ReportSubject(post: FeedServiceMock.internationalRoot),
                service: SafetyServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            )
        )
    }
    .preferredColorScheme(.dark)
}
