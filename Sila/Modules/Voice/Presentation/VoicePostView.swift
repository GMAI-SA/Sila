import SwiftUI

/// Hot Take stances from wherever a voice post is drawn.
public struct VoiceActions {
    public var setStance: @MainActor (_ stance: VoiceStances.Stance?, _ postId: UUID) async throws -> VoiceStances

    public init(setStance: @escaping @MainActor (_ stance: VoiceStances.Stance?, _ postId: UUID) async throws -> VoiceStances) {
        self.setStance = setStance
    }
}

private struct VoiceActionsKey: EnvironmentKey {
    static let defaultValue: VoiceActions? = nil
}

extension EnvironmentValues {
    /// How a Hot Take's agree / disagree is sent. `nil` draws the bar read-only.
    public var voiceActions: VoiceActions? {
        get { self[VoiceActionsKey.self] }
        set { self[VoiceActionsKey.self] = newValue }
    }
}

/// The waveform: 100 peaks, played part tinted. Tap or drag to scrub.
struct WaveformView: View {
    let peaks: [Int]
    let progress: Double
    let tint: Color
    var onScrub: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let bars = peaks.isEmpty ? Array(repeating: 40, count: 50) : peaks
            let spacing: CGFloat = 1.5
            let width = max(1, (geo.size.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, peak in
                    let played = Double(index) / Double(bars.count) < progress
                    Capsule()
                        .fill(played ? tint : SLColor.textMuted.opacity(0.45))
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(peak) / 255))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    onScrub?(Double(value.location.x / max(geo.size.width, 1)))
                }
            )
        }
        // A waveform is drawn left to right in time, whatever the language.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// A voice post on a card: play, waveform, speed, caption with its label, and
/// for a Hot Take the agree / disagree bar.
@MainActor
public struct VoicePostView: View {

    private let postId: UUID
    private let clip: VoiceClip
    private let isDetail: Bool
    private let canTakeStance: Bool

    @Environment(\.voiceActions) private var actions
    @State private var player = VoicePlayer.shared
    @State private var stances: VoiceStances?
    @State private var isVoting = false
    @State private var error: String?

    public init(postId: UUID, clip: VoiceClip, isDetail: Bool = false, canTakeStance: Bool = true) {
        self.postId = postId
        self.clip = clip
        self.isDetail = isDetail
        self.canTakeStance = canTakeStance
    }

    private var isCurrent: Bool { player.currentId == clip.id }
    private var isPlaying: Bool { isCurrent && player.isPlaying }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.md) {
                Button { player.toggle(clip) } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(SLColor.primary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t(isPlaying ? "voice.pause" : "voice.play")))
                .accessibilityValue(Text(VoiceTime.label(clip.duration)))
                .accessibilityIdentifier("voice.play")

                WaveformView(
                    peaks: clip.peaks,
                    progress: isCurrent ? player.progress : 0,
                    tint: SLColor.primary,
                    onScrub: { fraction in player.seek(to: fraction, in: clip) }
                )
                .frame(height: isDetail ? 44 : 32)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(VoiceTime.label(isCurrent ? clip.duration * (1 - player.progress) : clip.duration))
                        .font(SLFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(SLColor.textSecondary)
                    Button { player.cycleSpeed() } label: {
                        Text(speedLabel)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.t("voice.speed.a11yLabel", speedLabel)))
                }
            }
            .padding(SLSpacing.sm)
            .background(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous).fill(SLColor.surface1))

            if let label = clip.captionLabel {
                VStack(alignment: .leading, spacing: 2) {
                    if let caption = clip.caption {
                        Text(caption)
                            .font(isDetail ? SLFont.body : SLFont.caption)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(isDetail ? nil : 3)
                            .slContentDirection(TextDirection.resolve(languageCode: clip.captionLanguage, text: caption))
                    }
                    Text(label)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
            }

            if clip.kind == .hotTake {
                hotTakeBar
            }
        }
        .onAppear { stances = clip.stances }
    }

    private var speedLabel: String {
        let value = player.speed
        return value == 1 ? "1×" : (value == 1.5 ? "1.5×" : "2×")
    }

    // MARK: Hot Take

    @ViewBuilder
    private var hotTakeBar: some View {
        let current = stances ?? clip.stances ?? VoiceStances()
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(SLColor.secondary).frame(width: geo.size.width * current.agreeShare)
                    Rectangle().fill(SLColor.danger)
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)

            HStack {
                stanceButton(.agree, count: current.agree, selected: current.viewerStance == .agree)
                Spacer(minLength: 0)
                stanceButton(.disagree, count: current.disagree, selected: current.viewerStance == .disagree)
            }
            if let error {
                Text(error).font(SLFont.micro).foregroundStyle(SLColor.danger)
            }
        }
    }

    private func stanceButton(_ stance: VoiceStances.Stance, count: Int, selected: Bool) -> some View {
        Button {
            Task { await vote(selected ? nil : stance) }
        } label: {
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: stance == .agree ? "hand.thumbsup" : "hand.thumbsdown")
                Text(L10n.t(stance == .agree ? "voice.hotTake.agree" : "voice.hotTake.disagree"))
                Text(SLFormat.compactCount(count)).monospacedDigit()
            }
            .font(selected ? SLFont.bodyEmphasis : SLFont.caption)
            .foregroundStyle(stance == .agree ? SLColor.secondary : SLColor.danger)
        }
        .buttonStyle(.plain)
        .disabled(actions == nil || !canTakeStance || isVoting)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("voice.hotTake.\(stance.rawValue)")
    }

    private func vote(_ stance: VoiceStances.Stance?) async {
        guard let actions else { return }
        isVoting = true
        error = nil
        defer { isVoting = false }
        do {
            stances = try await actions.setStance(stance, postId)
        } catch {
            let wrapped = APIError.wrapping(error)
            if !wrapped.isCancellation { self.error = wrapped.userMessage }
        }
    }
}

/// The recording attached to a draft, with a way to take it off.
struct AttachedVoiceChip: View {
    let clip: VoiceClip
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "waveform").foregroundStyle(SLColor.primary).accessibilityHidden(true)
            Text(L10n.t("voice.attached", clip.kind.title, VoiceTime.label(clip.duration)))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(SLColor.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.t("voice.remove")))
            .accessibilityIdentifier("composer.voice.remove")
        }
        .padding(SLSpacing.sm)
        .background(Capsule().fill(SLColor.surface1))
    }
}
