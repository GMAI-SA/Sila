import CoreTransferable
import Network
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A video picked from Photos, copied where the app can keep it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // The picker's copy lasts only as long as this call: it is
            // copied out before the call returns.
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("sila-pick-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// "Video", beside "Photo" in the composer: the system's picker, videos only,
/// the original file (the app compresses it itself).
@MainActor
struct ComposerVideoButton: View {
    @Bindable var viewModel: ComposerViewModel
    /// Called as the button is pressed, before the picker rises: the
    /// composer puts the keyboard away, so it does not come back over the
    /// video's progress when the picker goes.
    var onPick: () -> Void = {}
    @State private var picked: PhotosPickerItem?
    @State private var isPicking = false

    var body: some View {
        Group {
            #if DEBUG
            if let kind = Self.mockPick {
                // The journeys' picker: a sample made on the phone, so a UI
                // test never depends on what the simulator's library holds.
                Button {
                    onPick()
                    Task {
                        guard let url = try? await SampleVideoFactory.make(kind, in: FileManager.default.temporaryDirectory) else { return }
                        await viewModel.attachVideo(from: url)
                    }
                } label: { label }
            } else {
                picker
            }
            #else
            picker
            #endif
        }
        .accessibilityIdentifier("composer.addVideo")
        .accessibilityHint(Text(L10n.t("video.add.a11yHint")))
    }

    private var picker: some View {
        Button {
            onPick()
            isPicking = true
        } label: { label }
            .photosPicker(isPresented: $isPicking, selection: $picked, matching: .videos, preferredItemEncoding: .current)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                Task {
                    do {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                        await viewModel.attachVideo(from: movie.url)
                    } catch {
                        viewModel.toast = .error(L10n.t("video.error.unreadable"))
                    }
                }
            }
    }

    private var label: some View {
        Label(L10n.t("video.add"), systemImage: "video")
            .font(SLFont.caption)
    }

    #if DEBUG
    /// `-mockVideoPick short|portrait|long|big`.
    static var mockPick: SampleVideoFactory.Kind? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mockVideoPick"), arguments.indices.contains(index + 1) else { return nil }
        return SampleVideoFactory.Kind(rawValue: arguments[index + 1])
    }
    #endif
}

/// The draft's video: its thumbnail, where the upload is, and what can be
/// done about it — or, for a video over three minutes, the way to trim it.
@MainActor
struct ComposerVideoCard: View {
    @Bindable var viewModel: ComposerViewModel

    var body: some View {
        if viewModel.isLoadingVideo {
            HStack(spacing: SLSpacing.sm) {
                ProgressView().tint(SLColor.primary)
                Text(L10n.t("video.status.loading"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("composer.video.loading")
        } else if let refusal = viewModel.videoRefusal {
            refusalCard(refusal)
        } else if let id = viewModel.videoJobId, let center = viewModel.videoUploads {
            attachedCard(id: id, center: center)
        }
    }

    // MARK: - Over three minutes

    private func refusalCard(_ refusal: VideoRefusal) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            HStack(alignment: .top, spacing: SLSpacing.sm) {
                Image(systemName: "scissors")
                    .foregroundStyle(SLColor.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    Text(refusal.message)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t("video.refusal.length", VideoCopy.duration(refusal.durationSeconds)))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("composer.video.tooLong")

            HStack(spacing: SLSpacing.md) {
                if UIVideoEditorController.canEditVideo(atPath: refusal.source.path) {
                    Button(L10n.t("video.trim")) { viewModel.trimRefusedVideo() }
                        .accessibilityIdentifier("composer.video.trim")
                }
                Button(L10n.t("video.trim.firstMinutes")) {
                    Task { await viewModel.useFirstMinutes() }
                }
                .accessibilityIdentifier("composer.video.firstMinutes")
                Spacer(minLength: 0)
                Button(L10n.t("video.remove"), role: .destructive) { viewModel.removeVideo() }
                    .accessibilityIdentifier("composer.video.remove")
            }
            .font(SLFont.caption)
        }
        .padding(SLSpacing.md)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.warning.opacity(0.1)))
    }

    // MARK: - On its way

