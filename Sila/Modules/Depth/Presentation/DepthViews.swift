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

            if viewModel.questions.isEmpty {
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
                    .tracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)
                ForEach(viewModel.answered) { question in
                    Label(question.text, systemImage: "checkmark.circle")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
        }
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
            .disabled(question.isAuthor)
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
@MainActor
struct RoomPollCard: View {
    let poll: RoomPoll
    let isStage: Bool
    let onVote: (PollOption) -> Void
    let onClose: () -> Void

    var body: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(poll.question).font(SLFont.bodyEmphasis).foregroundStyle(SLColor.textPrimary)
                ForEach(poll.poll.options) { option in
                    let share = poll.poll.share(of: option) ?? 0
                    Button { onVote(option) } label: {
                        HStack {
                            Text(option.text).font(SLFont.body)
                            if poll.poll.viewerOptionId == option.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(SLColor.primary)
                            }
                            Spacer(minLength: 0)
                            Text(share.formatted(.percent.precision(.fractionLength(0)).locale(L10n.formattingLocale)))
                                .font(SLFont.caption).monospacedDigit()
                        }
                        .padding(.horizontal, SLSpacing.md)
                        .frame(minHeight: 36)
                        .background(alignment: .leading) {
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.primary.opacity(0.15))
                                    .frame(width: geo.size.width * share)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!poll.poll.canVote)
                }
                HStack {
                    Text(PollCopy.footer(poll.poll)).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    Spacer(minLength: 0)
                    if isStage, !poll.poll.isClosed() {
                        Button(L10n.t("rooms.polls.close"), action: onClose).font(SLFont.caption)
                    }
                }
            }
        }
    }
}

/// Opening a room poll: a question, two to four options, how long.
@MainActor
struct RoomPollComposer: View {
    let onOpen: (String, [String], Int) async -> Bool
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var minutes = 5

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
            SLButton(L10n.t("rooms.polls.open")) {
                Task {
                    if await onOpen(question, options, minutes * 60) {
                        question = ""
                        options = ["", ""]
                    }
                }
            }
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
                        }
                        ForEach(viewModel.polls) { poll in
                            RoomPollCard(poll: poll, isStage: viewModel.isStage,
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
                Spacer(minLength: 0)
                Button(L10n.t("rooms.cohosts.remove"), role: .destructive) { Task { await viewModel.removeCohost(user.handle) } }
                    .font(SLFont.caption)
            }
        }
        if viewModel.cohosts.count < RoomDepthViewModel.maxCohosts {
            let others = candidates.filter { !viewModel.isCohost($0) }
            if !others.isEmpty {
                Text(L10n.t("rooms.cohosts.add")).font(SLFont.micro).tracking(0.8).foregroundStyle(SLColor.textSecondary)
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
