import MediaPlayer
import SwiftUI
import UIKit

/// Inside a room: the stage, the hands, the audience, and the one control that
/// matters for whoever is holding the phone.
///
/// **The screen joins.** It is pushed the moment a room is tapped and does the
/// join under a connecting header; a door that does not open is a state here,
/// with the reason and a way back — never a spinner on the list behind.
///
/// **The microphone is drawn only when it can work**, gated on the role the
/// server's token granted. A listener gets a hand to raise instead, and only
/// when the room's own rule could ever let them speak.
///
/// **The host sees the hands as a queue** — oldest first, with Approve and a
/// quieter Lower — and has Mute, Move to listeners, Remove (with an undo) on
/// every row. Running a room and protecting yourself in one are different
/// jobs, so the host menu and the safety menu stay separate controls.
///
/// **Leaving does both halves, on every exit path.**
@MainActor
public struct LiveRoomScreen: View {

    @Bindable private var viewModel: LiveRoomViewModel
    private let onLeave: @MainActor () -> Void
    /// Back to the app with the room still on — `nil` where there is no
    /// app to go back to (a preview).
    private let onMinimise: (@MainActor () -> Void)?
    private let onOpenProfile: (@MainActor (String) -> Void)?
    /// The person whose sheet is up. A tap on a tile opens this, never the
    /// profile directly — a thumb brushing the audience grid used to navigate.
    @State private var selected: ParticipantSelection?
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isManagingInvites = false

    private let stageColumns = [GridItem(.adaptive(minimum: 84), spacing: SLSpacing.md)]
    private let audienceColumns = [GridItem(.adaptive(minimum: 64), spacing: SLSpacing.sm)]

