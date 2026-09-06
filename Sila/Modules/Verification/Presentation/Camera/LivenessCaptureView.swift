import SwiftUI
import UIKit
import Vision

/// The selfie sequence: look straight, turn one way, turn the other.
///
/// Frames from the front camera go through the face detector; a challenge is
/// satisfied when the head has held the asked-for pose for a moment. The
/// straight-on frame becomes the selfie the reviewer compares with the
/// document; the first turned frame travels too, as evidence that a face was
/// moving rather than a photograph being held up.
///
/// This is a deterrent against the lazy attack, not a biometric. The reviewer
/// is the check; this makes sure they have something real to check.
@MainActor
struct LivenessCaptureView: View {

    let onCompleted: (_ selfie: Data, _ turn: Data?, _ challenges: [LivenessChallenge]) -> Void

    @State private var session = CameraSession(position: .front, frameInterval: 0.12)
    @State private var availability: CameraSession.Availability?
    @State private var engine = LivenessEngine()
    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: SLSpacing.lg) {
            VStack(spacing: SLSpacing.xs) {
                Text(L10n.t("document.liveness.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.liveness.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SLSpacing.lg)

            viewport
                .frame(width: 260, height: 260)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(
                        engine.faceVisible ? SLColor.secondary : SLColor.primary.opacity(0.5),
                        lineWidth: 3
                    )
                )
                .accessibilityLabel(Text(L10n.t("document.liveness.viewport.a11y")))

            VStack(spacing: SLSpacing.sm) {
                Text(prompt)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .animation(.default, value: prompt)

                HStack(spacing: SLSpacing.sm) {
                    ForEach(LivenessChallenge.allCases, id: \.rawValue) { challenge in
                        Circle()
                            .fill(engine.completed.contains(challenge) ? SLColor.secondary : SLColor.stroke)
                            .frame(width: 10, height: 10)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, SLSpacing.lg)

            controls
                .padding(.horizontal, SLSpacing.lg)
        }
        .task {
            availability = await CameraSession.requestAccess()
            if availability == .available { session.start() }
        }
        .onDisappear {
            session.stopFrames()
            session.stop()
        }
        .onChange(of: engine.isFinished) { _, finished in
            guard finished, let selfie = engine.selfie else { return }
            session.stopFrames()
            onCompleted(selfie, engine.turnFrame, engine.completed)
        }
    }

    private var prompt: String {
        guard hasStarted else { return L10n.t("document.liveness.start.prompt") }
        guard engine.faceVisible else { return L10n.t("document.liveness.noFace") }
        return engine.current?.instruction ?? L10n.t("document.liveness.done")
    }

    @ViewBuilder
    private var viewport: some View {
        switch availability {
        case .available:
            CameraPreview(session: session)
        case .denied:
            placeholder(L10n.t("document.capture.permissionDenied"))
        case .unavailable:
            placeholder(L10n.t("document.capture.noCamera"))
        case nil:
            ZStack {
                SLColor.surface2
                ProgressView().tint(SLColor.primary)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        ZStack {
            SLColor.surface2
            Text(text)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(SLSpacing.lg)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch availability {
        case .available where !hasStarted:
            SLButton(
                L10n.t("document.liveness.start"),
                variant: .primary,
                accessibilityHint: L10n.t("document.liveness.start.hint")
            ) {
                start()
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
                let selfie = SampleCapture.jpeg(label: "SELFIE", tint: UIColor(red: 0.55, green: 0.35, blue: 0.25, alpha: 1))
                let turn = SampleCapture.jpeg(label: "TURN", tint: UIColor(red: 0.5, green: 0.32, blue: 0.22, alpha: 1))
                onCompleted(selfie, turn, LivenessChallenge.allCases)
            }
        default:
            EmptyView()
        }
    }

    private func start() {
        hasStarted = true
        engine.reset()
        let engine = self.engine
        session.startFrames { buffer in
            let observation = LivenessEngine.detectFace(in: buffer)
            let frame = observation == nil ? nil : ImageEncoding.jpeg(buffer, maxEdge: 1024)
            Task { @MainActor in
                engine.observe(yaw: observation?.yaw?.doubleValue, faceVisible: observation != nil, frame: frame)
            }
        }
    }
}

/// The challenge state machine, separated from the view so it is testable
/// without a camera: feed it yaw readings and it tells you which prompts
/// have been satisfied and which frames to keep.
@MainActor
@Observable
final class LivenessEngine {

    /// Radians. Vision reports yaw in roughly ±π/2; a comfortable turn is
    /// well past this, a straight look well under.
    static let turnThreshold = 0.30
    static let straightThreshold = 0.12
    /// Consecutive frames the pose must hold. At ~8 fps this is about half a
    /// second — long enough to be deliberate, short enough not to be a chore.
    static let holdFrames = 4

    private(set) var completed: [LivenessChallenge] = []
    private(set) var faceVisible = false
    private(set) var selfie: Data?
    private(set) var turnFrame: Data?
    private var holdCount = 0
    private var firstTurnSign: Double?

    var current: LivenessChallenge? {
        LivenessChallenge.allCases.first { !completed.contains($0) }
    }

    var isFinished: Bool { current == nil }

    func reset() {
        completed = []
        faceVisible = false
        selfie = nil
        turnFrame = nil
        holdCount = 0
        firstTurnSign = nil
    }

    /// One reading from the detector.
    ///
    /// The two turns are "one way" and "the other way" rather than a literal
    /// left and right: the front camera's mirroring makes the sign of yaw a
    /// matter of configuration, and a person told to turn left who is being
    /// registered as turning right would never finish. What the sequence
    /// proves is a head that moved both ways, and that is what is checked.
    func observe(yaw: Double?, faceVisible visible: Bool, frame: Data?) {
        faceVisible = visible
        guard let current, visible, let yaw else {
            holdCount = 0
            return
        }

        let satisfied: Bool
        switch current {
        case .lookStraight:
            satisfied = abs(yaw) < Self.straightThreshold
        case .turnLeft:
            satisfied = abs(yaw) > Self.turnThreshold
        case .turnRight:
            let turned = abs(yaw) > Self.turnThreshold
            let thisSign: Double = yaw < 0 ? -1 : 1
            satisfied = turned && firstTurnSign != nil && thisSign != firstTurnSign
        }

        guard satisfied else {
            holdCount = 0
            return
        }
        holdCount += 1
        guard holdCount >= Self.holdFrames else { return }
        holdCount = 0

        switch current {
        case .lookStraight:
            selfie = frame
        case .turnLeft:
            firstTurnSign = yaw < 0 ? -1 : 1
            turnFrame = frame
        case .turnRight:
            break
        }
        completed.append(current)
    }

    /// The most prominent face in a frame, with its yaw.
    nonisolated static func detectFace(in buffer: CVPixelBuffer) -> VNFaceObservation? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([request])
        return (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
    }
}
