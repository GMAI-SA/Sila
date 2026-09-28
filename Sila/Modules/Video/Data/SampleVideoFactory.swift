#if DEBUG
import AVFoundation
import CoreVideo
import Foundation

/// Makes small test videos on the phone: moving colour, and a tone — nothing
/// of a person, ever.
///
/// Debug builds only. The UI journeys pick one of these instead of going
/// through the system's photo picker (`-mockVideoPick short|long`), and the
/// unit and live tests upload them.
public enum SampleVideoFactory {

    public enum Kind: String, Sendable {
        /// Three seconds, 320×240, with sound.
        case short
        /// Three minutes and ten seconds of a tiny picture, silent: over the
        /// limit, for the refusal and the trim.
        case long
        /// Five seconds of 1280×720 noise at a high bit rate, about 12 MB —
        /// three chunks, for resuming half way.
        case big
    }

    /// Writes a sample to `directory` and returns its file.
    public static func make(_ kind: Kind, in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("sample-\(kind.rawValue)-\(UUID().uuidString.prefix(8)).mp4")
        switch kind {
        case .short:
            try await write(to: url, seconds: 3, fps: 30, width: 320, height: 240, audio: true, noisy: false, bitRate: nil)
        case .long:
            try await write(to: url, seconds: 190, fps: 1, width: 64, height: 64, audio: false, noisy: false, bitRate: nil)
        case .big:
            try await write(to: url, seconds: 5, fps: 8, width: 1280, height: 720, audio: true, noisy: true, bitRate: 20_000_000)
        }
        return url
    }

    /// Writes an H.264 `.mp4` with an AAC tone.
    ///
    /// Each track is fed when the writer asks for it, on a queue of its own.
    /// Feeding them in turn from one loop deadlocks as soon as the writer
    /// wants more of the sound than the loop has given it before the next
    /// frame — the sound encoder holds some back — which is exactly what it
    /// did on the simulator.
    public static func write(
        to url: URL,
        seconds: Int,
        fps: Int32,
        width: Int,
        height: Int,
        audio withAudio: Bool,
        noisy: Bool,
        bitRate: Int?
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if let bitRate {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitRate]
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        sound.expectsMediaDataInRealTime = false
        if withAudio { writer.add(sound) }
        guard writer.startWriting() else { throw writer.error ?? VideoPreparationError.unreadable }
        writer.startSession(atSourceTime: .zero)

        let frames = FrameSource(frames: seconds * Int(fps), fps: fps, width: width, height: height, noisy: noisy)
        let tone = ToneSource(seconds: seconds)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await feed(video, on: "sila.sample.video") { frames.appendNext(to: adaptor) }
            }
            if withAudio {
                group.addTask {
                    await feed(sound, on: "sila.sample.audio") { tone.appendNext(to: sound) }
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoPreparationError.unreadable }
    }

    /// Feeds `input` whenever it is ready, until `next` says there is no
    /// more, then marks it finished.
    private static func feed(_ input: AVAssetWriterInput, on label: String, next: @escaping () -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = Once()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while input.isReadyForMoreMediaData {
                    guard next() else {
                        if done.claim() {
                            input.markAsFinished()
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }
    }
}

/// Resumes a continuation once, however often the writer calls back.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Moving colour, or noise, one frame at a time.
private final class FrameSource: @unchecked Sendable {
    private let frames: Int
    private let fps: Int32
    private let width: Int
    private let height: Int
    private let noisy: Bool
    private var frame = 0
    /// Noise made once and copied from a different place each frame: fast
    /// even in a debug build, and nothing an encoder can predict.
    private lazy var noise: [UInt8] = {
        var state: UInt32 = 0x2545F491
        return (0..<(width * height * 4 + 65_536)).map { _ in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        }
    }()

    init(frames: Int, fps: Int32, width: Int, height: Int, noisy: Bool) {
        self.frames = frames
        self.fps = fps
        self.width = width
        self.height = height
        self.noisy = noisy
    }

    /// Appends the next frame; `false` when there are none left.
    func appendNext(to adaptor: AVAssetWriterInputPixelBufferAdaptor) -> Bool {
        guard frame < frames, let pool = adaptor.pixelBufferPool else { return false }
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
        guard let pixels else { return false }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) {
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let hue = UInt8((frame * 255) / max(frames, 1))
            if noisy {
                let start = (frame * 4_099) % 65_536
                noise.withUnsafeBufferPointer { source in
                    for y in 0..<height {
                        memcpy(base + y * row, source.baseAddress! + start + y * width * 4, width * 4)
                    }
                }
            } else {
                for y in 0..<height {
                    for x in 0..<width {
                        let pixel = base + y * row + x * 4
                        pixel[0] = UInt8((x + frame * 4) & 0xFF)
                        pixel[1] = UInt8((y + frame * 2) & 0xFF)
                        pixel[2] = hue
                        pixel[3] = 255
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            return false
        }
        frame += 1
        return true
    }
}

/// A 440 Hz tone, 1024 samples at a time.
private final class ToneSource: @unchecked Sendable {
    private static let sampleRate = 44_100.0
    private let total: Int
    private var written = 0
    private var format: CMAudioFormatDescription?

    init(seconds: Int) {
        total = Int(Self.sampleRate) * seconds
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
    }

    /// Appends the next stretch of sound; `false` when it is all there.
    func appendNext(to input: AVAssetWriterInput) -> Bool {
        guard written < total, let format else { return false }
        let count = min(1024, total - written)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = Int16(sin(2 * .pi * 440 * Double(written + index) / Self.sampleRate) * 6000)
        }
        let bytes = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        )
        guard let block else { return false }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: bytes)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard let buffer, input.append(buffer) else { return false }
        written += count
        return true
    }
}
#endif