    public init(
        viewModel: LiveRoomViewModel,
        onLeave: @escaping @MainActor () -> Void,
        onMinimise: (@MainActor () -> Void)? = nil,
        onOpenProfile: (@MainActor (String) -> Void)? = nil,
        safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)? = nil,
        onReport: (@MainActor (ReportSubject) -> Void)? = nil,
        onVerifySelf: (@MainActor () -> Void)? = nil
    ) {
        self.onReport = onReport
        self.onVerifySelf = onVerifySelf
        self.viewModel = viewModel
        self.onLeave = onLeave
        self.onMinimise = onMinimise
        self.onOpenProfile = onOpenProfile
        self.safetyMenu = safetyMenu
    }

    private let onReport: (@MainActor (ReportSubject) -> Void)?
    /// A vouched listener's own verification, from where the room says what
    /// waits for it. `nil` offers the sentence alone.
    private let onVerifySelf: (@MainActor () -> Void)?
    @Environment(\.recognitionService) private var recognition

    public var body: some View {
        Group {
            if case let .refused(reason) = viewModel.phase {
                refused(reason)
            } else {
                inRoom
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .navigationBarBackButtonHidden(true)
        .tnNavigationBar(title: L10n.t("rooms.live.nav.title"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onMinimise, viewModel.phase == .inRoom || viewModel.phase == .joining {
                    // The way back to the app is not the way out of the room:
                    // this keeps the room on (the bar above the tabs brings it
                    // back); Leave, in the controls below, is the only exit.
                    Button {
                        onMinimise()
                    } label: {
                        Label(L10n.t("rooms.live.minimise"), systemImage: "chevron.down")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.live.minimise")))
                    .accessibilityHint(Text(L10n.t("rooms.live.minimise.a11yHint")))
                    .accessibilityIdentifier("rooms.live.minimise")
                } else {
                    Button {
                        // A host is asked what they mean; everybody else just goes.
                        guard viewModel.requestLeave() else { return }
                        Task {
                            await viewModel.leave()
                            onLeave()
                        }
                    } label: {
                        Label(L10n.t("rooms.live.leave"), systemImage: "chevron.backward")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.live.leave.a11yLabel")))
                    .accessibilityHint(Text(RoomCopy.leaveHint))
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.toggleLike() }
                } label: {
                    Label(
                        SLFormat.compactCount(viewModel.room.metrics.likes),
                        systemImage: viewModel.room.viewerLiked ? "heart.fill" : "heart"
                    )
                    .foregroundStyle(viewModel.room.viewerLiked ? SLColor.danger : SLColor.primary)
                }
                .accessibilityLabel(Text(
                    viewModel.room.viewerLiked ? L10n.t("rooms.like.undo.a11yLabel") : L10n.t("rooms.like.a11yLabel")
                ))
            }

            // A room is never recorded; putting it on a timeline is the only
            // way it is referred to after it ends. Closed rooms are absent —
            // advertising one is how an invite-only room would leak — and so
            // is a vouched listener's share, which waits for verification.
            //
            // The link goes anywhere the phone can send it (WhatsApp,
            // Messages, X, Telegram, Copy…); the post stays the timeline's.
            if viewModel.canShare || RoomShareContent.canShareLink(viewModel.room) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if RoomShareContent.canShareLink(viewModel.room) {
                            RoomShareLink(room: viewModel.room, showsTitle: true)
                        }
                        if viewModel.canShare {
                            Button {
                                viewModel.isSharing = true
                            } label: {
                                Label(L10n.t("rooms.shareLink.post"), systemImage: "text.bubble")
                            }
                            .accessibilityHint(Text(L10n.t("rooms.share.a11yHint")))
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.share.a11yLabel")))
                    .accessibilityIdentifier("rooms.share.menu")
                }
            }

            if viewModel.depth != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isDepthOpen = true
                    } label: {
                        Image(systemName: "questionmark.bubble")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.depth.title")))
                    .accessibilityIdentifier("rooms.depth.open")
                }
            }

            // The room's menu: its settings for the host and co-hosts
            // (contract v31), reporting for everybody but the host.
            if viewModel.canManageRoom || (onReport != nil && !viewModel.isHost) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if viewModel.canManageRoom {
                            Button {
                                viewModel.isShowingSettings = true
                            } label: {
                                Label(L10n.t("rooms.settings.title"), systemImage: "slider.horizontal.3")
                            }
                            .accessibilityIdentifier("room.settings")
                        }
                        if let onReport, !viewModel.isHost {
                            Button(role: .destructive) {
                                onReport(.room(id: viewModel.room.id, host: SafetyTarget(user: viewModel.room.host),
                                               title: viewModel.room.title))
                            } label: {
                                Label(L10n.t("rooms.report"), systemImage: "flag")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(viewModel.canManageRoom ? L10n.t("rooms.settings.title") : L10n.t("rooms.report")))
                    .accessibilityIdentifier("room.menu")
                }
            }

            if viewModel.isHost && viewModel.room.isClosed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isManagingInvites = true
                    } label: {
                        Label(L10n.t("rooms.invites.title"), systemImage: "person.badge.plus")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.invites.title")))
                    .accessibilityHint(Text(L10n.t("rooms.invites.open.a11yHint")))
                }
            }
        }
        .sheet(isPresented: $viewModel.isDepthOpen) {
            if let depth = viewModel.depth {
                RoomDepthSheet(
                    viewModel: depth,
                    candidates: (viewModel.speakers + viewModel.listeners).map(\.user)
                        .filter { $0.id != viewModel.room.host.id },
                    hostName: viewModel.room.isAMA ? viewModel.room.host.displayName : nil,
                    onClose: { viewModel.isDepthOpen = false }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            RoomSettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isSharing) {
            ShareRoomSheet(
                room: viewModel.room,
                onShare: { text in await viewModel.share(text: text) },
                onClose: { viewModel.isSharing = false }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isManagingInvites) {
            RoomInvitesSheet(
                viewModel: viewModel.makeInvitesViewModel(),
                onClose: { isManagingInvites = false }
            )
        }
        .sheet(item: $selected) { selection in
            participantSheet(for: selection)
        }
        .sheet(isPresented: $viewModel.isChatOpen) {
            roomChat
        }
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { _, phase in
            // With no app around it (a preview), the screen keeps the room
            // through the background itself; inside the app the room's
            // session above the tabs does, whether or not this is on screen.
            guard onMinimise == nil else { return }
            switch phase {
            case .background: Task { await viewModel.persistThroughBackgrounding() }
            case .active: Task { await viewModel.resumeFromBackground() }
            default: break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
        ) { _ in
            guard onMinimise == nil else { return }
            Task { await viewModel.handleTermination() }
        }
        .onChange(of: viewModel.hasLeft) { _, hasLeft in
            if hasLeft { onLeave() }
        }
        // A vote or a close that failed from the poll on the room's own
        // screen: said here, where the sheet's banner is not up.
        .onChange(of: viewModel.depth?.toast) { _, message in
            guard let message, !viewModel.isDepthOpen else { return }
            viewModel.toast = message
            viewModel.depth?.toast = nil
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.depth?.openPoll?.id)
        // Questions and votes, felt — here once, for the sheet above as well.
        .sensoryFeedback(.selection, trigger: viewModel.depth?.selectionBeats ?? 0)
        .sensoryFeedback(.success, trigger: viewModel.depth?.successBeats ?? 0)
        .sensoryFeedback(.error, trigger: viewModel.depth?.failureBeats ?? 0)
        // The host's Leave means one of two different things, and only they
        // know which. Asked here rather than guessed.
        .confirmationDialog(
            Text(L10n.t("rooms.live.leaveAsHost.title")),
            isPresented: $viewModel.isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button(L10n.t("rooms.live.end.confirmButton"), role: .destructive) {
                Task { await viewModel.endRoom() }
            }
            Button(L10n.t("rooms.live.leaveRunning")) {
                Task {
                    await viewModel.leaveRunning()
                    onLeave()
                }
            }
            Button(L10n.t("rooms.live.end.cancelButton"), role: .cancel) {
                viewModel.isConfirmingLeave = false
            }
        } message: {
            Text(L10n.t("rooms.live.leaveAsHost.message"))
        }
        .confirmationDialog(
            Text(L10n.t("rooms.live.end.confirmTitle")),
            isPresented: $viewModel.isConfirmingEnd,
            titleVisibility: .visible
        ) {
            Button(L10n.t("rooms.live.end.confirmButton"), role: .destructive) {
                Task { await viewModel.endRoom() }
            }
            Button(L10n.t("rooms.live.end.cancelButton"), role: .cancel) {
                viewModel.isConfirmingEnd = false
            }
        } message: {
            Text(RoomCopy.endRoomWarning)
        }
        .tnToast($viewModel.toast)
    }

    /// The tapped person's sheet, built from the roster's current copy so the
    /// host's verbs match what they can do right now, not what was true on
    /// the tap. A separate function keeps `body` small enough to type-check.
    private func participantSheet(for selection: ParticipantSelection) -> some View {
        let participant: RoomParticipant = viewModel.participants.participants.first { $0.id == selection.id } ?? selection.participant
        let target = SafetyTarget(user: participant.user)
        let promote: @MainActor (RoomHostActions) async -> Void = { actions in await viewModel.promote(actions) }
        let dismiss: @MainActor (RoomHostActions) async -> Void = { actions in await viewModel.dismissHand(actions) }
        let mute: @MainActor (RoomHostActions) async -> Void = { actions in await viewModel.mute(actions) }
        let demote: @MainActor (RoomHostActions) async -> Void = { actions in await viewModel.demote(actions) }
        let remove: @MainActor (RoomHostActions) async -> Void = { actions in await viewModel.remove(actions) }
        return RoomParticipantSheet(
            participant: participant,
            hostActions: viewModel.hostActions(for: participant),
            safetyMenu: safetyMenu?(target),
            isSpeaking: viewModel.isSpeaking(participant),
            isMuted: viewModel.isMuted(participant),
            onOpenProfile: onOpenProfile,
            onPromote: promote,
            onDismissHand: dismiss,
            onMute: mute,
            onDemote: demote,
            onRemove: remove,
            onClose: { selected = nil }
        )
    }

    /// The room's text chat: a line to everybody, or to the host alone.
    private var roomChat: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SLSpacing.sm) {
                            if viewModel.chat.isEmpty {
                                Text(RoomCopy.chatEmpty)
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, SLSpacing.xl)
                            }
                            ForEach(viewModel.chat) { line in
                                chatLine(line)
                                    .id(line.id)
                            }
                        }
                        .padding(SLSpacing.lg)
                    }
                    .onChange(of: viewModel.chat.count) { _, _ in
                        withAnimation { proxy.scrollTo(viewModel.chat.last?.id, anchor: .bottom) }
                    }
                }

                if viewModel.canChat {
                    composer
                } else {
                    vouchedComposer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: RoomCopy.chatTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.done")) { viewModel.isChatOpen = false }
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func chatLine(_ line: RoomChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SLSpacing.xs) {
                Text(line.name)
                    .font(SLFont.micro)
                    .foregroundStyle(line.isMine ? SLColor.primary : SLColor.textSecondary)
                    .lineLimit(1)
                if line.toHost {
                    Label(RoomCopy.chatToHost, systemImage: "lock.fill")
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.warning)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
            }
            Text(line.text)
                .font(SLFont.body)
                .foregroundStyle(line.hidden ? SLColor.textMuted : SLColor.textPrimary)
                .strikethrough(line.hidden, color: SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: line.text))
            if line.hidden {
                Text(L10n.t("rooms.chat.hidden")).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if viewModel.isStage, line.serverId != nil, !line.hidden, !line.isMine {
                Button(L10n.t("rooms.chat.hide")) { Task { await viewModel.hide(line) } }
            }
            if let onReport, let id = line.serverId, !line.isMine {
                Button(role: .destructive) {
                    onReport(.roomMessage(id: id, author: SafetyTarget(handle: line.handle ?? "", name: line.name),
                                          excerpt: line.text))
                } label: {
                    Label(L10n.t("rooms.chat.report"), systemImage: "flag")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Where a vouched listener's composer would be: why there is none — to
    /// the room or to the host alone — and the one door that opens it
    /// (contract v24 §4).
    private var vouchedComposer: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Rectangle().fill(SLColor.stroke).frame(height: 1)
            Text(L10n.t("vouch.limited.rooms"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SLSpacing.lg)
                .accessibilityIdentifier("rooms.chat.vouched")
            if let onVerifySelf {
                SLButton(L10n.t("vouch.own.action"), variant: .secondary, size: .compact, icon: "checkmark.seal",
                         action: onVerifySelf)
                    .padding(.horizontal, SLSpacing.lg)
                    .accessibilityIdentifier("rooms.chat.vouched.verify")
            }
        }
        .padding(.bottom, SLSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surface1)
    }

    private var composer: some View {
        VStack(spacing: SLSpacing.xs) {
            Rectangle().fill(SLColor.stroke).frame(height: 1)

            if !viewModel.isHost {
                // Who hears it, chosen before it is typed rather than after.
                Picker("", selection: $viewModel.chatToHostOnly) {
                    Text(RoomCopy.chatToEveryone).tag(false)
                    Text(RoomCopy.chatToHost).tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.sm)
            }

            HStack(spacing: SLSpacing.sm) {
                TextField(RoomCopy.chatPlaceholder, text: $viewModel.chatDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .padding(.horizontal, SLSpacing.md)
                    .padding(.vertical, SLSpacing.sm)
                    .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1))
                    .overlay(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.stroke, lineWidth: 1))

                Button {
                    Task { await viewModel.sendChat() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(viewModel.canSendChat ? SLColor.primary : SLColor.stroke)
                }
                .disabled(!viewModel.canSendChat)
                .accessibilityLabel(Text(L10n.t("rooms.chat.send.a11yLabel")))
            }
            .padding(.horizontal, SLSpacing.lg)

            Text(viewModel.chatToHostOnly && !viewModel.isHost ? RoomCopy.chatPrivateNote : L10n.t("rooms.chat.notKept"))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SLSpacing.lg)
                .padding(.bottom, SLSpacing.sm)
        }
        .background(SLColor.surface1)
    }

    // MARK: - The two states

    private var inRoom: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    header
                    if let pinned = viewModel.depth?.pinned?.text ?? viewModel.room.pinnedQuestion?.text {
                        PinnedQuestionBanner(text: pinned)
                    }
                    if let depth = viewModel.depth, let poll = depth.openPoll {
                        // The running poll, on the room itself: everybody sees
                        // it open, votes where they are, and watches it move.
                        RoomPollCard(poll: poll, isStage: depth.isStage, canTakePart: depth.canTakePart,
                                     chosen: depth.chosenOption(in: poll),
                                     onVote: { option in Task { await depth.vote(option, in: poll) } },
                                     onClose: { Task { await depth.close(poll) } })
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .accessibilityIdentifier("rooms.live.poll")
                    }
                    if viewModel.room.isAMA, let depth = viewModel.depth {
                        // An AMA's main surface is its queue.
                        QuestionQueueView(viewModel: depth, hostName: viewModel.room.host.displayName)
                            .task { await depth.loadQuestions() }
                            .animation(.easeOut(duration: 0.2), value: depth.pendingQuestions)
                    }
                    connectionBanner
                    audioBanner
                    if viewModel.phase == .joining {
                        joining
                    } else {
                        stage
                        if viewModel.isStage { handsQueue }
                        audience
                    }
                    notRecorded
                }
                .padding(SLSpacing.lg)
                .padding(.bottom, SLSpacing.xxl)
            }
            .refreshable { await viewModel.refresh() }

            if viewModel.phase == .inRoom {
                floatingReactions
                controlBar
            }
        }
    }

    /// The door did not open. The server's sentence, and the way back.
    private func refused(_ reason: String) -> some View {
        VStack(spacing: SLSpacing.xl) {
            Spacer(minLength: SLSpacing.xxl)
            SLEmptyState(
                icon: viewModel.room.isRemoved ? "person.slash" : "lock.fill",
                title: RoomCopy.cannotEnterTitle,
                subtitle: reason,
                tint: SLColor.warning,
                actionTitle: L10n.t("rooms.live.leave"),
                action: {
                    Task {
                        await viewModel.leave()
                        onLeave()
                    }
                }
            )
            .padding(.horizontal, SLSpacing.lg)
            // A room that has not started yet: be told when it does.
            RemindMeButtons(room: viewModel.room)
                .padding(.horizontal, SLSpacing.lg)
            // An ended room leaves a recap — metadata only, never what was said.
            if let recognition, viewModel.room.status == .ended || reason == RoomCopy.roomEnded {
                RoomRecapView(roomId: viewModel.room.id, service: recognition)
                    .padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: SLSpacing.xxl)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(viewModel.room.title)
                .font(SLFont.displayM)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.room.title))
            if let question = viewModel.room.starterQuestion {
                Label(question, systemImage: "questionmark.bubble")
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: question))
            }

            HStack(spacing: SLSpacing.sm) {
                SLChip(
                    viewModel.room.scopePresentation.label,
                    icon: viewModel.room.scopePresentation.icon,
                    accessibilityHint: viewModel.room.scopePresentation.accessibilityLabel
                )
                if viewModel.room.isInviteOnly {
                    SLChip(RoomCopy.inviteOnlyBadge, icon: "lock.fill", accessibilityHint: RoomCopy.inviteOnlyBadge)
                } else if viewModel.room.isFollowingOnly {
                    SLChip(RoomCopy.followingOnlyBadge, icon: "person.2.fill", accessibilityHint: RoomCopy.followingOnlyBadge)
                } else if viewModel.room.isGroupOnly {
                    let badge = RoomCopy.groupBadge(viewModel.room.groupName)
                    SLChip(badge, icon: "person.3.fill", accessibilityHint: badge)
                }
                if let topic = viewModel.room.topicLabel {
                    SLChip(topic, icon: "number")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: SLSpacing.sm) {
                if viewModel.phase == .joining {
                    ProgressView().controlSize(.mini).tint(SLColor.primary)
                    Text(RoomCopy.joining)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                } else {
                    Text(viewModel.attendanceSummary)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
            }
            // Guests are in no roster and no count above (contract v31):
            // this line is the only place they show.
            RoomGuestsLine(text: viewModel.guestsLine)
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if viewModel.phase == .inRoom, let message = viewModel.connection.message {
            HStack(spacing: SLSpacing.sm) {
                if viewModel.connection.isActive {
                    ProgressView().controlSize(.small).tint(SLColor.primary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SLColor.warning)
                }
                Text(message)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(SLSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1))
            .accessibilityElement(children: .combine)
        }
    }

    /// Another call has the phone's audio: said in words, with the promise
    /// the room keeps — the microphone returns when that call ends.
    @ViewBuilder
    private var audioBanner: some View {
        if viewModel.phase == .inRoom, let notice = viewModel.audioNotice {
            HStack(alignment: .top, spacing: SLSpacing.sm) {
                Image(systemName: "phone.arrow.up.right")
                    .foregroundStyle(SLColor.warning)
                    .accessibilityHidden(true)
                Text(notice)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(SLSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.warning.opacity(0.12)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rooms.audio.notice")
        }
    }

    /// The door opening: one clear state with the host's face, what is
    /// happening, and a way out — in place of a grid of grey circles.
    private var joining: some View {
        VStack(spacing: SLSpacing.md) {
            SLAvatar(
                url: viewModel.room.host.avatarURL,
                initials: viewModel.room.host.initials,
                size: .lg,
                isVerified: viewModel.room.host.isVerified,
                displayName: viewModel.room.host.displayName
            )
            HStack(spacing: SLSpacing.sm) {
                ProgressView().controlSize(.small).tint(SLColor.primary)
                Text(RoomCopy.joining)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
            }
            Text(L10n.t("rooms.live.joining.hint"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SLButton(
                L10n.t("common.cancel"),
                variant: .ghost,
                size: .compact,
                isLoading: viewModel.isLeaving,
                asyncAction: {
                    await viewModel.leave()
                    onLeave()
                }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SLSpacing.xl)
        .accessibilityElement(children: .combine)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            sectionHeader(L10n.t("rooms.live.stage.header"), count: nil)
            HStack(spacing: SLSpacing.md) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(SLColor.surface2).frame(width: 64, height: 64)
                }
            }
            sectionHeader(L10n.t("rooms.live.audience.header"), count: nil)
            HStack(spacing: SLSpacing.sm) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle().fill(SLColor.surface2).frame(width: 44, height: 44)
                }
            }
        }
        .accessibilityLabel(Text(RoomCopy.joining))
    }

    // MARK: - People

    private var stage: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(L10n.t("rooms.live.stage.header"), count: viewModel.speakers.count)
            if viewModel.speakers.isEmpty {
                Text(L10n.t("rooms.live.stage.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                LazyVGrid(columns: stageColumns, alignment: .leading, spacing: SLSpacing.md) {
                    ForEach(viewModel.speakers) { participant in
                        personTile(participant, size: .lg)
                    }
                }
            }
        }
    }

    /// The host's queue: who asked, oldest first, with the two answers.
    private var handsQueue: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(RoomCopy.handsHeader, count: viewModel.hands.count)
            if viewModel.hands.isEmpty {
                Text(RoomCopy.handsEmpty)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                ForEach(viewModel.hands) { participant in
                    handRow(participant)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rooms.hands")
    }

    private func handRow(_ participant: RoomParticipant) -> some View {
        HStack(spacing: SLSpacing.md) {
            SLAvatar(
                url: participant.user.avatarURL,
                initials: participant.user.initials,
                size: .md,
                isVerified: participant.user.isVerified,
                displayName: participant.user.displayName
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(participant.user.displayName)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: participant.user.displayName))
                if let since = participant.handRaisedAt {
                    Text(RelativeTime.accessible(since))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
            }
            Spacer(minLength: 0)
            if let actions = viewModel.hostActions(for: participant) {
                SLButton(
                    RoomCopy.approveHand,
                    variant: .primary,
                    size: .compact,
                    icon: "mic.fill",
                    isLoading: actions.isBusy,
                    accessibilityHint: RoomCopy.inviteToMic,
                    asyncAction: { await viewModel.promote(actions) }
                )
                Button {
                    Task { await viewModel.dismissHand(actions) }
                } label: {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SLColor.textSecondary)
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(actions.isBusy)
                .accessibilityLabel(Text(RoomCopy.dismissHand))
            }
        }
        .padding(SLSpacing.md)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { selected = ParticipantSelection(participant) }
    }

    private var audience: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(L10n.t("rooms.live.audience.header"), count: viewModel.listeners.count)
            if viewModel.listeners.isEmpty {
                Text(L10n.t("rooms.live.audience.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                LazyVGrid(columns: audienceColumns, alignment: .leading, spacing: SLSpacing.sm) {
                    ForEach(viewModel.listeners) { participant in
                        personTile(participant, size: .md)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(SLFont.micro)
                .slTracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            if let count {
                Text(SLFormat.number(count))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private enum TileSize {
        case lg, md
        var edge: CGFloat { self == .lg ? 64 : 44 }
        var avatar: SLAvatar.Size { self == .lg ? .lg : .md }
    }

    /// One person: avatar, the speaking ring, the mute or hand badge, the
    /// name, and the menus.
    private func personTile(_ participant: RoomParticipant, size: TileSize) -> some View {
        VStack(spacing: SLSpacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if viewModel.isSpeaking(participant) {
                        Circle()
                            .strokeBorder(SLColor.secondary, lineWidth: 3)
                            .frame(width: size.edge + 10, height: size.edge + 10)
                    }
                    SLAvatar(
                        url: participant.user.avatarURL,
                        initials: participant.user.initials,
                        size: size.avatar,
                        isVerified: participant.user.isVerified,
                        displayName: participant.user.displayName
                    )
                }
                .frame(width: size.edge + 10, height: size.edge + 10)

                if participant.role.canPublish, viewModel.isMuted(participant) {
                    badge("mic.slash.fill", tint: SLColor.textMuted)
                } else if participant.hasHandRaised {
                    badge("hand.raised.fill", tint: SLColor.warning)
                } else if participant.role.isHost {
                    badge("crown.fill", tint: SLColor.primary)
                }
            }

            Text(participant.user.displayName)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: size.edge + 24)

            // A listener's tile has no room for the tag's words; the mark
            // alone, and a tap on it explains (contract v24 §3). Speakers are
            // never vouched — a vouched account cannot take the microphone.
            if size == .md, participant.user.vouchedBy != nil {
                VouchTag(person: participant.user, style: .iconOnly)
            }

            if size == .lg {
                HStack(spacing: 2) {
                    SLCountryBadge(countryCode: participant.user.countryCode)
                    VouchTag(person: participant.user, style: .iconOnly)
                    if let actions = viewModel.hostActions(for: participant) {
                        hostMenu(actions)
                    }
                    if let menu = safetyMenu?(SafetyTarget(user: participant.user)) {
                        SafetyMenuButton(actions: menu)
                    }
                }
            }
        }
        // Behind the tile, not over it: a gesture on the tile beat the two
        // menus drawn under the avatar, so the host's Mute / Move / Remove
        // and everybody's Block / Report opened the participant sheet
        // instead. A button behind the content leaves the menus their taps.
        .background {
            Button { selected = ParticipantSelection(participant) } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .contextMenu {
            if let actions = viewModel.hostActions(for: participant) {
                hostMenuItems(actions)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tileLabel(participant)))
        .accessibilityAction(named: Text(L10n.t("rooms.participant.open.a11yAction"))) {
            selected = ParticipantSelection(participant)
        }
    }

    private func tileLabel(_ participant: RoomParticipant) -> String {
        var parts = [participant.user.displayName, participant.role.badgeTitle]
        if !participant.user.isVerified, let vouch = participant.user.vouchedBy {
            parts.append(VouchCopy.tagAccessibility(vouch))
        }
        if viewModel.isSpeaking(participant) { parts.append(L10n.t("rooms.live.a11y.speaking")) }
        if participant.hasHandRaised { parts.append(L10n.t("rooms.live.a11y.handRaised")) }
        if participant.role.canPublish, viewModel.isMuted(participant) { parts.append(L10n.t("rooms.live.a11y.muted")) }
        return parts.joined(separator: ", ")
    }

    private func badge(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(tint))
            .overlay(Circle().strokeBorder(SLColor.surface1, lineWidth: 2))
            .accessibilityHidden(true)
    }

    private func hostMenu(_ actions: RoomHostActions) -> some View {
        Menu {
            hostMenuItems(actions)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SLColor.primary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(L10n.t("rooms.live.hostMenu.a11yLabel", actions.target.name)))
        .accessibilityHint(Text(L10n.t("rooms.live.hostMenu.a11yHint")))
    }

    @ViewBuilder
    private func hostMenuItems(_ actions: RoomHostActions) -> some View {
        Section {
            if actions.canPromote {
                Button {
                    Task { await viewModel.promote(actions) }
                } label: {
                    Label(actions.hasHandRaised ? RoomCopy.approveHand : RoomCopy.inviteToMic, systemImage: "mic")
                }
                .disabled(actions.isBusy)
            }
            if actions.canDismissHand {
                Button {
                    Task { await viewModel.dismissHand(actions) }
                } label: {
                    Label(RoomCopy.dismissHand, systemImage: "hand.raised.slash")
                }
                .disabled(actions.isBusy)
            }
            if actions.canMute {
                Button {
                    Task { await viewModel.mute(actions) }
                } label: {
                    Label(RoomCopy.muteSpeaker, systemImage: "speaker.slash")
                }
                .disabled(actions.isBusy)
            }
            if actions.canDemote {
                Button {
                    Task { await viewModel.demote(actions) }
                } label: {
                    Label(RoomCopy.takeMicBack, systemImage: "mic.slash")
                }
                .disabled(actions.isBusy)
            }
            if actions.canRemove {
                Button(role: .destructive) {
                    Task { await viewModel.remove(actions) }
                } label: {
                    Label(L10n.t("rooms.live.hostMenu.remove"), systemImage: "person.slash")
                }
                .disabled(actions.isBusy)
            }
        } header: {
            Text(L10n.t("rooms.live.hostMenu.header"))
        }
    }

    private var notRecorded: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SLColor.secondary)
            Text(RoomCopy.neverRecorded)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SLSpacing.md)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(RoomCopy.neverRecorded))
    }

    // MARK: - Controls

    /// The strip anybody can hit while listening, and the way into the chat.
    private var expression: some View {
        HStack(spacing: SLSpacing.xs) {
            // A vouched listener's reactions would ride the data channel the
            // media server refuses them; the strip is not drawn at all.
            if viewModel.canReact {
                ForEach(RoomReaction.palette, id: \.self) { emoji in
                    ReactionChip(emoji: emoji) { big in
                        Task { await viewModel.react(emoji, big: big) }
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                viewModel.isChatOpen = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SLColor.primary)
                        .frame(width: 40, height: 34)
                    if viewModel.unreadChat > 0 {
                        Text(SLFormat.number(viewModel.unreadChat))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.background)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(SLColor.primary))
                            .offset(x: 4, y: -2)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(L10n.t("rooms.chat.open.a11yLabel")))
            .accessibilityIdentifier("rooms.chat.open")
        }
        // No inset of its own: the control bar already keeps the gutter. Both
        // together made this row 412pt wide, which pushed the whole room past
        // the edges of a 375pt screen.
        .padding(.top, SLSpacing.sm)
    }

    /// Emoji on their way up, over the stage. Purely decorative: everything
    /// they mean is already said by the emoji itself.
    private var floatingReactions: some View {
        HStack(alignment: .bottom, spacing: SLSpacing.sm) {
            ForEach(viewModel.reactions.suffix(6)) { reaction in
                Text(reaction.emoji)
                    .font(.system(size: reaction.big ? 65 : 26))
                    .transition(reaction.big
                        ? .asymmetric(insertion: .scale(scale: 0.3).combined(with: .move(edge: .bottom)),
                                      removal: .opacity.combined(with: .move(edge: .top)))
                        : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, SLSpacing.lg)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.25), value: viewModel.reactions)
    }

    private var controlBar: some View {
        VStack(spacing: SLSpacing.sm) {
            expression
            if viewModel.isListening {
                listeningState
            }
            if let removed = viewModel.lastRemoved, viewModel.isStage {
                SLButton(
                    RoomCopy.readmit(removed.name),
                    variant: .ghost,
                    size: .compact,
                    icon: "arrow.uturn.backward",
                    asyncAction: { await viewModel.readmitLastRemoved() }
                )
            }

            HStack(spacing: SLSpacing.md) {
                SLButton(
                    L10n.t("rooms.live.leave"),
                    variant: .ghost,
                    size: .compact,
                    icon: "rectangle.portrait.and.arrow.forward",
                    isLoading: viewModel.isLeaving,
                    accessibilityHint: RoomCopy.leaveHint,
                    asyncAction: {
                        // A host is asked what they mean; everybody else just
                        // goes.
                        guard viewModel.requestLeave() else { return }
                        await viewModel.leave()
                        onLeave()
                    }
                )
                // The one way out of the room ("Leave room"); the bar's
                // chevron only minimises it.
                .accessibilityLabel(Text(L10n.t("rooms.live.leave.a11yLabel")))

                if viewModel.canRaiseHand {
                    SLButton(
                        viewModel.handRaised ? RoomCopy.lowerHand : RoomCopy.raiseHand,
                        variant: viewModel.handRaised ? .secondary : .primary,
                        size: .compact,
                        icon: viewModel.handRaised ? "hand.raised.slash" : "hand.raised.fill",
                        isLoading: viewModel.isTogglingHand,
                        accessibilityHint: viewModel.handRaised ? RoomCopy.lowerHandHint : RoomCopy.raiseHandHint,
                        asyncAction: { await viewModel.toggleHand() }
                    )
                }

                if viewModel.canUseMicrophone {
                    SLButton(
                        viewModel.isMicrophoneEnabled ? RoomCopy.dropMic : RoomCopy.takeMic,
                        variant: viewModel.isMicrophoneEnabled ? .secondary : .primary,
                        size: .compact,
                        icon: viewModel.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                        isLoading: viewModel.isTogglingMic || viewModel.isRejoining,
                        accessibilityHint: viewModel.isMicrophoneEnabled ? RoomCopy.dropMicHint : RoomCopy.takeMicHint,
                        asyncAction: { await viewModel.toggleMicrophone() }
                    )
                }

                if viewModel.isStage {
                    SLButton(
                        L10n.t("rooms.live.end"),
                        variant: .destructive,
                        size: .compact,
                        icon: "stop.circle",
                        isLoading: viewModel.isEnding,
                        accessibilityHint: L10n.t("rooms.live.end.a11yHint"),
                        action: { viewModel.requestEnd() }
                    )
                }
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.md)
        .padding(.bottom, SLSpacing.sm)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                SLColor.surface1
                Rectangle().fill(SLColor.stroke).frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var listeningExplanation: String {
        if viewModel.handRaised { return RoomCopy.handRaised }
        return viewModel.speakRefusal ?? RoomCopy.listeningSubtitle
    }

    private var listeningState: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: viewModel.handRaised ? "hand.raised.fill" : "ear.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(viewModel.handRaised ? SLColor.warning : SLColor.primary)
                Text(RoomCopy.listeningTitle)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                Spacer(minLength: 0)
            }
            Text(listeningExplanation)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: listeningExplanation))
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            L10n.t("rooms.live.listening.a11yLabel", RoomCopy.listeningTitle, listeningExplanation)
        ))
    }
}

