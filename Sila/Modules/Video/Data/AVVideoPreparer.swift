import AVFoundation
import Foundation
import UIKit

/// The production ``VideoPreparing``: AVFoundation on the phone.
///
/// The server makes its own 720p and 480p from whatever arrives, so anything
/// much above 720p is upload time wasted (contract v28 §12). A picked video
/// is exported as H.264 at 1280×720 or below — a portrait video as 720×1280 —
/// which also maps an iPhone's HDR to ordinary colour. A small H.264 file is
/// sent as it is: re-encoding it would only cost time and quality.
public final class AVVideoPreparer: VideoPreparing {

    /// Sizes to try, largest first. A smaller one is used only when a larger
    /// one comes out over the server's limit, which three minutes of 720p
    /// never should.
    static let presets = [
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPreset640x480,
    ]

    /// A file at most this wide and dense goes up untouched.
    static let passthroughLongSide = 1280
    static let passthroughBitRate: Double = 4_500_000

    private let maximumBytes: Int

    public init(maximumBytes: Int = VideoLimits.maximumUploadBytes) {
        self.maximumBytes = maximumBytes
    }

    public func inspect(_ source: URL) async throws -> VideoSourceInfo {
        let asset = AVURLAsset(url: source)
        do {
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoPreparationError.unreadable
            }
            let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .estimatedDataRate)
            let shown = natural.applying(transform)
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { throw VideoPreparationError.unreadable }
            let bytes = Self.fileSize(source)
            let bitRate = bytes > 0 ? Double(bytes) * 8 / seconds : Double(rate)
            return VideoSourceInfo(
                durationSeconds: seconds,
                sizeBytes: bytes,
                width: Int(abs(shown.width).rounded()),
                height: Int(abs(shown.height).rounded()),
                estimatedBitRate: bitRate
            )
        } catch let error as VideoPreparationError {
            throw error
        } catch {
            throw VideoPreparationError.unreadable
        }
    }

    public func prepare(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedVideo {
        let info = try await inspect(source)
        try? FileManager.default.removeItem(at: destination)

        if await Self.canSendAsIs(source, info: info, maximumBytes: maximumBytes) {
            try FileManager.default.copyItem(at: source, to: destination)
            progress(1)
            return PreparedVideo(file: destination, sizeBytes: Self.fileSize(destination),
                                 durationSeconds: info.durationSeconds, width: info.width, height: info.height)
        }

        let asset = AVURLAsset(url: source)
        let compatible = await Self.compatiblePresets(for: asset)
        for preset in Self.presets where compatible.contains(preset) {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destination)
            try await Self.export(asset, preset: preset, to: destination, progress: progress)
            let bytes = Self.fileSize(destination)
            if bytes > 0, bytes <= maximumBytes {
                let made = (try? await inspect(destination)) ?? info
                progress(1)
                return PreparedVideo(file: destination, sizeBytes: bytes, durationSeconds: made.durationSeconds,
                                     width: made.width, height: made.height)
            }
        }
        try? FileManager.default.removeItem(at: destination)
        throw compatible.isEmpty ? VideoPreparationError.unreadable : VideoPreparationError.tooLarge
    }

    public func trim(_ source: URL, to destination: URL, seconds: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: source)
        try? FileManager.default.removeItem(at: destination)
        // Passthrough: the frames are kept as they are and compressed once,
        // afterwards, like any other video.
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try await Self.export(asset, preset: AVAssetExportPresetPassthrough, to: destination, timeRange: range, progress: { _ in })
        return destination
    }

    public func thumbnail(_ source: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }

    // MARK: - Helpers

    /// An H.264 file no bigger or denser than what the export would make.
    private static func canSendAsIs(_ source: URL, info: VideoSourceInfo, maximumBytes: Int) async -> Bool {
        guard max(info.width, info.height) <= passthroughLongSide,
              info.estimatedBitRate <= passthroughBitRate,
              info.sizeBytes > 0, info.sizeBytes <= maximumBytes else { return false }
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions) else { return false }
        return formats.allSatisfy { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
    }

    private static func compatiblePresets(for asset: AVAsset) async -> Set<String> {
        var compatible: Set<String> = []
        for preset in presets
        where await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4) {
            compatible.insert(preset)
        }
        return compatible
    }

    private static func export(
        _ asset: AVAsset,
        preset: String,
        to destination: URL,
        timeRange: CMTimeRange? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoPreparationError.unreadable
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        // Where and on what it was filmed stays on the phone; the server
        // strips it again anyway.
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        if let timeRange { session.timeRange = timeRange }

        let watcher = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { watcher.cancel() }

        // Three minutes of 4K take a while to compress, and people switch
        // apps while they wait. The time iOS lends an app that asks for it
        // lets the export carry on in the background; if that runs out, the
        // export is stopped here, cleanly, and the upload centre runs it
        // again when the app is back.
        let time = await VideoBackgroundTime.begin("Preparing a video") { session.cancelExport() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }

        let wentAway = await time.finish()
        if let failure = Self.failure(
            status: session.status,
            error: session.error,
            cancelledByCaller: Task.isCancelled,
            wentToBackground: wentAway
        ) {
            throw failure
        }
    }

    /// What an export that did not complete means.
    ///
    /// Stopped because the person gave up on the video (the task was
    /// cancelled): a cancellation. Stopped by anything else — iOS taking its
    /// time back, the app going to the background while the encoder was
    /// busy, the media services restarting — is an interruption, and is
    /// compressed again. Only a failure on screen, with no sign of an
    /// interruption, says the file itself could not be read: `inspect`
    /// read it a moment before, so anything else would refuse a video
    /// that is fine.
    /// - Returns: `nil` when the export completed.
    static func failure(
        status: AVAssetExportSession.Status,
        error: Error?,
        cancelledByCaller: Bool,
        wentToBackground: Bool
    ) -> Error? {
        switch status {
        case .completed:
            return nil
        case .cancelled:
            return cancelledByCaller ? CancellationError() : VideoPreparationError.interrupted
        default:
            if cancelledByCaller { return CancellationError() }
            if wentToBackground || isInterruption(error) { return VideoPreparationError.interrupted }
            return VideoPreparationError.unreadable
        }
    }

    /// The errors AVFoundation gives an export it had to stop, rather than
    /// one it could not do. The encoder's own "session no longer valid"
    /// (kVTInvalidSessionErr) is what the hardware encoder says when iOS
    /// takes it away from an app in the background.
    static func isInterruption(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == AVFoundationErrorDomain,
           [AVError.Code.operationInterrupted, .mediaServicesWereReset].map(\.rawValue).contains(error.code) {
            return true
        }
        if error.domain == NSOSStatusErrorDomain, error.code == Self.encoderSessionInvalid {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isInterruption(underlying)
        }
        return false
    }

    /// `kVTInvalidSessionErr`.
    static let encoderSessionInvalid = -12903

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
