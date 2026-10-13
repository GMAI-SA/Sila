import SwiftUI
import UIKit

// MARK: - The pictures' cache

/// Decoded pictures, by attachment id — never by URL, which changes every
/// ten minutes (contract v39 §4).
final class ChatImageCache: @unchecked Sendable {

    static let shared = ChatImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        return cache
    }()

    private func key(_ id: UUID, thumbnail: Bool) -> NSString {
        "\(id.uuidString)|\(thumbnail ? "t" : "f")" as NSString
    }

    func image(_ id: UUID, thumbnail: Bool) -> UIImage? {
        cache.object(forKey: key(id, thumbnail: thumbnail))
    }

    func store(_ image: UIImage, _ id: UUID, thumbnail: Bool) {
        cache.setObject(image, forKey: key(id, thumbnail: thumbnail))
    }
}

/// Loads one picture of a message: its thumbnail in the thread, the full
/// picture in the viewer.
struct ChatAttachmentImage: View {

    let attachment: ChatAttachment
    let thumbnail: Bool
    var contentMode: ContentMode = .fill
    let load: @MainActor (ChatAttachment, Bool) async throws -> Data

    @State private var image: UIImage?
    @State private var failed = false

    init(
        attachment: ChatAttachment,
        thumbnail: Bool,
        contentMode: ContentMode = .fill,
        load: @escaping @MainActor (ChatAttachment, Bool) async throws -> Data
    ) {
        self.attachment = attachment
        self.thumbnail = thumbnail
        self.contentMode = contentMode
        self.load = load
        // A picture seen before shows at once, with no flash of grey.
        _image = State(initialValue: ChatImageCache.shared.image(attachment.id, thumbnail: thumbnail)
            ?? (thumbnail ? nil : ChatImageCache.shared.image(attachment.id, thumbnail: true)))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                SLColor.surface2
                if failed {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(SLColor.textMuted)
                } else {
                    ProgressView()
                        .tint(SLColor.textSecondary)
                }
            }
        }
        .task(id: attachment.id) { await fetch() }
    }

    private func fetch() async {
        if let cached = ChatImageCache.shared.image(attachment.id, thumbnail: thumbnail) {
            image = cached
            return
        }
        do {
            let data = try await load(attachment, thumbnail)
            guard let decoded = UIImage(data: data) else {
                failed = image == nil
                return
            }
            ChatImageCache.shared.store(decoded, attachment.id, thumbnail: thumbnail)
            image = decoded
        } catch {
            failed = image == nil
        }
    }
}

// MARK: - In a bubble

/// A message's pictures (a grid) and documents (rows), above its words.
struct ChatMessageAttachmentsView: View {

    let message: DirectMessage
    let mine: Bool
    let openingDocumentId: UUID?
    let load: @MainActor (ChatAttachment, Bool) async throws -> Data
    let onOpenPicture: (Int) -> Void
    let onOpenDocument: (ChatAttachment) -> Void

    private static let width: CGFloat = 228
    private static let gap: CGFloat = 4

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: SLSpacing.xs) {
            let pictures = message.pictures
            if pictures.count == 1, let only = pictures.first {
                single(only)
            } else if pictures.count > 1 {
                grid(pictures)
            }
            ForEach(message.documents) { document in
                ChatDocumentRow(
                    attachment: document,
                    mine: mine,
                    isOpening: openingDocumentId == document.id,
                    onOpen: { onOpenDocument(document) }
                )
            }
        }
    }

    private func single(_ picture: ChatAttachment) -> some View {
        // Laid out at its own shape before it arrives, within reason.
        let ratio = min(2, max(0.5, picture.aspectRatio ?? 1))
        return Button {
            onOpenPicture(0)
        } label: {
            Color.clear
                .frame(width: Self.width, height: Self.width / ratio)
                .overlay { ChatAttachmentImage(attachment: picture, thumbnail: true, load: load) }
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ChatFileCopy.label(for: .image)))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("chat.attachment.picture")
    }

    private func grid(_ pictures: [ChatAttachment]) -> some View {
        let side = (Self.width - Self.gap) / 2
        let rows = stride(from: 0, to: pictures.count, by: 2).map { Array(pictures[$0..<min($0 + 2, pictures.count)]) }
        return VStack(spacing: Self.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Self.gap) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { column, picture in
                        Button {
                            onOpenPicture(rowIndex * 2 + column)
                        } label: {
                            Color.clear
                                .frame(width: side, height: side)
                                .overlay { ChatAttachmentImage(attachment: picture, thumbnail: true, load: load) }
                                .clipShape(RoundedRectangle(cornerRadius: SLRadius.sm, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(ChatFileCopy.label(for: .image)))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("chat.attachment.picture")
                    }
                    if row.count == 1 {
                        Color.clear.frame(width: side, height: side)
                    }
                }
            }
        }
    }
}

/// One document: its kind's icon, its name and its size. Tapping opens it.
struct ChatDocumentRow: View {

    let attachment: ChatAttachment
    let mine: Bool
    let isOpening: Bool
    let onOpen: () -> Void