#Preview("Room — listening") {
    NavigationStack {
        LiveRoomScreen(
            viewModel: LiveRoomViewModel(
                room: VoiceRoom(
                    id: UUID(),
                    title: "قهوة الصباح — Riyadh morning",
                    topic: "culture",
                    scope: .country,
                    scopeCountry: "SA",
                    status: .live,
                    host: FeedServiceMock.noor,
                    speakerCount: 5,
                    listenerCount: 112,
                    startedAt: Date().addingTimeInterval(-3_000),
                    canSpeak: false,
                    speakRefusal: "Only 🇸🇦 Saudi Arabia-verified accounts can speak in this room. You can still listen."
                ),
                viewerHandle: "aziz",
                service: RoomsServiceMock(scenario: .listenerOnly),
                engine: VoiceEngineMock(),
                analytics: RecordingAnalyticsClient(),
                pollInterval: 0
            ),
            onLeave: {}
        )
    }
    .preferredColorScheme(.dark)
}

/// A tapped participant, as sheet state. Keyed on the account id so the
/// sheet can re-read the roster's current copy of the person.
private struct ParticipantSelection: Identifiable {
    let id: UUID
    let participant: RoomParticipant

    init(_ participant: RoomParticipant) {
        id = participant.id
        self.participant = participant
    }
}


