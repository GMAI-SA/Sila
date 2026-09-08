import SwiftUI
import UIKit
import Vision

/// The live head-turn: look straight, then turn the head slowly all the way
/// round while a ring of eight sectors fills as each direction is covered.
///
/// Frames from the front camera go through the face detector at ~15 fps; the
/// engine reads yaw and pitch, turns them into a direction on the ring, and
/// keeps one frame per sector at the moment the head pointed there. The
/// straight-on frame becomes the selfie the reviewer compares with the
/// document; the eight sector frames travel too, with the angle and time the
/// camera measured for each.
///
/// Two things make this more than three timed prompts. The ring **follows the
/// face** — whichever way the person turns lights the sector they are pointing
/// at, so the sequence works whatever sign convention the camera's mirroring
/// gives yaw. And the face has to stay **continuous**: losing it, or a jump in
/// where it is, restarts the sweep, so the frames are of one head that moved,
/// not of eight photographs held up in turn.
///
/// Still a deterrent against the lazy attack rather than a biometric. The
/// reviewer is the check; this makes sure they have something real to check.
@MainActor
struct SweepCaptureView: View {

    let onCompleted: (LivenessSweep) -> Void

    @State private var session = CameraSession(position: .front, frameInterval: 0.066)
    @State private var availability: CameraSession.Availability?
    @State private var engine = SweepEngine()
    @State private var hasStarted = false
    @State private var haptics = UIImpactFeedbackGenerator(style: .light)

    private let ringSize: CGFloat = 268

    var body: some View {
        VStack(spacing: SLSpacing.lg) {
            VStack(spacing: SLSpacing.xs) {
                Text(L10n.t("document.sweep.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.sweep.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SLSpacing.lg)

            ZStack {
                viewport
                    .frame(width: ringSize - 28, height: ringSize - 28)
                    .clipShape(Circle())
                ring
                    .frame(width: ringSize, height: ringSize)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L10n.t("document.sweep.viewport.a11y")))
            .accessibilityValue(Text(L10n.plural("document.sweep.covered", engine.coveredCount)))

            VStack(spacing: SLSpacing.sm) {
                Text(prompt)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(engine.restarted ? SLColor.warning : SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.default, value: prompt)
                SLProgressBar(
                    value: Double(engine.coveredCount) / Double(SweepEngine.sectors),
                    tint: SLColor.secondary,
                    label: L10n.plural("document.sweep.covered", engine.coveredCount)
                )
                .frame(maxWidth: ringSize)
            }
            .padding(.horizontal, SLSpacing.lg)

            controls
                .padding(.horizontal, SLSpacing.lg)
        }
        .task {
            availability = await CameraSession.requestAccess()
            if availability == .available { session.start() }
            haptics.prepare()
        }
        .onDisappear {
            session.stopFrames()
            session.stop()
        }
        .onChange(of: engine.coveredCount) { before, after in
            if after > before { haptics.impactOccurred() }
        }
        .onChange(of: engine.isFinished) { _, finished in
            guard finished, let sweep = engine.sweep() else { return }
            session.stopFrames()
            haptics.impactOccurred(intensity: 1)
            onCompleted(sweep)
        }
    }

    private var prompt: String {
        guard hasStarted else { return L10n.t("document.sweep.start.prompt") }
        if engine.restarted { return L10n.t("document.sweep.restarted") }
        guard engine.faceVisible else { return L10n.t("document.liveness.noFace") }
        if engine.straightFrame == nil { return L10n.t("document.sweep.lookStraight") }
        if engine.isFinished { return L10n.t("document.liveness.done") }
        return engine.coveredCount == 0
            ? L10n.t("document.sweep.turn")
            : L10n.t("document.sweep.keepGoing")
    }

    /// Eight arcs. Covered ones are solid; the one the nose points at now
    /// glows; the rest wait. Sector 0 sits at the top and they run clockwise.
    private var ring: some View {
        ZStack {
            ForEach(0..<SweepEngine.sectors, id: \.self) { index in
                let slice = 1.0 / Double(SweepEngine.sectors)
                Circle()
                    .trim(from: CGFloat(Double(index) * slice + 0.012), to: CGFloat(Double(index + 1) * slice - 0.012))
                    .stroke(color(for: index), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90 - 360 / Double(SweepEngine.sectors) / 2))
                    .animation(.easeOut(duration: 0.2), value: engine.coveredCount)
            }
        }
    }

    private func color(for sector: Int) -> Color {
        if engine.covered.contains(sector) { return SLColor.secondary }
        if engine.pointingAt == sector { return SLColor.primary }
        return SLColor.stroke
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
                accessibilityHint: L10n.t("document.sweep.start.hint")
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
                onCompleted(SampleCapture.sweep())
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
            let observation = SweepEngine.detectFace(in: buffer)
            let frame = observation == nil ? nil : ImageEncoding.jpeg(buffer, maxEdge: 640)
            let reading = observation.map {
                SweepEngine.Reading(
                    yaw: $0.yaw?.doubleValue ?? 0,
                    pitch: $0.pitch?.doubleValue ?? 0,
                    box: $0.boundingBox
                )
            }
            Task { @MainActor in
                engine.observe(reading, frame: frame)
            }
        }
    }
}

