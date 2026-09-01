import SwiftUI
import UIKit

/// Inside a room: who is speaking, who is listening, and the one control that
/// matters.
///
/// Four things here are load-bearing.
///
/// **The microphone is drawn only when it can work.** It is gated on
/// ``LiveRoomViewModel/canUseMicrophone``, which is the role the server's token
/// grants — not the scope, not a country, not anything this screen worked out.
/// A listener sees "You're listening" and the reason, in the server's words.
///
/// **There is no recording affordance, and the screen says why.** Not because
/// recording is switched off somewhere, but because it does not exist: nothing
/// is stored, so there is nothing to offer.
///
/// **Removal is described as what it is.** One room, by one host, with the
/// account untouched. The word "block" appears nowhere in this file.
///
/// **Leaving does both halves, on every exit path.** The Leave button, the
/// swipe back, and the app being killed all reach ``LiveRoomViewModel/leave()``,
/// which posts `/leave` *and* disconnects the media.
@MainActor
public struct LiveRoomScreen: View {

    @Bindable private var viewModel: LiveRoomViewModel
    private let onLeave: @MainActor () -> Void
    private let onOpenProfile: (@MainActor (String) -> Void)?
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?

    @Environment(\.scenePhase) private var scenePhase

    /// - Parameters:
    ///   - viewModel: Owns the connection, the roster and the host controls.
    ///   - onLeave: Pops the screen once the room has been left.
    ///   - onOpenProfile: Opens somebody's page.
    ///   - safetyMenu: The app's block / mute / report menu, per participant.
    ///     `nil` only in previews — in the app it is always present, because a
    ///     live audio room is exactly where somebody needs it most.
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    header
                    connectionBanner
                    stage
                    audience
                    notRecorded
                }
                .padding(SLSpacing.lg)
                .padding(.bottom, SLSpacing.xxl)
            }
            .refreshable { await viewModel.refresh() }

            controlBar
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
                    // `.backward`, not `.left`: the back chevron has to point at
                    // the edge the user came from, which swaps in Arabic.
                    Label(L10n.t("rooms.live.leave"), systemImage: "chevron.backward")
                        .foregroundStyle(SLColor.primary)
                }
                .accessibilityLabel(Text(L10n.t("rooms.live.leave.a11yLabel")))
                .accessibilityHint(Text(RoomCopy.leaveHint))
            }
        }
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding does **not** leave: audio survives it on purpose,
            // and a room that dropped the moment somebody checked a message
            // would be unusable. Termination is the one that must tear down.
            switch phase {
            case .background: Task { await viewModel.persistThroughBackgrounding() }
            case .active: Task { await viewModel.resumeFromBackground() }
            default: break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
        ) { _ in
            // The last chance to post `/leave` and close the socket. Without
            // this the room keeps a ghost on its list and a socket nobody owns.
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            // The host's own words: laid out in the title's direction, not the
            // interface's.
            Text(viewModel.room.title)
                .font(SLFont.displayM)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .slContentDirection(
                    TextDirection.resolve(languageCode: nil, text: viewModel.room.title)
                )

            HStack(spacing: SLSpacing.sm) {
                SLChip(
                    viewModel.room.scopePresentation.label,
                    icon: viewModel.room.scopePresentation.icon,
                    accessibilityHint: viewModel.room.scopePresentation.accessibilityLabel
                )
                if let topic = viewModel.room.topicLabel {
                    SLChip(topic, icon: "number")
                }
                Spacer(minLength: 0)
            }

            Text(viewModel.room.attendanceSummary)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if let message = viewModel.connection.message {
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

    // MARK: - People

    private var stage: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(L10n.t("rooms.live.stage.header"), count: viewModel.speakers.count)

            if viewModel.speakers.isEmpty {
                Text(L10n.t("rooms.live.stage.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                ForEach(viewModel.speakers) { participant in
                    participantRow(participant)
                }
            }
        }
    }

    private var audience: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(L10n.t("rooms.live.audience.header"), count: viewModel.listeners.count)

            if viewModel.listeners.isEmpty {
                Text(L10n.t("rooms.live.audience.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                ForEach(viewModel.listeners) { participant in
                    participantRow(participant)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            Text(SLFormat.number(count))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func participantRow(_ participant: RoomParticipant) -> some View {
        HStack(spacing: SLSpacing.md) {
            ZStack {
                // The speaking ring comes from the media server's own speaker
                // report, not from any local guess about who is loud.
                if viewModel.isSpeaking(participant) {
                    Circle()
                        .strokeBorder(SLColor.secondary, lineWidth: 2)
                        .frame(width: 50, height: 50)
                }
                SLAvatar(
                    url: participant.user.avatarURL,
                    initials: participant.user.initials,
                    size: .md,
                    isVerified: participant.user.isVerified,
                    displayName: participant.user.displayName
                )
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SLSpacing.xs) {
                    Text(participant.user.displayName)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                        .slContentDirection(
                            TextDirection.resolve(
                                languageCode: nil,
                                text: participant.user.displayName
                            )
                        )
                    if participant.user.isVerified {
                        SLVerifiedBadge(size: 12, isPulsing: false)
                    }
                    SLCountryBadge(countryCode: participant.user.countryCode)
                }
                Text(participant.role.badgeTitle)
                    .font(SLFont.micro)
                    .foregroundStyle(
                        participant.role.isHost ? SLColor.primary : SLColor.textMuted
                    )
            }

            Spacer(minLength: 0)

            // The host's menu and the safety menu are separate controls on
            // purpose. Running a room and protecting yourself in one are
            // different jobs, and folding "remove from this room" in beside
            // "block this account" would blur exactly the distinction this
            // feature has to keep sharp.
            if let actions = viewModel.hostActions(for: participant) {
                hostMenu(actions)
            }
            if let menu = safetyMenu?(SafetyTarget(user: participant.user)) {
                SafetyMenuButton(actions: menu)
            }
        }
        .padding(.vertical, SLSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { onOpenProfile?(participant.user.handle) }
    }

    private func hostMenu(_ actions: RoomHostActions) -> some View {
        Menu {
            Section {
                if actions.canPromote {
                    Button {
                        Task { await viewModel.promote(actions) }
                    } label: {
                        Label(RoomCopy.inviteToMic, systemImage: "mic")
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
                // The sentence that stops a removal being read as a block.
                Text(L10n.t("rooms.live.hostMenu.header"))
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SLColor.primary)
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(L10n.t("rooms.live.hostMenu.a11yLabel", actions.target.name)))
        .accessibilityHint(Text(L10n.t("rooms.live.hostMenu.a11yHint")))
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

    /// The bar along the bottom.
    ///
    /// A listener gets no microphone button at all — not a disabled one. A
    /// control that is present but inert invites people to keep pressing it and
    /// then to keep talking into a stream nobody receives.
    private var controlBar: some View {
        VStack(spacing: SLSpacing.sm) {
            if viewModel.isListening {
                listeningState
            }

            HStack(spacing: SLSpacing.md) {
                SLButton(
                    L10n.t("rooms.live.leave"),
                    variant: .ghost,
                    size: .compact,
                    // `.forward` rather than `.right`: the door the arrow points
                    // out of is on the other side in Arabic, and
                    // `rectangle.portrait.and.arrow.right` does not mirror.
                    icon: "rectangle.portrait.and.arrow.forward",
                    isLoading: viewModel.isLeaving,
                    accessibilityHint: RoomCopy.leaveHint,
                    asyncAction: {
                        await viewModel.leave()
                        onLeave()
                    }
                )

                if viewModel.canUseMicrophone {
                    SLButton(
                        viewModel.isMicrophoneEnabled ? RoomCopy.dropMic : RoomCopy.takeMic,
                        variant: viewModel.isMicrophoneEnabled ? .secondary : .primary,
                        size: .compact,
                        icon: viewModel.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                        isLoading: viewModel.isTogglingMic || viewModel.isRejoining,
                        accessibilityHint: viewModel.isMicrophoneEnabled
                            ? RoomCopy.dropMicHint
                            : RoomCopy.takeMicHint,
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

    /// The server's refusal when there is one, otherwise the plain fact that
    /// listening needs no microphone.
    private var listeningExplanation: String {
        viewModel.speakRefusal ?? RoomCopy.listeningSubtitle
    }

    /// What a listener is told: that they are hearing everything, that no
    /// microphone is involved, and — when the server sent one — exactly why.
    private var listeningState: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "ear.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SLColor.primary)
                Text(RoomCopy.listeningTitle)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                Spacer(minLength: 0)
            }

            // The server's sentence, verbatim, when there is one — otherwise
            // the plain fact that listening needs no microphone. The server
            // wrote it, so it is laid out in its own direction.
            Text(listeningExplanation)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .slContentDirection(
                    TextDirection.resolve(languageCode: nil, text: listeningExplanation)
                )
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
                join: RoomJoin(
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
                    url: "wss://sila.gmai.sa/rtc",
                    token: "preview",
                    role: .listener
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