/// One emoji in the room's strip. A tap sends it; holding it (a third of a
/// second — a light tap on the wrist says it is armed, and the chip grows)
/// sends it big when released.
private struct ReactionChip: View {
    let emoji: String
    let onSend: (_ big: Bool) -> Void

    @State private var isPressed = false
    @State private var isArmed = false

    static let holdDuration: Double = 0.35

    var body: some View {
        Text(emoji)
            .font(.system(size: 20))
            // Gives a little on a narrow phone rather than pushing the room
            // wider than the screen: eight of these and the chat button have
            // to fit in 343pt on an iPhone SE.
            .frame(minWidth: 28, idealWidth: 34, maxWidth: 34, minHeight: 34, maxHeight: 34)
            .background(Circle().fill(isArmed ? SLColor.primary.opacity(0.25) : SLColor.surface2))
            .scaleEffect(isArmed ? 1.6 : (isPressed ? 1.12 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isArmed)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 40) {
                isArmed = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } onPressingChanged: { pressing in
                if pressing {
                    isPressed = true
                } else {
                    isPressed = false
                    let big = isArmed
                    isArmed = false
                    onSend(big)
                }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(L10n.t("rooms.reactions.send.a11yLabel", emoji)))
            .accessibilityAction { onSend(false) }
            .accessibilityAction(named: Text(L10n.t("rooms.reactions.sendBig.a11yLabel"))) { onSend(true) }
            .accessibilityIdentifier("rooms.reaction.\(emoji)")
    }
}


