import Foundation
import LocalAuthentication

/// Which biometry the current device offers.
public enum BiometryKind: Equatable, Sendable {
    case none, touchID, faceID, opticID

    /// Human-readable name used in button labels and prompts.
    public var displayName: String {
        switch self {
        case .none: return "Biometrics"
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        }
    }

    /// SF Symbol representing the biometry.
    public var symbolName: String {
        switch self {
        case .none: return "lock"
        case .touchID: return "touchid"
        case .faceID: return "faceid"
        case .opticID: return "opticid"
        }
    }
}

/// The mockable seam for `LocalAuthentication`.
public protocol BiometricAuthenticating: Sendable {
    /// The biometry available right now, or ``BiometryKind/none``.
    var availableBiometry: BiometryKind { get }
    /// Presents the biometric prompt.
    /// - Parameter reason: Shown by the system in the prompt.
    /// - Throws: ``APIError/biometricFailed(_:)`` on cancel or failure.
    func authenticate(reason: String) async throws
}

/// Production ``BiometricAuthenticating`` built on `LAContext`.
///
/// Uses the `.deviceOwnerAuthentication` policy so a user who cannot present a
/// face or finger can still fall back to the device passcode.
public struct LocalAuthenticationBiometricAuthenticator: BiometricAuthenticating {

    public init() {}

    public var availableBiometry: BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw APIError.biometricFailed(
                policyError?.localizedDescription ?? "Biometric sign-in isn't available on this device."
            )
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else {
                throw APIError.biometricFailed("Biometric sign-in was not completed.")
            }
        } catch let error as LAError {
            throw APIError.biometricFailed(Self.message(for: error))
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.biometricFailed(error.localizedDescription)
        }
    }

    private static func message(for error: LAError) -> String {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return "Biometric sign-in was cancelled."
        case .userFallback:
            return "Enter your password to continue."
        case .biometryNotEnrolled:
            return "No biometrics are enrolled on this device."
        case .biometryLockout:
            return "Biometrics are locked. Unlock your device with its passcode first."
        default:
            return error.localizedDescription
        }
    }
}

/// Scriptable ``BiometricAuthenticating`` for tests and previews.
public struct StubBiometricAuthenticator: BiometricAuthenticating {

    public let availableBiometry: BiometryKind
    private let shouldSucceed: Bool

    /// - Parameters:
    ///   - availableBiometry: What ``availableBiometry`` reports.
    ///   - shouldSucceed: Whether ``authenticate(reason:)`` resolves or throws.
    public init(availableBiometry: BiometryKind = .faceID, shouldSucceed: Bool = true) {
        self.availableBiometry = availableBiometry
        self.shouldSucceed = shouldSucceed
    }

    public func authenticate(reason: String) async throws {
        guard shouldSucceed else {
            throw APIError.biometricFailed("Biometric sign-in was cancelled.")
        }
    }
}
