import CoreImage
import SwiftUI
import UIKit
import Vision

/// Photographs one side of a document — and finds the document for the person.
///
/// The camera looks for a card-shaped rectangle in every frame. The guide
/// turns green when it has one that fills the frame and holds still, says
/// what to fix when it does not (closer, steadier), and takes the photo
/// itself once the card has held for a moment. The shutter stays for anyone
/// who would rather press it. What is kept is the card, cropped and squared
/// from the rectangle's corners, so a reviewer gets a document rather than a
/// tabletop with a document somewhere on it.
///
/// The flow is still capture → look at the still → keep or retake: the person
/// sees what was captured before anything is read from it, because the
/// failure mode of a document photo is "blurry" and they are the best judge.
@MainActor
struct DocumentCaptureView: View {

    enum Side {
        case front, back
    }

    let side: Side
    let documentType: DocumentType
    /// Called with the JPEG and, for the front, the recognised text.
    let onCaptured: (Data, String?) -> Void

    @State private var session = CameraSession(position: .back, frameInterval: 0.1)
    @State private var availability: CameraSession.Availability?
    @State private var guide = CaptureGuide()
    @State private var still: Data?
    @State private var isCapturing = false
    @State private var isReading = false
    @State private var autoCaptureFired = false

    var body: some View {
        VStack(spacing: SLSpacing.lg) {
            VStack(spacing: SLSpacing.xs) {
                Text(side == .front ? L10n.t("document.capture.front.title") : L10n.t("document.capture.back.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(side == .front ? L10n.t("document.capture.front.instruction") : L10n.t("document.capture.back.instruction"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SLSpacing.lg)

            viewport
                .frame(maxWidth: .infinity)
                .aspectRatio(documentType == .passport ? 125.0 / 88.0 : 85.6 / 54.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: SLRadius.lg)
                        .strokeBorder(guideColor, lineWidth: still == nil && guide.state.isSteady ? 4 : 2)
                        .animation(.easeOut(duration: 0.2), value: guide.state)
                )
                .padding(.horizontal, SLSpacing.lg)
                .accessibilityLabel(Text(L10n.t("document.capture.viewport.a11y")))
                .accessibilityValue(Text(hint))

            if still == nil, availability == .available {
                Text(hint)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(guide.state.isSteady ? SLColor.secondary : SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .animation(.default, value: hint)
                    .padding(.horizontal, SLSpacing.lg)
            }

            controls
                .padding(.horizontal, SLSpacing.lg)
        }
        .task {
            availability = await CameraSession.requestAccess()
            if availability == .available {
                session.start()
                watch()
            }
        }
        .onDisappear {
            session.stopFrames()
            session.stop()
        }
        .onChange(of: guide.state) { _, state in
            // The camera found the card and it held still: take the photo
            // for them. Once — a retake is theirs to start.
            if case .ready = state, still == nil, !isCapturing, !autoCaptureFired {
                autoCaptureFired = true
                Task { await capture(automatic: true) }
            }
        }
    }

    private var guideColor: Color {
        guard still == nil else { return SLColor.primary.opacity(0.6) }
        switch guide.state {
        case .ready, .steady: return SLColor.secondary
        case .searching: return SLColor.primary.opacity(0.6)
        case .adjust: return SLColor.warning
        }
    }

    private var hint: String {
        switch guide.state {
        case .searching: return L10n.t("document.capture.hint.lineUp")
        case let .adjust(reason):
            switch reason {
            case .closer: return L10n.t("document.capture.hint.closer")
            case .steady: return L10n.t("document.capture.hint.holdStill")
            }
        case .steady: return guide.zoneSeen ? L10n.t("document.capture.hint.zoneFound") : L10n.t("document.capture.hint.holdStill")
        case .ready: return L10n.t("document.capture.hint.captured")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var viewport: some View {
        if let still, let image = UIImage(data: still) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            switch availability {
            case .available:
                CameraPreview(session: session)
            case .denied:
                notice(icon: "camera.fill", text: L10n.t("document.capture.permissionDenied"))
            case .unavailable:
                notice(icon: "camera.fill", text: L10n.t("document.capture.noCamera"))
            case nil:
                ZStack {
                    SLColor.surface2
                    ProgressView().tint(SLColor.primary)
                }
            }
        }
    }

    private func notice(icon: String, text: String) -> some View {
        ZStack {
            SLColor.surface2
            VStack(spacing: SLSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(SLColor.textMuted)
                Text(text)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SLSpacing.lg)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if still != nil {
            VStack(spacing: SLSpacing.md) {
                SLButton(
                    L10n.t("document.capture.usePhoto"),
                    variant: .primary,
                    isLoading: isReading,
                    accessibilityHint: L10n.t("document.capture.usePhoto.hint")
                ) {
                    Task { await accept() }
                }
                SLButton(
                    L10n.t("document.capture.retake"),
                    variant: .secondary,
                    isEnabled: !isReading,
                    accessibilityHint: L10n.t("document.retake.hint")
                ) {
                    still = nil
                    autoCaptureFired = false
                    guide.reset()
                    watch()
                }
                if isReading {
                    Text(L10n.t("document.capture.reading"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
        } else {
            switch availability {
            case .available:
                SLButton(
                    L10n.t("document.capture.shutter"),
                    variant: .primary,
                    icon: "camera.fill",
                    isLoading: isCapturing,
                    accessibilityHint: L10n.t("document.capture.shutter.hint")
                ) {
                    Task { await capture(automatic: false) }
                }
            case .denied:
                SLButton(
                    L10n.t("document.capture.openSettings"),
                    variant: .secondary,
                    accessibilityHint: L10n.t("document.capture.openSettings.hint")
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .unavailable where CameraEnvironment.isSimulated:
                SLButton(
                    L10n.t("document.mock.useSample"),
                    variant: .secondary,
                    accessibilityHint: L10n.t("document.mock.useSample.hint")
                ) {
                    still = SampleCapture.jpeg(
                        label: side == .front ? "FRONT" : "BACK",
                        tint: side == .front ? UIColor(red: 0.12, green: 0.24, blue: 0.47, alpha: 1)
                                             : UIColor(red: 0.16, green: 0.31, blue: 0.55, alpha: 1)
                    )
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Actions

    /// Watches the live frames for the card.
    private func watch() {
        let guide = self.guide
        let wantsZone = side == .front
        session.startFrames { buffer in
            let card = CardDetector.detect(in: buffer)
            let zone = wantsZone && card != nil && guide.wantsZoneCheck()
                ? CardDetector.looksLikeZone(in: buffer)
                : false
            Task { @MainActor in
                guide.observe(card: card, zoneSeen: zone)
            }
        }
    }

    private func capture(automatic: Bool) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        session.stopFrames()
        guard let data = try? await session.capturePhoto() else {
            watch()
            return
        }
        // The card, not the tabletop: squared from the rectangle's corners
        // when the still shows one, the whole still otherwise.
        still = CardDetector.cropToCard(data) ?? data
    }

    private func accept() async {
        guard let still, !isReading else { return }
        isReading = true
        defer { isReading = false }
        guard side == .front else {
            onCaptured(still, nil)
            return
        }
        var text: String?
        if CameraEnvironment.isSimulated, availability == .unavailable {
            text = SampleCapture.passportZone()
        } else {
            text = DocumentTextReader.zone(from: await DocumentTextReader.lines(in: still))
        }
        onCaptured(still, text)
    }
}

/// The guidance state machine, separated from the view so it is testable
/// without a camera: feed it what the rectangle detector saw and it says
/// what the person should do, and when the photo should take itself.
@MainActor
@Observable
final class CaptureGuide {

    enum Adjustment: Equatable {
        case closer
        case steady
    }

    enum State: Equatable {
        /// No card-shaped rectangle in the frame.
        case searching
        /// A card, but not yet usable: too small, or moving.
        case adjust(Adjustment)
        /// A card that fills the frame and has held for `progress` frames.
        case steady(Int)
        /// Held long enough: the photo takes itself.
        case ready

        var isSteady: Bool {
            switch self {
            case .steady, .ready: return true
            case .searching, .adjust: return false
            }
        }
    }

    /// The card must cover this much of the frame's width.
    static let minimumWidth = 0.55
    /// Consecutive still frames before the shutter fires itself. ~0.6 s.
    static let holdFrames = 6
    /// A centre that moved further than this fraction of the frame is not
    /// holding still.
    static let maxDrift = 0.03

    private(set) var state: State = .searching
    /// Whether a zone-shaped line of text was seen while steady.
    private(set) var zoneSeen = false

    private var lastBox: CGRect?
    private var holdCount = 0
    private var lastZoneCheck = Date.distantPast

    func reset() {
        state = .searching
        zoneSeen = false
        lastBox = nil
        holdCount = 0
    }

    /// Whether it is worth running the (slow) text pass on this frame.
    nonisolated func wantsZoneCheck() -> Bool {
        // Read off the main actor's state deliberately loosely: a stale
        // answer costs one extra text pass, never a wrong capture.
        true
    }

    /// One detector result.
    func observe(card: CGRect?, zoneSeen: Bool) {
        guard case .ready = state else {
            guard let card else {
                state = .searching
                holdCount = 0
                lastBox = nil
                return
            }
            if zoneSeen { self.zoneSeen = true }
            if card.width < Self.minimumWidth {
                state = .adjust(.closer)
                holdCount = 0
                lastBox = card
                return
            }
            if let lastBox, abs(lastBox.midX - card.midX) > Self.maxDrift || abs(lastBox.midY - card.midY) > Self.maxDrift {
                state = .adjust(.steady)
                holdCount = 0
                self.lastBox = card
                return
            }
            lastBox = card
            holdCount += 1
            state = holdCount >= Self.holdFrames ? .ready : .steady(holdCount)
            return
        }
    }
}

/// Finds a card-shaped rectangle, and squares a still to it.
enum CardDetector {

    /// The largest card-shaped rectangle in a frame, as a normalised box.
    nonisolated static func detect(in buffer: CVPixelBuffer) -> CGRect? {
        let request = rectangleRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([request])
        return largest(request.results)?.boundingBox
    }

    /// Whether a line shaped like a machine-readable zone is visible: a fast
    /// text pass, used only for the "zone found" reassurance.
    nonisolated static func looksLikeZone(in buffer: CVPixelBuffer) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.contains { line in
            let cleaned = line.replacingOccurrences(of: " ", with: "")
            return cleaned.count >= 28 && cleaned.filter { $0 == "<" }.count >= 3
        }
    }

    /// The still, cropped and perspective-corrected to the card it shows, or
    /// `nil` when no card-shaped rectangle is found in it.
    nonisolated static func cropToCard(_ jpeg: Data) -> Data? {
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        let request = rectangleRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([request])
        guard let card = largest(request.results) else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        func point(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * width, y: p.y * height)
        }
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(point(card.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(card.topRight), forKey: "inputTopRight")
        filter.setValue(point(card.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(card.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let corrected = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return ImageEncoding.jpeg(UIImage(cgImage: corrected), maxEdge: 1600)
    }

    private nonisolated static func rectangleRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        // Cards are 1.59:1 and a passport page 1.42:1; expressed as height
        // over width, both sit between these.
        request.minimumAspectRatio = 0.55
        request.maximumAspectRatio = 0.78
        request.minimumSize = 0.3
        request.quadratureTolerance = 20
        request.minimumConfidence = 0.6
        request.maximumObservations = 3
        return request
    }

    private nonisolated static func largest(_ results: [VNRectangleObservation]?) -> VNRectangleObservation? {
        (results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }
}
