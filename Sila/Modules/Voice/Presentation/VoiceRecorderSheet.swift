import SwiftUI

/// Recording one's own voice post.
///
/// Says, before anything is recorded, whose voice this is and where it goes —
/// and that rooms are a different thing and are never recorded.
@MainActor
public struct VoiceRecorderSheet: View {

    @Bindable private var viewModel: VoiceRecorderViewModel
    private let showsKinds: Bool
    private let onClose: @MainActor () -> Void

    public init(viewModel: VoiceRecorderViewModel, showsKinds: Bool = true, onClose: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        self.showsKinds = showsKinds
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SLSpacing.lg) {
                    if showsKinds { kindChips }

                    Text(viewModel.kind.prompt)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)

                    levelBars

                    Text(clock)
                        .font(SLFont.displayM)
                        .monospacedDigit()
                        .foregroundStyle(viewModel.isRecording && viewModel.remaining < 10 ? SLColor.danger : SLColor.textPrimary)
                        .accessibilityLabel(Text(L10n.t("voice.remaining.a11yLabel", VoiceTime.label(viewModel.remaining))))

                    controls

                    if case let .uploading(fraction) = viewModel.phase {
                        ProgressView(value: fraction)
                            .tint(SLColor.primary)
                            .accessibilityLabel(Text(L10n.t("voice.uploading")))
                    }

                    if let clip = viewModel.uploadedClip { captionEditor(clip) }

                    if viewModel.micDenied {
                        Text(L10n.t("voice.micDenied"))
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.warning)
                            .multilineTextAlignment(.center)
                    }

                    Text(L10n.t("voice.promise"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(SLSpacing.lg)
            }
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("voice.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.cancel")) {
                        viewModel.cancel()
                        onClose()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("voice.use")) {
                        viewModel.use()
                        onClose()
                    }
                    .disabled(viewModel.uploadedClip == nil)
                    .accessibilityIdentifier("voice.use")
                }
            }
            .tnToast($viewModel.toast)
        }
        .tint(SLColor.primary)
        .interactiveDismissDisabled(viewModel.phase != .idle)
    }

    private var clock: String {
        switch viewModel.phase {
        case let .recorded(_, seconds): return VoiceTime.label(seconds)
        case let .uploaded(clip): return VoiceTime.label(clip.duration)
        default: return VoiceTime.label(viewModel.isRecording ? viewModel.remaining : TimeInterval(viewModel.kind.maxSeconds))
        }
    }

    private var kindChips: some View {
        HStack(spacing: SLSpacing.sm) {
            ForEach(VoiceKind.allCases) { kind in
                Button { viewModel.kind = kind } label: {
                    Text(kind.title)
                        .font(SLFont.caption)
                        .foregroundStyle(viewModel.kind == kind ? .white : SLColor.textPrimary)
                        .padding(.horizontal, SLSpacing.md)
                        .padding(.vertical, SLSpacing.sm)
                        .background(Capsule().fill(viewModel.kind == kind ? SLColor.primary : SLColor.surface1))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canChangeKind)
                .accessibilityAddTraits(viewModel.kind == kind ? .isSelected : [])
                .accessibilityIdentifier("voice.kind.\(kind.rawValue)")
            }
        }
    }

    private var levelBars: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(viewModel.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(viewModel.isRecording ? SLColor.danger : SLColor.textMuted.opacity(0.4))
                    .frame(width: 5, height: 6 + CGFloat(level) * 54)
            }
        }
        .frame(height: 64)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.phase {
        case .idle, .recording, .failed:
            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                ZStack {
                    Circle().fill(SLColor.danger.opacity(0.15)).frame(width: 96, height: 96)
                    if viewModel.isRecording {
                        RoundedRectangle(cornerRadius: 8).fill(SLColor.danger).frame(width: 34, height: 34)
                    } else {
                        Circle().fill(SLColor.danger).frame(width: 64, height: 64)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.t(viewModel.isRecording ? "voice.stop" : "voice.record")))
            .accessibilityIdentifier("voice.record")
            if case let .failed(message) = viewModel.phase {
                Text(message).font(SLFont.caption).foregroundStyle(SLColor.danger)
            }
        case .recorded:
            HStack(spacing: SLSpacing.xl) {
                Button(L10n.t("voice.retake")) { viewModel.retake() }
                    .accessibilityIdentifier("voice.retake")
                Button(L10n.t(viewModel.isPlayingBack ? "voice.pause" : "voice.listen")) { viewModel.togglePlayback() }
                SLButton(L10n.t("voice.upload")) { Task { await viewModel.upload() } }
                    .frame(width: 140)
                    .accessibilityIdentifier("voice.upload")
            }
            .font(SLFont.bodyEmphasis)
        case .uploading:
            EmptyView()
        case .uploaded:
            Button(L10n.t("voice.retake")) { viewModel.retake() }
                .font(SLFont.caption)
        }
    }

    private func captionEditor(_ clip: VoiceClip) -> some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack {
                    Text(L10n.t("voice.caption.title")).font(SLFont.bodyEmphasis)
                    Spacer(minLength: 0)
                    if let label = clip.captionLabel {
                        Text(label).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    }
                }
                if clip.captionStatus == .pending {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    TextField(L10n.t("voice.caption.placeholder"), text: $viewModel.captionDraft, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("voice.caption.field")
                    HStack(spacing: SLSpacing.md) {
                        Button(L10n.t("voice.caption.save")) { Task { await viewModel.saveCaption() } }
                            .disabled(viewModel.isSavingCaption || viewModel.captionDraft == (clip.caption ?? ""))
                        Button(L10n.t("voice.caption.remove"), role: .destructive) { Task { await viewModel.removeCaption() } }
                            .disabled(viewModel.isSavingCaption || clip.caption == nil)
                        Menu(L10n.t("voice.caption.redo")) {
                            Button(L10n.t("voice.caption.redo.ar")) { Task { await viewModel.redoCaption(language: "ar") } }
                            Button(L10n.t("voice.caption.redo.en")) { Task { await viewModel.redoCaption(language: "en") } }
                        }
                    }
                    .font(SLFont.caption)
                }
            }
        }
    }
}
