import Foundation
import os

/// The mockable seam for product analytics.
///
/// Phase 1 ships the no-op / logging implementation only; a real provider can
/// be dropped in later without touching a single call site.
public protocol AnalyticsClient: Sendable {
    /// Records a named event with optional string properties.
    func track(_ event: AnalyticsEvent, properties: [String: String])
}

extension AnalyticsClient {
    /// Records an event with no properties.
    public func track(_ event: AnalyticsEvent) {
        track(event, properties: [:])
    }
}

/// Events emitted by Phase 1.
public enum AnalyticsEvent: String, Sendable {
    case appLaunched = "app_launched"
    case registerSubmitted = "register_submitted"
    case otpRequested = "otp_requested"
    case otpVerified = "otp_verified"
    case signInSucceeded = "sign_in_succeeded"
    case signInFailed = "sign_in_failed"
    case biometricSignIn = "biometric_sign_in"
    case signedOut = "signed_out"
    case verificationWallShown = "verification_wall_shown"
    case verificationStarted = "verification_started"
    case appealOpened = "appeal_opened"
}

/// Default ``AnalyticsClient``: writes to the unified log in debug and does
/// nothing in release. No network, no third party.
public struct ConsoleAnalyticsClient: AnalyticsClient {

    public init() {}

    public func track(_ event: AnalyticsEvent, properties: [String: String]) {
        #if DEBUG
        let logger = Logger(subsystem: "com.socialsa.trustnet", category: "analytics")
        if properties.isEmpty {
            logger.debug("event=\(event.rawValue, privacy: .public)")
        } else {
            let rendered = properties
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            logger.debug("event=\(event.rawValue, privacy: .public) \(rendered, privacy: .public)")
        }
        #endif
    }
}

/// ``AnalyticsClient`` that records events in memory so tests can assert on them.
public final class RecordingAnalyticsClient: AnalyticsClient, @unchecked Sendable {

    private var storage: [(event: AnalyticsEvent, properties: [String: String])] = []
    private let lock = NSLock()

    public init() {}

    /// Every event tracked so far, in order.
    public var events: [AnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage.map(\.event)
    }

    public func track(_ event: AnalyticsEvent, properties: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append((event, properties))
    }
}
