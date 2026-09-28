import SwiftUI
import UIKit

/// A room, for somebody without an account (contract v31).
///
/// Opening it listens at once — `POST /public/rooms/{id}/listen`, then the
/// media server, listen-only and hidden — and every refusal says what it
/// means and what can be done. Everything that takes part (speaking, a
/// raised hand, a reaction, the chat, a question, a poll) meets the "Join
/// Sila to take part" invitation instead; the chat and the reactions of the
/// members are there to read and watch.
///
/// Laid out as the member room is (``LiveRoomScreen``), so joining changes
/// what somebody can do in it, not where anything is.
@MainActor
public struct GuestRoomScreen: View {

    @Bindable private var viewModel: GuestRoomViewModel
    private let onLeave: @MainActor () -> Void
    private let onAsk: @MainActor (JoinPrompt) -> Void
    private let onCreateAccount: @MainActor () -> Void
    private let onSignIn: @MainActor () -> Void

    private let stageColumns = [GridItem(.adaptive(minimum: 84), spacing: SLSpacing.md)]
    private let audienceColumns = [GridItem(.adaptive(minimum: 64), spacing: SLSpacing.sm)]

    /// - Parameters:
    ///   - onLeave: Back to the guest's Rooms tab.
    ///   - onAsk: The invitation for whatever a guest reached for.
    ///   - onCreateAccount / onSignIn: The two doors a refusal offers, which
    ///     come back to this room once through them.
    public init(
        viewModel: GuestRoomViewModel,
        onLeave: @escaping @MainActor () -> Void,
        onAsk: @escaping @MainActor (JoinPrompt) -> Void,
        onCreateAccount: @escaping @MainActor () -> Void,
        onSignIn: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.onLeave = onLeave
        self.onAsk = onAsk
        self.onCreateAccount = onCreateAccount
        self.onSignIn = onSignIn
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    header
                    switch viewModel.phase {
                    case .connecting:
                        connecting
                    case .listening:
                        stage
                        audience
                    case let .refused(refusal):
                        refused(refusal)
                    }
                    notRecorded
                }
                .padding(SLSpacing.lg)
                .padding(.bottom, SLSpacing.xxl)
            }

            if viewModel.isListening {
                floatingReactions
                controlBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .navigationBarBackButtonHidden(true)
        .tnNavigationBar(title: L10n.t("rooms.live.nav.title"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { leave() } label: {
                    Label(L10n.t("rooms.live.leave"), systemImage: "chevron.backward")
                        .foregroundStyle(SLColor.primary)
                }
                .accessibilityLabel(Text(L10n.t("rooms.live.leave.a11yLabel")))
                .accessibilityIdentifier("guest.room.back")
            }
            if viewModel.isListening, let card = viewModel.card {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onAsk(.like) } label: {
                        Label(SLFormat.compactCount(card.metrics.likes), systemImage: "heart")
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.like.a11yLabel")))
                    .accessibilityIdentifier("guest.room.like")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onAsk(.takePart) } label: {
                        Image(systemName: "questionmark.bubble").foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(L10n.t("rooms.depth.title")))
                    .accessibilityIdentifier("guest.room.depth")
                }
            }
        }
        .sheet(isPresented: $viewModel.isChatOpen) { chatSheet }
        .task { await viewModel.open() }
        .onDisappear { Task { await viewModel.close() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            Task { await viewModel.close() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest.room")
    }

    private func leave() {
        Task {
            await viewModel.close()
            onLeave()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let card = viewModel.card {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(card.title)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: card.title))
                if let question = card.starterQuestion {
                    Label(question, systemImage: "questionmark.bubble")
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: question))
                }
                HStack(spacing: SLSpacing.sm) {
                    SLChip(
                        card.scopePresentation.label,
                        icon: card.scopePresentation.icon,
                        accessibilityHint: card.scopePresentation.accessibilityLabel
                    )
                    if card.isAMA {
                        SLChip(L10n.t("rooms.create.ama"), icon: "questionmark.bubble")
                    }
                    if let topic = card.topicLabel {
                        SLChip(topic, icon: "number")
                    }
                    Spacer(minLength: 0)
                }
                if let line = viewModel.attendanceLine {
                    Text(line)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .accessibilityIdentifier("guest.room.counts")
                }
            }
        }
    }

    // MARK: - The three states

    private var connecting: some View {
        VStack(spacing: SLSpacing.md) {
            if let host = viewModel.card?.host {
                SLAvatar(
                    url: host.avatarURL,
                    initials: host.initials,
                    size: .lg,
                    isVerified: host.isVerified,
                    displayName: host.displayName
                )
            }
            HStack(spacing: SLSpacing.sm) {
                ProgressView().controlSize(.small).tint(SLColor.primary)
                Text(RoomCopy.joining)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
            }
            SLButton(L10n.t("common.cancel"), variant: .ghost, size: .compact, action: { leave() })
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SLSpacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest.room.connecting")
    }

    /// Why this guest is not listening, and what they can do about it.
    private func refused(_ refusal: GuestRefusal) -> some View {
        VStack(spacing: SLSpacing.lg) {
            SLEmptyState(
                icon: refusal.icon,
                title: refusal.title,
                subtitle: refusal.detail,
                tint: tint(for: refusal)
            )
            if let starts = viewModel.startsLine {
                Label(starts, systemImage: "calendar.badge.clock")
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityIdentifier("guest.room.starts")
            }
            if refusal.canRetry {
                // A countdown while the server's wait runs, then the button.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = viewModel.secondsUntilRetry(at: context.date)
                    SLButton(
                        wait > 0 ? GuestRefusal.tryAgainIn(seconds: wait) : L10n.t("rooms.error.retry"),
                        variant: refusal.offersJoin ? .secondary : .primary,
                        icon: "arrow.clockwise",
                        isEnabled: wait == 0,
                        asyncAction: { await viewModel.start() }
                    )
                    .accessibilityIdentifier("guest.room.retry")
                }
            }
            if refusal.offersJoin {
                VStack(spacing: SLSpacing.sm) {
                    SLButton(L10n.t("guest.join.create"), variant: .primary, action: { onCreateAccount() })
                        .accessibilityIdentifier("guest.room.create")
                    SLButton(L10n.t("guest.join.signIn"), variant: .secondary, action: { onSignIn() })
                        .accessibilityIdentifier("guest.room.signIn")
                }
            }
            Button(L10n.t("guest.room.back"), action: { leave() })
                .font(SLFont.caption)
                .foregroundStyle(SLColor.primary)
                .accessibilityIdentifier("guest.room.backToRooms")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, SLSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest.room.refusal.\(refusal.code.rawValue)")
    }

    private func tint(for refusal: GuestRefusal) -> Color {
        switch refusal.code {
        case .connectFailed: return SLColor.danger
        case .roomEnded, .notFound: return SLColor.textSecondary
        default: return SLColor.warning
        }
    }

    // MARK: - People

    private var stage: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(L10n.t("rooms.live.stage.header"), count: viewModel.stage.count)
            if viewModel.stage.isEmpty {
                Text(L10n.t("rooms.live.stage.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                LazyVGrid(columns: stageColumns, alignment: .leading, spacing: SLSpacing.md) {
                    ForEach(viewModel.stage) { person in tile(person, large: true) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest.room.stage")
    }

    private var audience: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            sectionHeader(L10n.t("rooms.live.audience.header"), count: viewModel.audience.count)
            if viewModel.audience.isEmpty {
                Text(L10n.t("rooms.live.audience.empty"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            } else {
                LazyVGrid(columns: audienceColumns, alignment: .leading, spacing: SLSpacing.sm) {
                    ForEach(viewModel.audience) { person in tile(person, large: false) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(SLFont.micro)
                .slTracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            Text(SLFormat.number(count))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// One person: the avatar, the speaking ring, the crown, the name. No
    /// menus — a guest can open nobody's profile and act on nobody.
    private func tile(_ person: VoiceParticipant, large: Bool) -> some View {
        let edge: CGFloat = large ? 64 : 44
        let speaking = viewModel.isSpeaking(person)
        let host = viewModel.card?.host
        let isTheHost = person.isHost && host.map { Handle.normalised($0.handle) == person.handle } == true
        return VStack(spacing: SLSpacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if speaking {
                        Circle()
                            .strokeBorder(SLColor.secondary, lineWidth: 3)
                            .frame(width: edge + 10, height: edge + 10)
                    }
                    SLAvatar(
                        url: isTheHost ? host?.avatarURL : nil,
                        initials: person.initials,
                        size: large ? .lg : .md,
                        isVerified: isTheHost && host?.isVerified == true,
                        displayName: person.displayName
                    )
                }
                .frame(width: edge + 10, height: edge + 10)
                if person.isHost {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(SLColor.primary))
                        .overlay(Circle().strokeBorder(SLColor.surface1, lineWidth: 2))
                        .accessibilityHidden(true)
                }
            }
            Text(person.displayName)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: edge + 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(tileLabel(person, speaking: speaking)))
    }

    private func tileLabel(_ person: VoiceParticipant, speaking: Bool) -> String {
        let role: RoomRole = person.isHost ? .host : (person.isOnStage ? .speaker : .listener)
        var parts = [person.displayName, role.badgeTitle]
        if speaking { parts.append(L10n.t("rooms.live.a11y.speaking")) }
        return parts.joined(separator: ", ")
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
    }

    // MARK: - The bar

    /// Members' reactions on their way up. Decorative: the emoji says it all.
    private var floatingReactions: some View {
        HStack(alignment: .bottom, spacing: SLSpacing.sm) {
            ForEach(viewModel.reactions.suffix(6)) { reaction in
                Text(reaction.emoji)
                    .font(.system(size: reaction.big ? 65 : 26))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
            listeningCard
            HStack(spacing: SLSpacing.md) {
                SLButton(
                    L10n.t("rooms.live.leave"),
                    variant: .ghost,
                    size: .compact,
                    icon: "rectangle.portrait.and.arrow.forward",
                    accessibilityHint: RoomCopy.leaveHint,
                    action: { leave() }
                )
                .accessibilityIdentifier("guest.room.leave")
                SLButton(
                    RoomCopy.raiseHand,
                    variant: .secondary,
                    size: .compact,
                    icon: "hand.raised.fill",
                    action: { onAsk(.takePart) }
                )
                .accessibilityIdentifier("guest.room.hand")
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

    /// The same strip a member has; for a guest every emoji is the
    /// invitation, and the chat opens to read.
    private var expression: some View {
        HStack(spacing: SLSpacing.xs) {
            ForEach(RoomReaction.palette, id: \.self) { emoji in
                Button { onAsk(.takePart) } label: {
                    Text(emoji)
                        .font(.system(size: 20))
                        .frame(minWidth: 28, idealWidth: 34, maxWidth: 34, minHeight: 34, maxHeight: 34)
                        .background(Circle().fill(SLColor.surface2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("rooms.reactions.send.a11yLabel", emoji)))
                .accessibilityIdentifier("guest.room.reaction.\(emoji)")
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
            .accessibilityIdentifier("guest.room.chat.open")
        }
        .padding(.top, SLSpacing.sm)
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "ear.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SLColor.primary)
                Text(L10n.t("guest.room.listening.title"))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                Spacer(minLength: 0)
            }
            Text(L10n.t("guest.room.listening.subtitle"))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("guest.room.listening.join"))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest.room.listening")
    }

    // MARK: - The chat, to read

    private var chatSheet: some View {
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name.isEmpty ? L10n.t("rooms.chat.someone") : line.name)
                                        .font(SLFont.micro)
                                        .foregroundStyle(SLColor.textSecondary)
                                        .lineLimit(1)
                                    Text(line.text)
                                        .font(SLFont.body)
                                        .foregroundStyle(SLColor.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: line.text))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                .id(line.id)
                            }
                            Text(L10n.t("guest.room.chat.note"))
                                .font(SLFont.micro)
                                .foregroundStyle(SLColor.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, SLSpacing.sm)
                        }
                        .padding(SLSpacing.lg)
                    }
                    .onChange(of: viewModel.chat.count) { _, _ in
                        withAnimation { proxy.scrollTo(viewModel.chat.last?.id, anchor: .bottom) }
                    }
                }
                VStack(spacing: SLSpacing.xs) {
                    Rectangle().fill(SLColor.stroke).frame(height: 1)
                    SLButton(
                        L10n.t("guest.join.takePart.title"),
                        variant: .primary,
                        size: .compact,
                        icon: "person.badge.plus",
                        action: {
                            // The invitation is a sheet of its own: this one
                            // goes first, or it would have nowhere to rise from.
                            viewModel.isChatOpen = false
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                onAsk(.takePart)
                            }
                        }
                    )
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.top, SLSpacing.sm)
                    .accessibilityIdentifier("guest.room.chat.join")
                    Text(L10n.t("rooms.chat.notKept"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SLSpacing.lg)
                        .padding(.bottom, SLSpacing.sm)
                }
                .background(SLColor.surface1)
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
}
