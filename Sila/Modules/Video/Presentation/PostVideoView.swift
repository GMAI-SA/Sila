import SwiftUI

/// A post's video, wherever a post is drawn.
///
/// A `ready` video is a poster with a play button, which plays in place and
/// opens full screen. Anything else is shown to its author only — nobody
/// else is ever sent a post whose video is not ready — as the words for where
/// it stands, watched until it is ready (contract v28 §11).
@MainActor
public struct PostVideoView: View {

    private let video: PostVideo
    private let isAuthor: Bool
    private let isDetail: Bool

    @Environment(\.videoStatusBoard) private var board
    @State private var isWatching = false

    public init(video: PostVideo, isAuthor: Bool, isDetail: Bool = false) {
        self.video = video
        self.isAuthor = isAuthor
        self.isDetail = isDetail
    }

    private var current: PostVideo { board?.current(video) ?? video }

    public var body: some View {
        Group {
            if current.isPlayable {
                VideoPlayerCard(video: current, isDetail: isDetail)
                    // A new copy of the video — ready now — is a new player.
                    .id(current.id.uuidString + current.status.rawValue)
            } else if isAuthor, let notice = VideoCopy.authorNotice(for: current) {
                VideoStatusNotice(video: current, text: notice)
            }
        }
        .onAppear {
            guard isAuthor, !current.status.isSettled, !isWatching, let board else { return }
            isWatching = true
            board.watch(video)
        }
        .onDisappear {
            guard isWatching else { return }
            isWatching = false
            board?.unwatch(video.id)
        }
    }
}

/// The author's own words for a video that is not ready: preparing, being
/// reviewed, failed or removed.
@MainActor
struct VideoStatusNotice: View {
    let video: PostVideo
    let text: String

    private var icon: String {
        switch video.status {
        case .processing, .uploading: return "film"
        case .held: return "eye"
        case .failed: return "exclamationmark.triangle.fill"
        case .removed: return "shield.lefthalf.filled"
        case .ready: return "play.rectangle"
        }
    }

    private var tint: Color {
        switch video.status {
        case .failed, .removed: return SLColor.danger
        case .held: return SLColor.warning
        default: return SLColor.primary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: SLSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous)
                    .fill(tint.opacity(0.12))
                if video.status == .processing {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text(text)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let seconds = video.durationSeconds, seconds > 0 {
                    Text(VideoCopy.duration(seconds))
                        .font(SLFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(SLColor.textMuted)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(SLSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous)
                .fill(SLColor.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
        .accessibilityIdentifier("video.status.\(video.status.rawValue)")
    }
}

/// A ready video in a card: the poster until it plays, then the picture with
/// a small row of controls — play, sound, captions, full screen.
@MainActor
struct VideoPlayerCard: View {
    let video: PostVideo
    let isDetail: Bool

    @State private var model: VideoPlaybackModel
    @State private var isFullscreen = false
    private let coordinator = VideoAutoplayCoordinator.shared

    init(video: PostVideo, isDetail: Bool) {
        self.video = video
        self.isDetail = isDetail
        self._model = State(initialValue: VideoPlaybackModel(video: video))
    }

    var body: some View {
        ZStack {
            Color.black

            if model.hasStarted {
                VideoSurface(player: model.player)
            } else {
                poster
            }

            // Behind the controls, not an `onTapGesture` over them: a tap
            // gesture on an ancestor takes the taps meant for the captions
            // menu inside it.
            Button { model.togglePlay() } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let caption = model.caption {
                    VideoCaptionText(text: caption, language: model.captionLanguage, isLarge: false)
                        .padding(.horizontal, SLSpacing.sm)
                        .padding(.bottom, SLSpacing.xs)
                }
                controlBar
            }

            if !model.isPlaying {
                playButton
            } else if model.isBuffering {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(video.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isDetail ? 560 : 440)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))
        .background(visibilityReporter)
        .onChange(of: coordinator.activeCard) { _, active in
            if active == model.card {
                if !model.isPlaying, !model.pausedByUser { model.play(muted: true, autoplay: true) }
            } else if model.isPlaying, model.isAutoplaying {
                model.pause(byUser: false)
            }
        }
        .onDisappear {
            // Covering the card with its own full-screen player is not the
            // card going away: the same player carries on up there.
            guard !isFullscreen else { return }
            coordinator.withdraw(model.card)
            model.tearDown()
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            VideoFullscreenView(model: model, onClose: { isFullscreen = false })
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(SLFont.micro)
                    .foregroundStyle(.white)
                    .padding(.horizontal, SLSpacing.sm)
                    .padding(.vertical, SLSpacing.xs)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .padding(SLSpacing.sm)
                    .transition(.opacity)
            }
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { model.notice = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.t("video.a11y.label", VideoCopy.duration(video.durationSeconds))))
        .accessibilityIdentifier("video.card")
    }

    private var poster: some View {
        AsyncImage(url: video.posterURL) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFit()
            default:
                SLColor.surface2
            }
        }
        .accessibilityHidden(true)
    }

