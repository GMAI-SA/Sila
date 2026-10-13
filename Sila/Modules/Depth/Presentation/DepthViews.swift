import SwiftUI

// MARK: - Reactions

/// How a qualitative reaction is sent, from wherever a post is drawn.
public struct ReactionActions {
    public var set: @MainActor (_ kind: ReactionKind, _ on: Bool, _ postId: UUID) async throws -> PostMetrics

    public init(set: @escaping @MainActor (_ kind: ReactionKind, _ on: Bool, _ postId: UUID) async throws -> PostMetrics) {
        self.set = set
    }
}

private struct ReactionActionsKey: EnvironmentKey {
    static let defaultValue: ReactionActions? = nil
}

extension EnvironmentValues {
    public var reactionActions: ReactionActions? {
        get { self[ReactionActionsKey.self] }
        set { self[ReactionActionsKey.self] = newValue }
    }
}

/// The "+" that opens the four reactions, and the counted chips under a
/// card. Never a list of who reacted.
@MainActor
struct ReactionControls: View {
    let post: Post
    @Environment(\.reactionActions) private var actions
    @State private var metrics: PostMetrics?
    @State private var mine: Set<String>?
    @State private var error: String?

    private var counts: PostMetrics { metrics ?? post.metrics }
    private var chosen: Set<String> { mine ?? Set(post.viewer.reactions) }

    /// The picker button, placed beside Like.
    var picker: some View {
        Menu {
            ForEach(ReactionKind.allCases) { kind in
                Button {
                    Task { await toggle(kind) }
                } label: {
                    Label(kind.title, systemImage: chosen.contains(kind.rawValue) ? "checkmark" : kind.icon)
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(SLColor.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(actions == nil || post.viewer.isAuthor)
        .accessibilityLabel(Text(L10n.t("reaction.picker.a11yLabel")))
        .accessibilityIdentifier("post.reactions")
    }

    /// The chips with a count, only for reactions somebody has given.
    var body: some View {
        let shown = ReactionKind.allCases.filter { counts.count(for: $0) > 0 }
        if !shown.isEmpty || error != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SLSpacing.xs) {
                    ForEach(shown) { kind in
                        Button {
                            Task { await toggle(kind) }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: kind.icon)
                                Text(SLFormat.compactCount(counts.count(for: kind))).monospacedDigit()
                            }
                            .font(SLFont.micro)
                            .foregroundStyle(chosen.contains(kind.rawValue) ? SLColor.primary : SLColor.textSecondary)
                            .padding(.horizontal, SLSpacing.sm)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(chosen.contains(kind.rawValue) ? SLColor.primary.opacity(0.15) : SLColor.surface1))
                        }
                        .buttonStyle(.plain)
                        .disabled(actions == nil || post.viewer.isAuthor)
                        .accessibilityLabel(Text(L10n.t("reaction.chip.a11yLabel", kind.title, SLFormat.number(counts.count(for: kind)))))
                    }
                }
                if let error {
                    Text(error).font(SLFont.micro).foregroundStyle(SLColor.danger)
                }
            }
        }
    }

    private func toggle(_ kind: ReactionKind) async {
        guard let actions else { return }
        let on = !chosen.contains(kind.rawValue)
        do {
            metrics = try await actions.set(kind, on, post.id)
            var next = chosen
            if on { next.insert(kind.rawValue) } else { next.remove(kind.rawValue) }
            mine = next
            error = nil
        } catch {
            let wrapped = APIError.wrapping(error)
            if !wrapped.isCancellation { self.error = wrapped.userMessage }
        }
    }
}

// MARK: - Room depth

/// The pinned question, on the stage for everyone.
struct PinnedQuestionBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: SLSpacing.sm) {
            Image(systemName: "pin.fill").foregroundStyle(SLColor.warning).accessibilityHidden(true)
            Text(text)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: text))
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous).fill(SLColor.warning.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("rooms.questions.pinned.a11yLabel", text)))
    }
}