/// The sweep state machine, separated from the view so it is testable without
/// a camera: feed it readings and it tells you which sectors are covered,
/// which frames to keep, and when it is done.
@MainActor
@Observable
final class SweepEngine {

    /// One detector reading.
    struct Reading: Equatable {
        /// Radians, as Vision reports them.
        let yaw: Double
        let pitch: Double
        /// The face's normalised bounding box.
        let box: CGRect
    }

    static let sectors = 8
    /// How far the head has to turn (radians, combined yaw and pitch) before it
    /// counts as pointing at a sector rather than looking roughly straight.
    static let turnThreshold = 0.22
    /// Under this it is a straight look.
    static let straightThreshold = 0.10
    /// Consecutive frames a direction must hold. ~0.2 s at 15 fps: deliberate,
    /// not a chore.
    static let holdFrames = 3
    /// A face whose box jumped further than this fraction of its own width
    /// between readings is not the same face carrying on; the sweep restarts.
    static let maxJump = 0.25
    /// Longest a sweep may take before it restarts.
    static let budget: TimeInterval = 90
    /// After this long, six sectors are enough — some necks do not do eight.
    static let leniencyAfter: TimeInterval = 30
    static let minimumSectors = 6

    private(set) var faceVisible = false
    private(set) var covered: Set<Int> = []
    private(set) var pointingAt: Int?
    private(set) var straightFrame: Data?
    private(set) var isFinished = false
    /// `true` for the frames after a restart, so the prompt can say why.
    private(set) var restarted = false

    private var straightSample: LivenessSample?
    private var frames: [LivenessFrame] = []
    private var holdSector: Int?
    private var holdCount = 0
    private var lastBox: CGRect?
    private var startedAt: Date?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var coveredCount: Int { covered.count }

    func reset() {
        faceVisible = false
        covered = []
        pointingAt = nil
        straightFrame = nil
        straightSample = nil
        frames = []
        holdSector = nil
        holdCount = 0
        lastBox = nil
        startedAt = nil
        isFinished = false
        restarted = false
    }

    /// What was kept, once ``isFinished``.
    func sweep() -> LivenessSweep? {
        guard isFinished, let straightSample, let straightFrame else { return nil }
        let ordered = frames.sorted { $0.sample.t < $1.sample.t }
        return LivenessSweep(
            straight: straightSample,
            straightFrame: straightFrame,
            frames: ordered,
            duration: ordered.last.map { $0.sample.t } ?? 0
        )
    }