    private func attachedCard(id: UUID, center: VideoUploadCenter) -> some View {
        let phase = center.phase(id)
        let job = center.job(id)
        return HStack(alignment: .top, spacing: SLSpacing.md) {
            VideoThumbnail(data: center.thumbnail(id), durationSeconds: job?.durationSeconds)
                .frame(width: 96, height: 72)

            // All the width between the thumbnail and the close button, always:
            // beside a spacer the column's width, and so where the words
            // wrap and where the bar sits, changed with every percent.
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                VideoUploadStatusLine(phase: phase)
                if case let .failed(failure)? = phase, failure.canRetry {
                    Button(L10n.t("video.retry")) { viewModel.retryVideo() }
                        .font(SLFont.caption)
                        .accessibilityIdentifier("composer.video.retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.removeVideo()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(SLColor.textPrimary, SLColor.surface2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.t("video.remove")))
            .accessibilityIdentifier("composer.video.remove")
        }
        .padding(SLSpacing.sm)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.video")
    }
}

/// The words and the bar for where an upload is. Shared by the composer and
/// the posts waiting above the feed, so both say the same thing.
@MainActor
struct VideoUploadStatusLine: View {
    let phase: VideoUploadPhase?
    @State private var connection = VideoConnectionWatch.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(words)
                .font(SLFont.caption)
                .foregroundStyle(isFailure ? SLColor.danger : SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let fraction {
                SLProgressBar(value: fraction, tint: waiting ? SLColor.warning : nil, height: 4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(words))
        .accessibilityIdentifier("video.upload.status")
    }

    private var isFailure: Bool {
        if case .failed? = phase { return true }
        return false
    }

    private var waiting: Bool {
        if case .uploading(.waiting)? = phase { return true }
        if case .uploading? = phase, !connection.isOnline { return true }
        return false
    }

    private var fraction: Double? {
        switch phase {
        case let .preparing(value)?: return value
        case let .uploading(activity)?: return activity.fraction
        case .posting?: return 1
        default: return nil
        }
    }

    private var words: String {
        switch phase {
        case let .preparing(value)?:
            return VideoCopy.preparing(value)
        case let .uploading(activity)?:
            if waiting { return L10n.t("video.status.waiting") }
            if case .completing = activity { return L10n.t("video.status.finishing") }
            return VideoCopy.uploading(activity.fraction)
        case .uploaded?:
            return L10n.t("video.status.uploaded")
        case .posting?:
            return L10n.t("video.status.posting")
        case let .failed(failure)?:
            return failure.message
        case nil:
            return VideoCopy.preparing(0)
        }
    }
}

/// Whether the phone has a connection at all — so an upload waiting for one
/// says so, rather than sitting at the same percentage in silence.
@MainActor
@Observable
final class VideoConnectionWatch {
    static let shared = VideoConnectionWatch()
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        guard !AppConfig.isRunningUnitTests else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "sila.video.connection"))
    }
}

/// A still from the video, with its length, filling exactly the frame it is
/// given.
///
/// The still is drawn over a plain fill that takes the frame's size, and cut
/// to it. Laid out on its own, a portrait still scaled to fill a landscape
/// frame is as tall as the frame's width asks, more than twice the frame,
/// and a frame set from outside only centres it: it spilled out of the card
/// it sits in, above and below.
struct VideoThumbnail: View {
    let data: Data?
    let durationSeconds: Double?

    var body: some View {
        SLColor.surface2
            .overlay {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "video").foregroundStyle(SLColor.textMuted)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { length }
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var length: some View {
        if let durationSeconds, durationSeconds > 0 {
            Text(VideoCopy.duration(durationSeconds))
                .font(SLFont.micro)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(4)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// The system's trimming screen, held to three minutes.
struct VideoTrimmerView: UIViewControllerRepresentable {
    let source: URL
    let onTrimmed: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIVideoEditorController {
        let editor = UIVideoEditorController()
        editor.videoPath = source.path
        editor.videoMaximumDuration = VideoLimits.trimDuration
        editor.videoQuality = .typeHigh
        editor.delegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ controller: UIVideoEditorController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIVideoEditorControllerDelegate {
        private let parent: VideoTrimmerView
        /// The editor has been known to report a save twice.
        private var finished = false

        init(_ parent: VideoTrimmerView) { self.parent = parent }

        func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath editedVideoPath: String) {
            guard !finished else { return }
            finished = true
            parent.onTrimmed(URL(fileURLWithPath: editedVideoPath))
        }

        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) {
            guard !finished else { return }
            finished = true
            parent.onCancel()
        }

        func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: Error) {
            guard !finished else { return }
            finished = true
            parent.onCancel()
        }
    }
}

/// Posts waiting for their video, above the feed: how far each upload is,
/// and what can be done when one has stopped. Said in the author's own
/// words — nobody else sees these.
@MainActor
public struct PendingVideoPostsStrip: View {
    @Environment(\.videoUploadCenter) private var center
    @State private var confirming: UUID?

    public init() {}

    public var body: some View {
        if let center, !center.pendingPosts.isEmpty {
            VStack(spacing: SLSpacing.sm) {
                ForEach(center.pendingPosts) { job in
                    row(job, center: center)
                }
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.sm)
            .confirmationDialog(
                L10n.t("video.pending.discard.title"),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                Button(L10n.t("video.pending.discard.confirm"), role: .destructive) {
                    if let id = confirming { center.discard(id) }
                    confirming = nil
                }
                Button(L10n.t("common.cancel"), role: .cancel) { confirming = nil }
            }
        }
    }

    private func row(_ job: VideoUploadJob, center: VideoUploadCenter) -> some View {
        let phase = center.phase(job.id)
        return HStack(alignment: .top, spacing: SLSpacing.md) {
            VideoThumbnail(data: center.thumbnail(job.id), durationSeconds: job.durationSeconds)
                .frame(width: 72, height: 54)
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                if let text = job.pendingPost?.text, !text.isEmpty {
                    Text(text)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(1)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: text))
                }
                VideoUploadStatusLine(phase: phase)
                if case let .failed(failure)? = phase {
                    HStack(spacing: SLSpacing.md) {
                        if failure.canRetry {
                            Button(L10n.t("video.retry")) { center.retry(job.id) }
                                .accessibilityIdentifier("video.pending.retry")
                        }
                        Button(L10n.t("video.pending.discard"), role: .destructive) { confirming = job.id }
                            .accessibilityIdentifier("video.pending.discard")
                    }
                    .font(SLFont.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SLSpacing.sm)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.t("video.pending.a11yLabel")))
        .accessibilityIdentifier("video.pending")
    }
}