// MARK: - The room you are in, wherever you are in the app

/// The one room this person is in, held above every tab.
///
/// The room screen used to own its room: switching tabs rebuilt the Rooms
/// tab's stack, the screen went, and the connection went with it — "joining
/// a room while browsing the app, it exits". The room now lives here, the
/// screen is only a view of it, and only an explicit Leave (or the room
/// ending) takes anybody out. Browsing elsewhere shows ``RoomMiniPlayer``.
@MainActor
@Observable
public final class ActiveRoomSession {

    /// The room's model, while one is held. Stays set after a leave until
    /// another room is entered, so a screen still on its way out has a
    /// model to draw — ``isLive`` says whether it is still a room.
    public private(set) var current: LiveRoomViewModel?

    public init() {}

    /// `true` while somebody is actually in a room.
    public var isLive: Bool {
        guard let current, !current.hasLeft else { return false }
        return current.phase == .inRoom || current.phase == .joining
    }

    /// The live model for this room, if it is the one held.
    public func model(for roomId: UUID) -> LiveRoomViewModel? {
        guard let current, current.room.id == roomId else { return nil }
        return current
    }

    /// Enters a room: the one already held for it, or a new one — leaving
    /// any other room first, as one person is in one room at a time.
    @discardableResult
    public func enter(_ room: VoiceRoom, make: @MainActor () -> LiveRoomViewModel) -> LiveRoomViewModel {
        if let current, current.room.id == room.id, !current.hasLeft { return current }
        if let previous = current, !previous.hasLeft {
            Task { await previous.leave() }
        }
        let made = make()
        current = made
        nowPlaying.attach(made)
        // Joined here, not by the screen's `.task`: switching tabs mid-join
        // tears the screen down and would cancel a join tied to it.
        Task { await made.start() }
        return made
    }