    private var ink: Color { mine ? Color(tnHex: 0x02121C) : SLColor.textPrimary }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: Self.symbol(for: attachment.fileExtension))
                    .font(.system(size: 24))
                    .foregroundStyle(ink)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename.isEmpty ? ChatFileCopy.label(for: .document) : attachment.filename)
                        .font(SLFont.caption.weight(.semibold))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(Self.details(attachment))
                        .font(SLFont.micro)
                        .foregroundStyle(ink.opacity(0.7))
                }

                Spacer(minLength: 0)

                if isOpening {
                    ProgressView()
                        .tint(ink)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(ink.opacity(0.8))
                }
            }
            .padding(SLSpacing.sm)
            .frame(width: 228, alignment: .leading)
            .background(ink.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(attachment.filename), \(Self.details(attachment))"))
        .accessibilityHint(Text(L10n.t("messages.files.open")))
        .accessibilityIdentifier("chat.attachment.document")
    }

    static func details(_ attachment: ChatAttachment) -> String {
        let size = SLFormat.fileSize(attachment.sizeBytes)
        let ext = attachment.fileExtension.uppercased()
        return ext.isEmpty ? size : "\(ext) · \(size)"
    }

    static func symbol(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "xlsx", "csv": return "tablecells"
        case "pptx": return "play.rectangle"
        case "txt": return "doc.plaintext"
        default: return "doc.text"
        }
    }
}

// MARK: - In the composer

/// The files waiting to go, above the text field: progress, failure (tap to
/// retry), and a remove button on each.
struct ChatComposerFilesTray: View {

    let files: [ChatDraftFile]
    let onRetry: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SLSpacing.sm) {
                    ForEach(files) { file in
                        ChatDraftFileTile(file: file, onRetry: { onRetry(file.id) }, onRemove: { onRemove(file.id) })
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.sm)
            }

            if let failure = files.lazy.compactMap({ $0.failure }).first {
                Text(verbatim: Self.sentence(for: failure))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.danger)
                    .padding(.horizontal, SLSpacing.lg)
                    .accessibilityIdentifier("chat.files.error")
            } else if files.contains(where: \.isUploading) {
                Text(L10n.t("messages.files.uploading"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .padding(.horizontal, SLSpacing.lg)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.files")
    }

    /// The reason, then "Couldn't send. Tap to retry." when trying again can
    /// help — once, when the reason is that sentence already.
    static func sentence(for failure: (message: String, retryable: Bool)) -> String {
        let retry = L10n.t("messages.files.failed")
        guard failure.retryable, failure.message != retry else { return failure.message }
        return "\(failure.message) \(retry)"
    }
}

/// One waiting file.
struct ChatDraftFileTile: View {

    let file: ChatDraftFile
    let onRetry: () -> Void
    let onRemove: () -> Void

    @State private var preview: UIImage?

    private static let side: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topTrailing) {
            tile
                .frame(width: file.kind == .image ? Self.side : 132, height: Self.side)
                .background(SLColor.surface2)
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
                .overlay { state }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(SLColor.textPrimary, SLColor.surface1)
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel(Text(L10n.t("messages.files.remove")))
            .accessibilityIdentifier("chat.files.remove")
        }
        .task(id: file.id) {
            guard file.kind == .image, preview == nil else { return }
            let url = file.fileURL
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                ChatImagePreparer.thumbnail(of: url).map { UIImage(cgImage: $0) }
            }.value
            preview = image
        }
    }

    @ViewBuilder
    private var tile: some View {
        if file.kind == .image {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(SLColor.textMuted)
            }
        } else {
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: ChatDocumentRow.symbol(for: (file.filename as NSString).pathExtension.lowercased()))
                    .font(.system(size: 20))
                    .foregroundStyle(SLColor.textSecondary)
                Text(file.filename)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(2)
            }
            .padding(.horizontal, SLSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var state: some View {
        switch file.phase {
        case let .uploading(fraction):
            ZStack {
                Color.black.opacity(0.35)
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 3)
                    .frame(width: 26, height: 26)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 26, height: 26)
            }
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L10n.t("messages.files.uploading")))
            .accessibilityValue(Text(verbatim: "\(SLFormat.number(Int((fraction * 100).rounded())))%"))
        case .ready:
            EmptyView()
        case let .failed(_, retryable):
            Button {
                if retryable { onRetry() }
            } label: {
                ZStack {
                    SLColor.danger.opacity(0.35)
                    Image(systemName: retryable ? "arrow.clockwise.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(retryable ? L10n.t("messages.files.retry") : file.failure?.message ?? ""))
            .accessibilityIdentifier("chat.files.retry")
        }
    }
}

// MARK: - Full screen

/// A message's pictures, one at a time, swiped between.
struct ChatPictureViewer: View {

    let viewing: ChatPictureViewing
    let load: @MainActor (ChatAttachment, Bool) async throws -> Data
    let onClose: () -> Void

    @State private var selection: Int

    init(
        viewing: ChatPictureViewing,
        load: @escaping @MainActor (ChatAttachment, Bool) async throws -> Data,
        onClose: @escaping () -> Void
    ) {
        self.viewing = viewing
        self.load = load
        self.onClose = onClose
        _selection = State(initialValue: viewing.startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(viewing.pictures.enumerated()), id: \.element.id) { index, picture in
                    ChatZoomablePicture(attachment: picture, load: load)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: viewing.pictures.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(SLSpacing.lg)
            .accessibilityLabel(Text(L10n.t("common.done")))
            .accessibilityIdentifier("chat.viewer.close")
        }
        .accessibilityIdentifier("chat.viewer")
    }
}

/// One picture, pinch to zoom, double-tap to zoom back.
private struct ChatZoomablePicture: View {

    let attachment: ChatAttachment
    let load: @MainActor (ChatAttachment, Bool) async throws -> Data

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1

    var body: some View {
        ChatAttachmentImage(attachment: attachment, thumbnail: false, contentMode: .fit, load: load)
            .scaleEffect(scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(4, max(1, settledScale * value.magnification))
                    }
                    .onEnded { _ in
                        settledScale = scale
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scale = scale > 1 ? 1 : 2
                    settledScale = scale
                }
            }
            .accessibilityLabel(Text(ChatFileCopy.label(for: .image)))
            .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Share sheet

/// "Download": the system share sheet, from which a document is saved to
/// Files or sent on.
struct ChatShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
