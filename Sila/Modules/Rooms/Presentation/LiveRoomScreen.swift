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
    private let onOpenProfile: (@MainActor (String) -> Void)?
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isManagingInvites = false

    private let stageColumns = [GridItem(.adaptive(minimum: 84), spacing: SLSpacing.md)]
    private let audienceColumns = [GridItem(.adaptive(minimum: 64), spacing: SLSpacing.sm)]

    public init(
        viewModel: LiveRoomViewModel,
        onLeave: @escaping @MainActor () -> Void,
        onOpenProfile: (@MainActor (String) -> Void)? = nil,
        safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)? = nil
    ) {
        self.viewModel = viewModel
        self.onLeave = onLeave
        self.onOpenProfile = onOpenProfile
        self.safetyMenu = safetyMenu
    }

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
                Button {
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
        .sheet(isPresented: $isManagingInvites) {
            RoomInvitesSheet(
                viewModel: viewModel.makeInvitesViewModel(),
                onClose: { isManagingInvites = false }
            )
        }
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await viewModel.persistThroughBackgrounding() }
            case .active: Task { await viewModel.resumeFromBackground() }
            default: break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
        ) { _ in
            Task { await viewModel.handleTermination() }
        }
        .onChange(of: viewModel.hasLeft) { _, hasLeft in
            if hasLeft { onLeave() }
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

    // MARK: - The two states

    private var inRoom: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    header
                    connectionBanner
                    if viewModel.phase == .joining {
                        skeleton
                    } else {
                        stage
                        if viewModel.isHost { handsQueue }
                        audience
                    }
                    notRecorded
                }
                .padding(SLSpacing.lg)
                .padding(.bottom, SLSpacing.xxl)
            }
            .refreshable { await viewModel.refresh() }

            if viewModel.phase == .inRoom {
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
        .onTapGesture { onOpenProfile?(participant.user.handle) }
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
                .tracking(0.8)
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

            if size == .lg {
                HStack(spacing: 2) {
                    SLCountryBadge(countryCode: participant.user.countryCode)
                    if let actions = viewModel.hostActions(for: participant) {
                        hostMenu(actions)
                    }
                    if let menu = safetyMenu?(SafetyTarget(user: participant.user)) {
                        SafetyMenuButton(actions: menu)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenProfile?(participant.user.handle) }
        .contextMenu {
            if let actions = viewModel.hostActions(for: participant) {
                hostMenuItems(actions)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(tileLabel(participant)))
    }

    private func tileLabel(_ participant: RoomParticipant) -> String {
        var parts = [participant.user.displayName, participant.role.badgeTitle]
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

    private var controlBar: some View {
        VStack(spacing: SLSpacing.sm) {
            if viewModel.isListening {
                listeningState
            }
            if let removed = viewModel.lastRemoved, viewModel.isHost {
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
                        await viewModel.leave()
                        onLeave()
                    }
                )

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

                if viewModel.isHost {
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