    /// Leaves the room held, if any.
    public func leave() async {
        guard let current, !current.hasLeft else { return }
        await current.leave()
        nowPlaying.detach()
    }

    /// Called when the held room has been left by any path.
    public func didLeave() {
        nowPlaying.detach()
    }

    // MARK: Background and the lock screen

    private let nowPlaying = RoomNowPlaying()

    /// Re-says the room on the lock screen and in Control Center.
    public func refreshNowPlaying() {
        guard let current, isLive else {
            nowPlaying.detach()
            return
        }
        nowPlaying.update(current)
    }

    public func didEnterBackground() async {
        await current?.persistThroughBackgrounding()
    }

    public func didBecomeActive() async {
        await current?.resumeFromBackground()
    }

    public func willTerminate() async {
        await current?.handleTermination()
    }
}

/// The room on the lock screen, in Control Center and on a paired device:
/// its title, its host, the app's icon; play/pause takes and drops the
/// microphone for somebody who has one, stop leaves.
///
/// Audio keeps going in the background on its own (`UIBackgroundModes`
/// `audio`, a `.playAndRecord` session held by the media engine); this only
/// gives the room a face outside the app.
@MainActor
final class RoomNowPlaying {
    private weak var model: LiveRoomViewModel?
    private var targets: [Any] = []

