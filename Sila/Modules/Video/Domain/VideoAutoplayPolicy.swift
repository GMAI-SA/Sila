import CoreGraphics
import Foundation

/// When a video may start by itself, muted, as it scrolls into view.
///
/// Only on Wi-Fi that is neither expensive nor in Low Data Mode, and only
/// when the person has not turned off "Auto-Play Video Previews" in the
/// system's accessibility settings or switched on Low Power Mode. Anywhere
/// else a video waits for a tap: somebody's data plan is not ours to spend.
public struct VideoAutoplayPolicy: Equatable, Sendable {

    /// The connection, as `NWPath` describes it.
    public struct Connection: Equatable, Sendable {
        public var isSatisfied: Bool
        public var usesWiFi: Bool
        /// Low Data Mode.
        public var isConstrained: Bool
        /// A hotspot, or cellular.
        public var isExpensive: Bool

        public init(isSatisfied: Bool, usesWiFi: Bool, isConstrained: Bool, isExpensive: Bool) {
            self.isSatisfied = isSatisfied
            self.usesWiFi = usesWiFi
            self.isConstrained = isConstrained
            self.isExpensive = isExpensive
        }

        /// Until the monitor has spoken: no autoplay.
        public static let unknown = Connection(isSatisfied: false, usesWiFi: false, isConstrained: true, isExpensive: true)
    }

    public var connection: Connection
    /// `UIAccessibility.isVideoAutoplayEnabled`.
    public var systemAllowsAutoplay: Bool
    /// `ProcessInfo.isLowPowerModeEnabled`.
    public var isLowPowerMode: Bool

    public init(connection: Connection, systemAllowsAutoplay: Bool, isLowPowerMode: Bool) {
        self.connection = connection
        self.systemAllowsAutoplay = systemAllowsAutoplay
        self.isLowPowerMode = isLowPowerMode
    }

    /// Whether a video may start muted without a tap.
    public var allowsAutoplay: Bool {
        connection.isSatisfied
            && connection.usesWiFi
            && !connection.isConstrained
            && !connection.isExpensive
            && systemAllowsAutoplay
            && !isLowPowerMode
    }

    // MARK: - Which card plays

    /// How much of a card must be on screen before it may play by itself.
    public static let visibleThreshold: CGFloat = 0.6

    /// The share of `frame` inside `viewport`, 0…1.
    public static func visibleFraction(of frame: CGRect, in viewport: CGRect) -> CGFloat {
        guard frame.height > 0, frame.width > 0 else { return 0 }
        let overlap = frame.intersection(viewport)
        guard !overlap.isNull else { return 0 }
        return (overlap.height * overlap.width) / (frame.height * frame.width)
    }

    /// The one card that should be playing: the most visible at or above the
    /// threshold, the one nearest the middle of the screen on a tie.
    public static func choose(_ frames: [UUID: CGRect], in viewport: CGRect) -> UUID? {
        let candidates = frames.compactMap { id, frame -> (UUID, CGFloat, CGFloat)? in
            let fraction = visibleFraction(of: frame, in: viewport)
            guard fraction >= visibleThreshold else { return nil }
            return (id, fraction, abs(frame.midY - viewport.midY))
        }
        return candidates.max { lhs, rhs in
            if abs(lhs.1 - rhs.1) > 0.01 { return lhs.1 < rhs.1 }
            return lhs.2 > rhs.2
        }?.0
    }
}
