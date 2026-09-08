import SwiftUI

/// One person in a room, on a tap: who they are, what the host may do about
/// them, and — as a choice rather than a consequence — their profile.
///
/// A tap on a tile used to push the profile straight away, which is what a
/// thumb brushing the audience grid did most often. The sheet makes the
/// profile one deliberate tap further, and puts the host's verbs where the
/// host's eye already is.
@MainActor
struct RoomParticipantSheet: View {

    let participant: RoomParticipant
    let hostActions: RoomHostActions?
    let safetyMenu: SafetyMenuActions?
    let isSpeaking: Bool
    let isMuted: Bool
    let onOpenProfile: (@MainActor (String) -> Void)?
    let onPromote: (@MainActor (RoomHostActions) async -> Void)?
    let onDismissHand: (@MainActor (RoomHostActions) async -> Void)?
    let onMute: (@MainActor (RoomHostActions) async -> Void)?
    let onDemote: (@MainActor (RoomHostActions) async -> Void)?
    let onRemove: (@MainActor (RoomHostActions) async -> Void)?
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            identity

            if let hostActions {
                hostVerbs(hostActions)
            }

            HStack(spacing: SLSpacing.md) {
                if let onOpenProfile {
                    SLButton(
                        L10n.t("rooms.live.participant.viewProfile"),
                        variant: hostActions == nil ? .primary : .secondary,
                        size: .compact,
                        icon: "person.crop.circle",
                        action: {
                            onClose()
                            onOpenProfile(participant.user.handle)
                        }
                    )
                }
                if let safetyMenu {
                    SafetyMenuButton(actions: safetyMenu)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tnScreenBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var identity: some View {
        HStack(spacing: SLSpacing.md) {
            ZStack {
                if isSpeaking {
                    Circle().strokeBorder(SLColor.secondary, lineWidth: 3).frame(width: 74, height: 74)
                }
                SLAvatar(
                    url: participant.user.avatarURL,
                    initials: participant.user.initials,
                    size: .lg,
                    isVerified: participant.user.isVerified,
                    displayName: participant.user.displayName
                )
            }
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.user.displayName)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: participant.user.displayName))
                HStack(spacing: SLSpacing.xs) {
                    Text(participant.user.atHandle)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(1)
                    SLCountryBadge(countryCode: participant.user.countryCode)
                }
                Text(roleLine)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var roleLine: String {
        if participant.hasHandRaised { return RoomCopy.handRaised }
        switch participant.role {
        case .host: return L10n.t("rooms.live.participant.role.host")
        case .speaker:
            return isMuted ? L10n.t("rooms.live.participant.role.speakerMuted") : L10n.t("rooms.live.participant.role.speaker")
        case .listener: return L10n.t("rooms.live.participant.role.listener")
        }
    }

    private func hostVerbs(_ actions: RoomHostActions) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("rooms.live.hostMenu.header").uppercased())
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
            if actions.canPromote, let onPromote {
                SLButton(
                    actions.hasHandRaised ? RoomCopy.approveHand : RoomCopy.inviteToMic,
                    variant: .primary,
                    size: .compact,
                    icon: "mic.fill",
                    isLoading: actions.isBusy,
                    asyncAction: { await onPromote(actions); onClose() }
                )
            }
            HStack(spacing: SLSpacing.sm) {
                if actions.canDismissHand, let onDismissHand {
                    SLButton(RoomCopy.dismissHand, variant: .secondary, size: .compact, icon: "hand.raised.slash",
                             isLoading: actions.isBusy, asyncAction: { await onDismissHand(actions); onClose() })
                }
                if actions.canMute, let onMute {
                    SLButton(RoomCopy.muteSpeaker, variant: .secondary, size: .compact, icon: "speaker.slash",
                             isLoading: actions.isBusy, asyncAction: { await onMute(actions) })
                }
                if actions.canDemote, let onDemote {
                    SLButton(RoomCopy.takeMicBack, variant: .secondary, size: .compact, icon: "mic.slash",
                             isLoading: actions.isBusy, asyncAction: { await onDemote(actions); onClose() })
                }
            }
            if actions.canRemove, let onRemove {
                SLButton(L10n.t("rooms.live.hostMenu.remove"), variant: .destructive, size: .compact, icon: "person.slash",
                         isLoading: actions.isBusy, asyncAction: { await onRemove(actions); onClose() })
            }
        }
    }
}