    /// One reading from the detector (`nil` when no face was found).
    func observe(_ reading: Reading?, frame: Data?) {
        guard !isFinished else { return }
        let time = now()
        if startedAt == nil { startedAt = time }
        let elapsed = time.timeIntervalSince(startedAt ?? time)

        guard let reading else {
            // Losing the face is a break in continuity, not a pause.
            faceVisible = false
            pointingAt = nil
            if straightFrame != nil { restart() }
            return
        }
        faceVisible = true

        if let previous = lastBox, jumped(from: previous, to: reading.box) {
            restart()
            lastBox = reading.box
            return
        }
        lastBox = reading.box

        if elapsed > Self.budget {
            restart()
            startedAt = time
            return
        }

        let magnitude = (reading.yaw * reading.yaw + reading.pitch * reading.pitch).squareRoot()

        guard straightFrame != nil else {
            // The straight look first: the selfie the reviewer compares.
            pointingAt = nil
            if magnitude < Self.straightThreshold {
                holdCount += 1
                if holdCount >= Self.holdFrames, let frame {
                    straightFrame = frame
                    straightSample = LivenessSample(yaw: reading.yaw, pitch: reading.pitch, t: elapsed)
                    restarted = false
                    holdCount = 0
                }
            } else {
                holdCount = 0
            }
            return
        }

        guard magnitude > Self.turnThreshold else {
            pointingAt = nil
            holdSector = nil
            holdCount = 0
            return
        }

        let sector = Self.sector(yaw: reading.yaw, pitch: reading.pitch)
        pointingAt = sector
        if holdSector == sector {
            holdCount += 1
        } else {
            holdSector = sector
            holdCount = 1
        }
        guard holdCount >= Self.holdFrames, !covered.contains(sector), let frame else { return }
        covered.insert(sector)
        frames.append(
            LivenessFrame(
                sector: sector,
                sample: LivenessSample(yaw: reading.yaw, pitch: reading.pitch, t: elapsed),
                jpeg: frame
            )
        )
        restarted = false
        holdCount = 0

        if covered.count == Self.sectors
            || (covered.count >= Self.minimumSectors && elapsed >= Self.leniencyAfter) {
            isFinished = true
        }
    }

    private func restart() {
        covered = []
        frames = []
        straightFrame = nil
        straightSample = nil
        holdSector = nil
        holdCount = 0
        pointingAt = nil
        restarted = true
    }

    private func jumped(from: CGRect, to: CGRect) -> Bool {
        let dx = abs(from.midX - to.midX)
        let dy = abs(from.midY - to.midY)
        let allowed = max(from.width, 0.05) * Self.maxJump
        return dx > allowed || dy > allowed
    }

    /// The ring sector a head pointing at (`yaw`, `pitch`) is aimed at: 0 at
    /// the top, clockwise. Whatever the camera's sign convention, turning all
    /// the way round covers every sector.
    static func sector(yaw: Double, pitch: Double) -> Int {
        // atan2 gives the angle from the +x axis counter-clockwise; rotate so
        // "up" is 0 and clockwise increases.
        var angle = atan2(yaw, pitch)
        if angle < 0 { angle += 2 * .pi }
        let slice = 2 * Double.pi / Double(sectors)
        return Int(((angle + slice / 2) / slice).rounded(.down)) % sectors
    }

    /// The most prominent face in a frame, with its yaw and pitch.
    nonisolated static func detectFace(in buffer: CVPixelBuffer) -> VNFaceObservation? {
        let request = VNDetectFaceRectanglesRequest()
        // Revision 3 is the one that reports pitch as well as yaw.
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([request])
        return (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
    }
}

extension SampleCapture {

    /// A whole sweep, for environments without a camera: eight tinted frames
    /// and a plausible trace, so the rest of the flow stays walkable.
    static func sweep() -> LivenessSweep {
        let straight = jpeg(label: "SELFIE", tint: UIColor(red: 0.55, green: 0.35, blue: 0.25, alpha: 1))
        let frames = (0..<SweepEngine.sectors).map { index -> LivenessFrame in
            let angle = Double(index) * 2 * .pi / Double(SweepEngine.sectors)
            return LivenessFrame(
                sector: index,
                sample: LivenessSample(yaw: 0.35 * sin(angle), pitch: 0.35 * cos(angle), t: 1.0 + Double(index) * 0.9),
                jpeg: jpeg(label: "TURN \(index)", tint: UIColor(red: 0.5, green: 0.32 + CGFloat(index) * 0.02, blue: 0.22, alpha: 1))
            )
        }
        return LivenessSweep(
            straight: LivenessSample(yaw: 0.01, pitch: 0.0, t: 0.0),
            straightFrame: straight,
            frames: frames,
            duration: 8.5
        )
    }
}
