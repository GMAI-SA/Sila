import AVFoundation
import CoreImage
import Foundation
import UIKit
import Vision

/// The camera, wrapped so a SwiftUI view can ask for a still or a stream of
/// frames without owning `AVCaptureSession` state.
///
/// One session per capture screen. Configuration runs on a private queue —
/// AVFoundation blocks while it starts — and results come back on the main
/// actor. Nothing captured here is written to disk: stills are returned as
/// JPEG bytes and frames as pixel buffers, and both are the caller's to drop.
public final class CameraSession: NSObject, @unchecked Sendable {

    public enum Position: Sendable {
        case back, front
    }

    public enum Availability: Equatable, Sendable {
        /// Ready, or will be once `start()` runs.
        case available
        /// The person said no. Only Settings can change that.
        case denied
        /// No camera on this device (the simulator, say).
        case unavailable
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.socialsa.sila.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let frameOutput = AVCaptureVideoDataOutput()
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var frameHandler: (@Sendable (CVPixelBuffer) -> Void)?
    private var lastFrameAt = Date.distantPast
    private let frameInterval: TimeInterval

    public let position: Position

    /// The layer a preview view installs.
    public let previewLayer: AVCaptureVideoPreviewLayer

    /// - Parameters:
    ///   - position: Which camera.
    ///   - frameInterval: Minimum seconds between frames delivered to
    ///     ``startFrames(_:)``. Vision does not need 60 of them a second.
    public init(position: Position, frameInterval: TimeInterval = 0.1) {
        self.position = position
        self.frameInterval = frameInterval
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    // MARK: - Availability

    /// Whether a camera can be used, asking for permission if it has never
    /// been asked.
    public static func requestAccess() async -> Availability {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .available
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .available : .denied
        default:
            return .denied
        }
    }

    // MARK: - Lifecycle

    /// Configures and starts the session. Safe to call more than once.
    public func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            if session.inputs.isEmpty {
                configure()
            }
            session.startRunning()
        }
    }

    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frameOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(frameOutput) {
            session.addOutput(frameOutput)
        }
        if let connection = frameOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            if position == .front, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        if let connection = photoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }
        session.commitConfiguration()
    }

    // MARK: - Stills

    /// Takes one photo and returns it as JPEG bytes, downscaled to `maxEdge`.
    public func capturePhoto(maxEdge: CGFloat = 1600) async throws -> Data {
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning, photoOutput.connection(with: .video) != nil else {
                    continuation.resume(throwing: CameraError.notRunning)
                    return
                }
                photoContinuation = continuation
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
        guard let image = UIImage(data: raw), let jpeg = ImageEncoding.jpeg(image, maxEdge: maxEdge) else {
            throw CameraError.encodingFailed
        }
        return jpeg
    }

    // MARK: - Frames

    /// Delivers pixel buffers, throttled to ``frameInterval``, until
    /// ``stopFrames()``. The handler runs on the camera queue.
    public func startFrames(_ handler: @escaping @Sendable (CVPixelBuffer) -> Void) {
        queue.async { [self] in frameHandler = handler }
    }

    public func stopFrames() {
        queue.async { [self] in frameHandler = nil }
    }

    public enum CameraError: Error {
        case notRunning
        case encodingFailed
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let continuation = photoContinuation
        photoContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: CameraError.encodingFailed)
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frameHandler, Date().timeIntervalSince(lastFrameAt) >= frameInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameAt = Date()
        frameHandler(buffer)
    }
}

// MARK: - Encoding

/// JPEG encoding with the server's limits in mind.
public enum ImageEncoding {

    /// `image` as JPEG, downscaled so its long edge is at most `maxEdge`.
    /// EXIF is not written: a fresh bitmap carries none.
    public static func jpeg(_ image: UIImage, maxEdge: CGFloat, quality: CGFloat = 0.85) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    /// A frame from the camera as JPEG. Used for the selfie frames, which
    /// come off the video stream rather than the photo output so the moment
    /// the challenge was satisfied is the moment kept.
    public static func jpeg(_ buffer: CVPixelBuffer, maxEdge: CGFloat, quality: CGFloat = 0.85) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return jpeg(UIImage(cgImage: cgImage), maxEdge: maxEdge, quality: quality)
    }
}

// MARK: - Text on a document

/// Runs the on-device text recogniser over a still and returns the lines.
public enum DocumentTextReader {

    /// Every recognised line, top to bottom. `usesLanguageCorrection` is off
    /// on purpose: a zone is not language, and "correcting" `K<<` into a word
    /// is exactly the damage to avoid.
    public static func lines(in jpeg: Data) async -> [String] {
        guard let image = UIImage(data: jpeg)?.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let sorted = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                continuation.resume(returning: sorted.compactMap { $0.topCandidates(1).first?.string })
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// The zone, if the recognised lines contain one: the lines that look
    /// like zone lines, joined. Repairs the one substitution the recogniser
    /// makes on every document — `«` for `<` — and nothing else; the parser's
    /// own bounded repair handles digits.
    public static func zone(from lines: [String]) -> String? {
        let candidates = lines
            .map { $0.replacingOccurrences(of: "«", with: "<").replacingOccurrences(of: " ", with: "").uppercased() }
            .filter { line in
                (line.count == 44 || line.count == 36 || line.count == 30)
                    && line.unicodeScalars.allSatisfy { $0 == "<" || ("0"..."9").contains($0) || ("A"..."Z").contains($0) }
                    && line.contains("<")
            }
        guard candidates.count >= 2 else { return nil }
        let length = candidates.last!.count
        let zone = candidates.filter { $0.count == length }.suffix(length == 30 ? 3 : 2)
        return zone.joined(separator: "\n")
    }
}
