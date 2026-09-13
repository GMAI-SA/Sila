import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// An animated GIF in a post or a picker.
///
/// Decoded and driven by ImageIO (`CGAnimateImageDataWithBlock`), which
/// handles the frame timing and the memory, rather than a video player: a
/// player takes over the audio session, and this app has voice rooms whose
/// session must not be touched by a feed scrolling past a cat. Animation
/// stops the moment the view leaves the window, so a long feed does not keep
/// a hundred GIFs ticking behind the screen.
public struct GifMediaView: View {
    private let gif: Gif
    private let maxHeight: CGFloat

    /// - Parameters:
    ///   - gif: What to show.
    ///   - maxHeight: The tallest a card lets it be; the width is the card's.
    public init(_ gif: Gif, maxHeight: CGFloat = 320) {
        self.gif = gif
        self.maxHeight = maxHeight
    }

    public var body: some View {
        // The frame is known before a byte arrives, so the feed does not
        // reflow as pictures load.
        Color.clear
            .aspectRatio(gif.aspectRatio, contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .overlay {
                ZStack {
                    SLColor.surface2
                    if gif.isVideo && gif.gifURL == nil && gif.previewURL == nil {
                        LoopingVideoView(url: gif.url)
                    } else {
                        AnimatedGifView(url: gif.gifURL ?? gif.previewURL ?? gif.url, stillURL: gif.stillURL)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text("GIF")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(SLSpacing.sm)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(gif.title.map { L10n.t("post.gif.a11yLabelTitled", $0) } ?? L10n.t("post.gif.a11yLabel")))
            .accessibilityAddTraits(.isImage)
    }
}

/// A GIF driven by ImageIO. Shows the still frame, when there is one, until
/// the animation has been fetched.
struct AnimatedGifView: UIViewRepresentable {
    let url: URL
    var stillURL: URL? = nil

    func makeUIView(context: Context) -> AnimatedGifUIView {
        let view = AnimatedGifUIView(frame: .zero)
        view.load(url, still: stillURL)
        return view
    }

    func updateUIView(_ view: AnimatedGifUIView, context: Context) {
        view.load(url, still: stillURL)
    }
}

final class AnimatedGifUIView: UIImageView {

    private var currentURL: URL?
    private var fetch: Task<Void, Never>?
    private var data: Data?
    /// Bumped whenever the animation must stop; the running block compares.
    private var generation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func load(_ url: URL, still: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        stop()
        image = nil
        data = nil
        fetch?.cancel()
        fetch = Task { [weak self] in
            if let still, let (stillData, _) = try? await URLSession.shared.data(from: still), !Task.isCancelled {
                await MainActor.run { [weak self] in
                    if self?.data == nil { self?.image = UIImage(data: stillData) }
                }
            }
            guard let (bytes, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == url else { return }
                self.data = bytes
                self.startIfVisible()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { startIfVisible() }
    }

    private func startIfVisible() {
        guard window != nil, let data else { return }
        generation += 1
        let mine = generation
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
            guard let self, self.generation == mine, self.window != nil else {
                stop.pointee = true
                return
            }
            self.image = UIImage(cgImage: frame)
        }
        if status != noErr {
            // Not animatable (a single-frame GIF, or something else entirely):
            // show whatever it is once.
            image = UIImage(data: data)
        }
    }

    private func stop() {
        generation += 1
    }

    deinit {
        fetch?.cancel()
    }
}

/// A muted looping video, for the rare GIF whose only rendition is an mp4.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView()
        view.load(url)
        return view
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {
        view.load(url)
    }
}

final class LoopingPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        if window != nil { player.play() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { player?.pause() } else { player?.play() }
    }
}