    func attach(_ model: LiveRoomViewModel) {
        detach()
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        // iOS calls these on the main thread.
        targets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleMic(wantOn: nil) ?? .commandFailed }
        })
        targets.append(center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleMic(wantOn: false) ?? .commandFailed }
        })
        targets.append(center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleMic(wantOn: true) ?? .commandFailed }
        })
        targets.append(center.stopCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() ?? .commandFailed }
        })
        update(model)
    }

    func detach() {
        let center = MPRemoteCommandCenter.shared()
        for target in targets {
            center.togglePlayPauseCommand.removeTarget(target)
            center.pauseCommand.removeTarget(target)
            center.playCommand.removeTarget(target)
            center.stopCommand.removeTarget(target)
        }
        targets = []
        model = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func update(_ model: LiveRoomViewModel) {
        let center = MPRemoteCommandCenter.shared()
        let canMic = model.canUseMicrophone
        center.togglePlayPauseCommand.isEnabled = canMic
        center.pauseCommand.isEnabled = canMic
        center.playCommand.isEnabled = canMic
        center.stopCommand.isEnabled = !model.isHost
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: model.room.title,
            MPMediaItemPropertyArtist: L10n.t("rooms.nowPlaying.hostedBy", model.room.host.displayName),
            MPMediaItemPropertyAlbumTitle: L10n.t("auth.brand.wordmark"),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            // "Playing" while the microphone is open (pause = mute), paused
            // while it is shut (play = unmute). A listener is always playing.
            MPNowPlayingInfoPropertyPlaybackRate: (!canMic || model.isMicrophoneEnabled) ? 1.0 : 0.0
        ]
        if let artwork = Self.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// `wantOn` `nil` toggles; otherwise only moves the microphone if it is
    /// not there already.
    private func toggleMic(wantOn: Bool?) -> MPRemoteCommandHandlerStatus {
        guard let model, model.canUseMicrophone else { return .commandFailed }
        if let wantOn, wantOn == model.isMicrophoneEnabled { return .success }
        Task { await model.toggleMicrophone() }
        return .success
    }

    private func leave() -> MPRemoteCommandHandlerStatus {
        // A host is asked what leaving means; that question needs the room.
        guard let model, !model.isHost else { return .commandFailed }
        Task { await model.leave() }
        return .success
    }

    private static let artwork: MPMediaItemArtwork? = makeArtwork()

    /// The app's own icon, read from the bundle — or a waveform if the icon
    /// files are not where iOS usually puts them. Built outside the main
    /// actor: iOS asks the artwork for its image on a queue of its own.
    nonisolated private static func makeArtwork() -> MPMediaItemArtwork? {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        let image = files?.last.flatMap { UIImage(named: $0) }
            ?? UIImage(systemName: "waveform.circle.fill")
        guard let image else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// The room you are in, while you browse: its name, who is talking, your
/// microphone and the way out. Tapping it goes back into the room.
@MainActor
public struct RoomMiniPlayer: View {
    @Bindable var viewModel: LiveRoomViewModel
    let onOpen: @MainActor () -> Void
    let onLeave: @MainActor () -> Void

    public init(viewModel: LiveRoomViewModel, onOpen: @escaping @MainActor () -> Void,
                onLeave: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onLeave = onLeave
    }

    private var someoneSpeaking: Bool { !viewModel.speakingIds.isEmpty }

    public var body: some View {
        HStack(spacing: SLSpacing.md) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(someoneSpeaking ? SLColor.secondary : SLColor.primary)
                .symbolEffect(.variableColor.iterative, isActive: someoneSpeaking)
                .frame(width: 36, height: 36)
                .background(Circle().fill(SLColor.primary.opacity(0.15)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.room.title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.room.title))
                Text(subtitle)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if viewModel.canUseMicrophone {
                Button {
                    Task { await viewModel.toggleMicrophone() }
                } label: {
                    Image(systemName: viewModel.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(viewModel.isMicrophoneEnabled ? SLColor.primary : SLColor.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isTogglingMic)
                .accessibilityLabel(Text(viewModel.isMicrophoneEnabled ? RoomCopy.dropMic : RoomCopy.takeMic))
                .accessibilityIdentifier("rooms.mini.mic")
            }

            Button {
                onLeave()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SLColor.danger)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.t("rooms.live.leave.a11yLabel")))
            .accessibilityIdentifier("rooms.mini.leave")
        }
        .padding(.horizontal, SLSpacing.md)
        .padding(.vertical, SLSpacing.sm)
        .background {
            // Behind the controls, so the microphone and Leave keep their
            // own taps (a tap gesture on the bar would take them).
            Button {
                onOpen()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
        }
        .background(
            RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous)
                .fill(SLColor.surface2)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous)
                .strokeBorder(SLColor.primary.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, SLSpacing.md)
        .padding(.bottom, SLSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L10n.t("rooms.mini.open"))) { onOpen() }
        .accessibilityIdentifier("rooms.mini")
    }

    private var subtitle: String {
        if viewModel.audioNotice != nil { return L10n.t("rooms.audio.onAnotherCall.short") }
        if viewModel.isListening { return L10n.t("rooms.mini.listening") }
        return viewModel.isMicrophoneEnabled ? L10n.t("rooms.mini.micOn") : L10n.t("rooms.mini.micOff")
    }
}

/// A room screen for the room the app holds: the held model when it is this
/// room, or — reached some other way, a restored stack — the room entered
/// on arrival.
@MainActor
public struct ActiveRoomHost<Content: View>: View {
    let room: VoiceRoom
    let session: ActiveRoomSession
    let make: @MainActor () -> LiveRoomViewModel
    let content: (LiveRoomViewModel) -> Content

    public init(room: VoiceRoom, session: ActiveRoomSession, make: @escaping @MainActor () -> LiveRoomViewModel,
                @ViewBuilder content: @escaping (LiveRoomViewModel) -> Content) {
        self.room = room
        self.session = session
        self.make = make
        self.content = content
    }

    public var body: some View {
        if let model = session.model(for: room.id) {
            content(model)
        } else {
            Color.clear.onAppear { session.enter(room, make: make) }
        }
    }
}
