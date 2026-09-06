import SwiftUI
import UIKit

/// Photographs one side of a document and, for the front, reads the text on
/// it so the zone can be parsed.
///
/// The flow is capture → look at the still → keep or retake. The person sees
/// what was captured before anything is read from it, because the failure
/// mode of a document photo is "blurry" and the person is the best judge of
/// that.
@MainActor
struct DocumentCaptureView: View {

    enum Side {
        case front, back
    }

    let side: Side
    let documentType: DocumentType
    /// Called with the JPEG and, for the front, the recognised text.
    let onCaptured: (Data, String?) -> Void

    @State private var session = CameraSession(position: .back)
    @State private var availability: CameraSession.Availability?
    @State private var still: Data?
    @State private var isCapturing = false
    @State private var isReading = false

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
                        .strokeBorder(SLColor.primary.opacity(0.6), lineWidth: 2)
                )
                .padding(.horizontal, SLSpacing.lg)
                .accessibilityLabel(Text(L10n.t("document.capture.viewport.a11y")))

            controls
                .padding(.horizontal, SLSpacing.lg)
        }
        .task {
            availability = await CameraSession.requestAccess()
            if availability == .available { session.start() }
        }
        .onDisappear { session.stop() }
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
                    Task { await capture() }
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
                // The simulator has no camera. A sample keeps the rest of the
                // flow walkable there; on a device this button does not exist.
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

    private func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        if let data = try? await session.capturePhoto() {
            still = data
        }
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