    private var playButton: some View {
        Button {
            model.togglePlay()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t("video.play")))
        .accessibilityValue(Text(VideoCopy.duration(video.durationSeconds)))
        .accessibilityIdentifier("video.play")
    }

    private var controlBar: some View {
        HStack(spacing: SLSpacing.md) {
            if model.hasStarted {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(Text(L10n.t(model.isPlaying ? "video.pause" : "video.play")))
                .accessibilityIdentifier("video.playPause")
            }

            Text(VideoCopy.duration(max(0, model.duration - model.elapsed)))
                .font(SLFont.micro)
                .monospacedDigit()
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            if !video.captions.isEmpty {
                VideoCaptionsMenu(model: model)
            }

            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .accessibilityLabel(Text(L10n.t(model.isMuted ? "video.unmute" : "video.mute")))
            .accessibilityIdentifier("video.mute")

            Button {
                if !model.isPlaying { model.play(muted: false) }
                isFullscreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(Text(L10n.t("video.fullscreen")))
            .accessibilityIdentifier("video.fullscreen")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, SLSpacing.md)
        .padding(.vertical, SLSpacing.sm)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        )
        // Time and the controls run left to right in both languages, like a
        // clock and like every player.
        .environment(\.layoutDirection, .leftToRight)
    }

    /// Tells the coordinator where the card is, so the one most in view may
    /// play by itself — and so a card scrolled away stops.
    private var visibilityReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { coordinator.report(model.card, frame: proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in
                    coordinator.report(model.card, frame: frame)
                    if model.isPlaying, !isFullscreen, coordinator.visibleFraction(model.card) < 0.2 {
                        model.pause(byUser: false)
                    }
                }
        }
    }
}

/// Off, or one of the video's caption tracks — each named as automatic.
@MainActor
struct VideoCaptionsMenu: View {
    let model: VideoPlaybackModel

    var body: some View {
        Menu {
            Button {
                Task { await model.selectCaptions(nil) }
            } label: {
                if model.captionLanguage == nil {
                    Label(L10n.t("video.captions.off"), systemImage: "checkmark")
                } else {
                    Text(L10n.t("video.captions.off"))
                }
            }
            ForEach(model.video.captions, id: \.language) { track in
                Button {
                    Task { await model.selectCaptions(track.language) }
                } label: {
                    if model.captionLanguage == track.language {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            Image(systemName: model.captionLanguage == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .accessibilityLabel(Text(L10n.t("video.captions.menu")))
        .accessibilityValue(Text(model.captionLanguage.map(VideoCopy.captionLabel) ?? L10n.t("video.captions.off")))
        .accessibilityIdentifier("video.captions")
    }
}

/// A caption line, in its own direction: Arabic from the right even on an
/// English phone.
struct VideoCaptionText: View {
    let text: String
    let language: String?
    let isLarge: Bool

    var body: some View {
        Text(text)
            .font(isLarge ? SLFont.bodyEmphasis : SLFont.caption)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, SLSpacing.sm)
            .padding(.vertical, SLSpacing.xs)
            .background(RoundedRectangle(cornerRadius: SLRadius.sm).fill(.black.opacity(0.7)))
            .slContentDirection(TextDirection.resolve(languageCode: language, text: text))
            .accessibilityIdentifier("video.caption")
    }
}

/// The same player, over everything: the picture, a scrubber, and the
/// controls, which hide while it plays and come back with a tap.
@MainActor
struct VideoFullscreenView: View {
    let model: VideoPlaybackModel
    let onClose: () -> Void

    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: model.player)
                .ignoresSafeArea()
            // A tap on the picture shows or hides the controls; a button
            // underneath them, so the captions menu keeps its own taps.
            Button {
                showsControls.toggle()
                scheduleHide()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack {
                Spacer()
                if let caption = model.caption {
                    VideoCaptionText(text: caption, language: model.captionLanguage, isLarge: true)
                        .padding(.horizontal, SLSpacing.lg)
                        .padding(.bottom, showsControls ? SLSpacing.sm : SLSpacing.xxl)
                }
                if showsControls { bottomControls }
            }

            if showsControls {
                VStack {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(.black.opacity(0.5)))
                        }
                        .accessibilityLabel(Text(L10n.t("video.fullscreen.close")))
                        .accessibilityIdentifier("video.fullscreen.close")
                        Spacer()
                    }
                    .padding(SLSpacing.lg)
                    Spacer()
                }

                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.black.opacity(0.5)))
                }
                .accessibilityLabel(Text(L10n.t(model.isPlaying ? "video.pause" : "video.play")))
                .accessibilityIdentifier("video.fullscreen.playPause")
            }
        }
        .onAppear { scheduleHide() }
        .onChange(of: model.isPlaying) { _, _ in scheduleHide() }
        .statusBarHidden(!showsControls)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityAction(.escape, onClose)
    }

    private var bottomControls: some View {
        VStack(spacing: SLSpacing.sm) {
            Slider(
                value: Binding(
                    get: { model.duration > 0 ? model.elapsed / model.duration : 0 },
                    set: { model.seek(to: $0) }
                )
            )
            .tint(SLColor.primary)
            .accessibilityLabel(Text(L10n.t("video.scrubber")))
            .accessibilityValue(Text(L10n.t(
                "video.scrubber.value",
                VideoCopy.duration(model.elapsed),
                VideoCopy.duration(model.duration)
            )))

            HStack(spacing: SLSpacing.lg) {
                Text("\(VideoCopy.duration(model.elapsed)) / \(VideoCopy.duration(model.duration))")
                    .font(SLFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Spacer()
                if !model.video.captions.isEmpty {
                    VideoCaptionsMenu(model: model)
                }
                Button { model.toggleMute() } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .accessibilityLabel(Text(L10n.t(model.isMuted ? "video.unmute" : "video.mute")))
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    /// While it plays, the controls step aside after three seconds — unless
    /// VoiceOver is reading them.
    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying, showsControls, !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsControls = false }
        }
    }
}

/// "Video" on a quoted post: the quote card has no room for a player, and
/// the post is one tap away.
struct QuotedVideoLabel: View {
    let video: PostVideo

    var body: some View {
        Label(L10n.t("video.quoted", VideoCopy.duration(video.durationSeconds)), systemImage: "play.rectangle")
            .font(SLFont.micro)
            .foregroundStyle(SLColor.textSecondary)
    }
}