/// The question queue: ask, upvote, and — on the stage — pin, answer, dismiss.
@MainActor
struct QuestionQueueView: View {
    @Bindable var viewModel: RoomDepthViewModel
    var hostName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            if viewModel.viewerIsVouched {
                // Where the field would be, the reason it is not (contract
                // v24 §4): a vouched listener reads the queue, and asks once
                // they have verified.
                Text(L10n.t("vouch.limited.rooms"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rooms.questions.vouched")
            } else {
                HStack(spacing: SLSpacing.sm) {
                    TextField(hostName.map { L10n.t("rooms.questions.askHost", $0) } ?? L10n.t("rooms.questions.ask"),
                              text: $viewModel.askDraft, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("rooms.questions.field")
                    Button(L10n.t("rooms.questions.send")) { Task { await viewModel.ask() } }
                        .disabled(!viewModel.canAsk)
                        .accessibilityIdentifier("rooms.questions.send")
                }
            }

            // The viewer's own question, the moment it was sent: never a
            // field that empties into nothing while the server thinks.
            ForEach(viewModel.pendingQuestions) { pending in
                pendingRow(pending)
            }

            if viewModel.questions.isEmpty && viewModel.pendingQuestions.isEmpty {
                Text(L10n.t("rooms.questions.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            }
            ForEach(viewModel.questions) { question in
                row(question)
            }
            if !viewModel.answered.isEmpty {
                Text(L10n.t("rooms.questions.answered"))
                    .font(SLFont.micro)
                    .slTracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)
                ForEach(viewModel.answered) { question in
                    Label(question.text, systemImage: "checkmark.circle")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
        }
    }

    private func pendingRow(_ pending: RoomDepthViewModel.PendingQuestion) -> some View {
        HStack(alignment: .top, spacing: SLSpacing.md) {
            Group {
                if pending.state == .sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(SLColor.danger)
                }
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.text)
                    .font(SLFont.body)
                    .foregroundStyle(pending.state == .sending ? SLColor.textSecondary : SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: pending.text))
                switch pending.state {
                case .sending:
                    Text(L10n.t("rooms.questions.sending")).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                case let .failed(reason):
                    Text(reason).font(SLFont.micro).foregroundStyle(SLColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: SLSpacing.md) {
                        Button(L10n.t("rooms.questions.retry")) { Task { await viewModel.retry(pending) } }
                            .font(SLFont.caption)
                            .accessibilityIdentifier("rooms.questions.retry")
                        Button(L10n.t("rooms.questions.discard"), role: .destructive) { viewModel.discard(pending) }
                            .font(SLFont.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rooms.questions.pending")
    }

    private func row(_ question: RoomQuestion) -> some View {
        HStack(alignment: .top, spacing: SLSpacing.md) {
            Button {
                Task { await viewModel.toggleUpvote(question) }
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: question.viewerUpvoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                    Text(SLFormat.number(question.upvoteCount)).font(SLFont.micro).monospacedDigit()
                }
                .foregroundStyle(question.viewerUpvoted ? SLColor.primary : SLColor.textSecondary)
                .frame(width: 36)
            }
            .buttonStyle(.plain)
            .disabled(question.isAuthor || !viewModel.canTakePart)
            .accessibilityLabel(Text(L10n.t("rooms.questions.upvote.a11yLabel", SLFormat.number(question.upvoteCount))))

            VStack(alignment: .leading, spacing: 2) {
                if question.pinned {
                    Label(L10n.t("rooms.questions.onStage"), systemImage: "pin.fill")
                        .font(SLFont.micro).foregroundStyle(SLColor.warning)
                }
                Text(question.text)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: question.text))
                if let author = question.author {
                    Text(author.atHandle).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                        .slContentDirection(.leftToRight)
                }
            }
            Spacer(minLength: 0)
            if viewModel.isStage || question.isAuthor {
                Menu {
                    if viewModel.isStage {
                        Button(L10n.t(question.pinned ? "rooms.questions.unpin" : "rooms.questions.pin")) {
                            Task { await viewModel.stage(question.pinned ? "unpin" : "pin", question) }
                        }
                        Button(L10n.t("rooms.questions.markAnswered")) { Task { await viewModel.stage("answer", question) } }
                        Button(L10n.t("rooms.questions.dismiss"), role: .destructive) { Task { await viewModel.stage("dismiss", question) } }
                    }
                    if question.isAuthor {
                        Button(L10n.t("rooms.questions.withdraw"), role: .destructive) { Task { await viewModel.withdraw(question) } }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .accessibilityLabel(Text(L10n.t("rooms.questions.menu.a11yLabel")))
            }
        }
    }
}

/// A room poll: vote, watch the tally, and on the stage close it.
///
/// The viewer's own choice is drawn chosen the moment it is tapped (filled
/// bar, tick, "You voted"), the bars and the total move as the room votes,
/// and a vote from somebody else gives the total a small pulse — so it is
/// always clear that something happened, and what.
@MainActor
struct RoomPollCard: View {
    let poll: RoomPoll
    let isStage: Bool
    /// `false` for a vouched listener: the tally, never the vote.
    var canTakePart = true
    /// The option this viewer chose, including a tap still on its way.
    var chosen: UUID?
    let onVote: (PollOption) -> Void
    let onClose: () -> Void

    @State private var pulse = false

    private var isOpen: Bool { !poll.poll.isClosed() }
    private var canVote: Bool { poll.poll.canVote && canTakePart && chosen == nil && isOpen }

    var body: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(poll.question).font(SLFont.bodyEmphasis).foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: poll.question))
                    Spacer(minLength: 0)
                    if isOpen {
                        Label(L10n.t("rooms.status.live"), systemImage: "dot.radiowaves.left.and.right")
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.danger)
                            .labelStyle(.iconOnly)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(poll.poll.options) { option in
                    optionRow(option)
                }
                HStack(spacing: SLSpacing.xs) {
                    if chosen != nil {
                        Label(L10n.t("rooms.polls.youVoted"), systemImage: "checkmark.seal.fill")
                            .font(SLFont.micro.weight(.semibold))
                            .foregroundStyle(SLColor.primary)
                            .accessibilityIdentifier("rooms.polls.youVoted")
                    }
                    Text(PollCopy.footer(poll.poll))
                        .font(SLFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(pulse ? SLColor.primary : SLColor.textMuted)
                        .scaleEffect(pulse ? 1.08 : 1, anchor: .leading)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    if isStage, isOpen {
                        Button(L10n.t("rooms.polls.close"), action: onClose).font(SLFont.caption)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: poll.poll)
        .animation(.easeOut(duration: 0.2), value: chosen)
        .onChange(of: poll.poll.totalVotes) { old, new in
            guard new > old else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pulse = true }
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                withAnimation(.easeOut(duration: 0.3)) { pulse = false }
            }
        }
    }

    private func optionRow(_ option: PollOption) -> some View {
        let share = poll.poll.share(of: option) ?? 0
        let mine = chosen == option.id
        return Button { onVote(option) } label: {
            HStack(spacing: SLSpacing.sm) {
                Text(option.text)
                    .font(mine ? SLFont.bodyEmphasis : SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                if mine {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SLColor.primary)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if let votes = option.votes, poll.poll.resultsVisible {
                    Text(SLFormat.number(votes))
                        .font(SLFont.micro).monospacedDigit()
                        .foregroundStyle(SLColor.textMuted)
                        .contentTransition(.numericText())
                }
                Text(share.formatted(.percent.precision(.fractionLength(0)).locale(L10n.formattingLocale)))
                    .font(SLFont.caption).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, SLSpacing.md)
            .frame(minHeight: 40)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: SLRadius.md)
                        .fill(SLColor.primary.opacity(mine ? 0.32 : 0.14))
                        .frame(width: max(0, geo.size.width * share))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .strokeBorder(mine ? SLColor.primary : SLColor.stroke, lineWidth: mine ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canVote)
        .accessibilityLabel(Text(option.text))
        .accessibilityValue(Text(share.formatted(.percent.precision(.fractionLength(0)).locale(L10n.formattingLocale))))
        .accessibilityAddTraits(mine ? .isSelected : [])
    }
}

/// Opening a room poll: a question, two to four options, how long.
@MainActor
struct RoomPollComposer: View {
    let onOpen: (String, [String], Int) async -> Bool
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var minutes = 5
    /// One tap, one poll: the button waits for the answer.
    @State private var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            TextField(L10n.t("rooms.polls.question"), text: $question).textFieldStyle(.roundedBorder)
            ForEach(options.indices, id: \.self) { i in
                TextField(L10n.t("poll.editor.option", SLFormat.number(i + 1)), text: Binding(
                    get: { options[safe: i] ?? "" },
                    set: { if options.indices.contains(i) { options[i] = String($0.prefix(40)) } }
                ))
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                if options.count < 4 {
                    Button(L10n.t("poll.editor.addOption")) { options.append("") }.font(SLFont.caption)
                }
                Spacer(minLength: 0)
                Stepper(L10n.t("rooms.polls.minutes", SLFormat.number(minutes)), value: $minutes, in: 1...30)
                    .font(SLFont.caption)
            }
            SLButton(L10n.t("rooms.polls.open"), isLoading: isOpening) {
                guard !isOpening else { return }
                isOpening = true
                Task {
                    if await onOpen(question, options, minutes * 60) {
                        question = ""
                        options = ["", ""]
                    }
                    isOpening = false
                }
            }
            .disabled(isOpening)
            .accessibilityIdentifier("rooms.polls.open")
        }
    }
}

/// Questions, polls and (for the host) co-hosts, in one sheet.
@MainActor
public struct RoomDepthSheet: View {
    public enum Tab: String, CaseIterable, Identifiable { case questions, polls, cohosts; public var id: String { rawValue } }

    @Bindable var viewModel: RoomDepthViewModel
    let candidates: [UserSummary]
    let hostName: String?
    let onClose: () -> Void
    @State private var tab: Tab = .questions

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    Picker("", selection: $tab) {
                        Text(L10n.t("rooms.depth.questions")).tag(Tab.questions)
                        Text(L10n.t("rooms.depth.polls")).tag(Tab.polls)
                        if viewModel.isHost { Text(L10n.t("rooms.depth.cohosts")).tag(Tab.cohosts) }
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case .questions:
                        QuestionQueueView(viewModel: viewModel, hostName: hostName)
                    case .polls:
                        if viewModel.isStage, viewModel.openPoll == nil {
                            RoomPollComposer { q, o, d in await viewModel.openPoll(question: q, options: o, durationSeconds: d) }
                        }
                        if viewModel.polls.isEmpty {
                            Text(L10n.t("rooms.polls.empty")).font(SLFont.caption).foregroundStyle(SLColor.textMuted)
                        } else if !viewModel.canTakePart {
                            // The tally, and why there is no vote in it.
                            Text(L10n.t("poll.blocked.selfVerify"))
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textSecondary)
                                .accessibilityIdentifier("rooms.polls.vouched")
                        }
                        ForEach(viewModel.polls) { poll in
                            RoomPollCard(poll: poll, isStage: viewModel.isStage, canTakePart: viewModel.canTakePart,
                                         chosen: viewModel.chosenOption(in: poll),
                                         onVote: { option in Task { await viewModel.vote(option, in: poll) } },
                                         onClose: { Task { await viewModel.close(poll) } })
                        }
                    case .cohosts:
                        cohosts
                    }
                }
                .padding(SLSpacing.lg)
            }
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("rooms.depth.title"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.t("common.done")) { onClose() } } }
            .tnToast($viewModel.toast)
            .task { await viewModel.load() }
            .animation(.easeOut(duration: 0.2), value: viewModel.pendingQuestions)
        }
        .tint(SLColor.primary)
    }

    @ViewBuilder
    private var cohosts: some View {
        Text(L10n.t("rooms.cohosts.explanation"))
            .font(SLFont.caption).foregroundStyle(SLColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        ForEach(viewModel.cohosts, id: \.id) { user in
            HStack {
                Text(user.displayName).font(SLFont.body)
                Text(user.atHandle).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    .slContentDirection(.leftToRight)
                Spacer(minLength: 0)
                Button(L10n.t("rooms.cohosts.remove"), role: .destructive) { Task { await viewModel.removeCohost(user.handle) } }
                    .font(SLFont.caption)
            }
        }
        if viewModel.cohosts.count < RoomDepthViewModel.maxCohosts {
            let others = candidates.filter { !viewModel.isCohost($0) }
            if !others.isEmpty {
                Text(L10n.t("rooms.cohosts.add")).font(SLFont.micro).slTracking(0.8).foregroundStyle(SLColor.textSecondary)
                ForEach(others, id: \.id) { user in
                    Button {
                        Task { await viewModel.addCohost(user.handle) }
                    } label: {
                        HStack {
                            Text(user.displayName).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle").foregroundStyle(SLColor.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Guidelines and muted words

@MainActor
public struct GuidelinesSheet: View {
    @Bindable var gate: GuidelinesGate
    /// Set when the sheet stands before a first post: Accept, then post.
    let onAccept: (() -> Void)?
    let onClose: () -> Void

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    if let guidelines = gate.guidelines {
                        ForEach(guidelines.sections) { section in
                            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                                Text(section.localizedTitle()).font(SLFont.bodyEmphasis).foregroundStyle(SLColor.textPrimary)
                                Text(section.localizedBody()).font(SLFont.body).foregroundStyle(SLColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if gate.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let error = gate.error {
                        Text(error).font(SLFont.caption).foregroundStyle(SLColor.danger)
                    }
                    if let onAccept {
                        SLButton(L10n.t("guidelines.accept")) {
                            Task { if await gate.accept() { onAccept() } }
                        }
                        .accessibilityIdentifier("guidelines.accept")
                    }
                }
                .padding(SLSpacing.lg)
            }
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("guidelines.title"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.t(onAccept == nil ? "common.done" : "common.cancel")) { onClose() } } }
            .task { await gate.load() }
        }
        .tint(SLColor.primary)
    }
}

private struct GuidelinesGateKey: EnvironmentKey {
    static let defaultValue: GuidelinesGate? = nil
}

extension EnvironmentValues {
    /// The guidelines, for the link on every report sheet.
    public var guidelinesGate: GuidelinesGate? {
        get { self[GuidelinesGateKey.self] }
        set { self[GuidelinesGateKey.self] = newValue }
    }
}

/// "Read the community guidelines" — on every report sheet.
struct GuidelinesLink: View {
    @Environment(\.guidelinesGate) private var gate
    @State private var isShowing = false

    var body: some View {
        if let gate {
            Button(L10n.t("guidelines.link")) { isShowing = true }
                .font(SLFont.caption)
                .foregroundStyle(SLColor.primary)
                .sheet(isPresented: $isShowing) {
                    GuidelinesSheet(gate: gate, onAccept: nil, onClose: { isShowing = false })
                }
                .accessibilityIdentifier("guidelines.link")
        }
    }
}

@MainActor
public struct MutedTermsScreen: View {
    @Bindable var viewModel: MutedTermsViewModel

    public var body: some View {
        List {
            Section {
                HStack {
                    TextField(L10n.t("mutedTerms.placeholder"), text: $viewModel.draft)
                        .accessibilityIdentifier("mutedTerms.field")
                    Button(L10n.t("mutedTerms.add")) { Task { await viewModel.add() } }
                        .disabled(!viewModel.canAdd)
                }
            } footer: {
                Text(L10n.t("mutedTerms.explanation"))
            }
            Section {
                ForEach(viewModel.terms) { term in
                    Text(term.term)
                        .swipeActions {
                            Button(L10n.t("mutedTerms.remove"), role: .destructive) { Task { await viewModel.remove(term) } }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("mutedTerms.title"))
        .tnToast($viewModel.toast)
        .task { await viewModel.load() }
    }
}
