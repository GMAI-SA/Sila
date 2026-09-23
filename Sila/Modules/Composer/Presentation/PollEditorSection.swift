import SwiftUI

/// The composer's poll: two to four options, how long it runs, and when the
/// counts show. The post's text is the question, so there is no question field.
@MainActor
struct PollEditorSection: View {

    @Bindable var viewModel: ComposerViewModel

    var body: some View {
        if let poll = viewModel.poll {
            SLCard {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    HStack {
                        Label(L10n.t("poll.editor.title"), systemImage: "chart.bar")
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                        Spacer(minLength: 0)
                        Button(L10n.t("poll.editor.remove")) { viewModel.removePoll() }
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .accessibilityIdentifier("composer.poll.remove")
                    }

                    ForEach(poll.options.indices, id: \.self) { index in
                        optionField(index, poll: poll)
                    }

                    if poll.canAddOption {
                        Button {
                            viewModel.poll?.options.append("")
                        } label: {
                            Label(L10n.t("poll.editor.addOption"), systemImage: "plus.circle")
                                .font(SLFont.caption)
                        }
                        .accessibilityIdentifier("composer.poll.addOption")
                    }

                    Picker(L10n.t("poll.editor.duration"), selection: Binding(
                        get: { viewModel.poll?.duration ?? .oneDay },
                        set: { viewModel.poll?.duration = $0 }
                    )) {
                        ForEach(PollDraft.Duration.allCases) { duration in
                            Text(duration.title).tag(duration)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(L10n.t("poll.editor.results"), selection: Binding(
                        get: { viewModel.poll?.visibility ?? .afterVote },
                        set: { viewModel.poll?.visibility = $0 }
                    )) {
                        ForEach(PollResultsVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .pickerStyle(.menu)

                    if let problem = poll.problem, poll.trimmed.contains(where: { !$0.isEmpty }) {
                        Text(problem)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.warning)
                    }

                    Text(L10n.t("poll.anonymous"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t("poll.editor.whoVotes"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func optionField(_ index: Int, poll: PollDraft) -> some View {
        HStack(spacing: SLSpacing.sm) {
            TextField(
                L10n.t("poll.editor.option", SLFormat.number(index + 1)),
                text: Binding(
                    get: { viewModel.poll?.options[safe: index] ?? "" },
                    set: { value in
                        guard viewModel.poll?.options.indices.contains(index) == true else { return }
                        viewModel.poll?.options[index] = String(value.prefix(PollDraft.maxOptionLength))
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("composer.poll.option.\(index)")

            if poll.canRemoveOption {
                Button {
                    viewModel.poll?.options.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("poll.editor.removeOption", SLFormat.number(index + 1))))
            }
        }
    }
}

/// Starter phrases above an empty composer.
struct ComposerStartersRow: View {
    let starters: [ComposerStarter]
    let onUse: (ComposerStarter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SLSpacing.sm) {
                ForEach(starters) { starter in
                    Button {
                        onUse(starter)
                    } label: {
                        HStack(spacing: SLSpacing.xs) {
                            if starter.kind == .poll {
                                Image(systemName: "chart.bar").accessibilityHidden(true)
                            }
                            Text(starter.phrase().trimmingCharacters(in: .whitespaces))
                                .lineLimit(1)
                        }
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                        .padding(.horizontal, SLSpacing.md)
                        .padding(.vertical, SLSpacing.sm)
                        .background(Capsule().fill(SLColor.surface1))
                        .overlay(Capsule().strokeBorder(SLColor.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(L10n.t("composer.starters.hint")))
                    .accessibilityIdentifier("composer.starter.\(starter.id)")
                }
            }
        }
        .accessibilityLabel(Text(L10n.t("composer.starters.a11yLabel")))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
