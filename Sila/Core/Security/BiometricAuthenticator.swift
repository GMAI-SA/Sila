import Foundation
import LocalAuthentication

/// Which biometry the current device offers.
public enum BiometryKind: Equatable, Sendable {
    case none, touchID, faceID, opticID

    /// Human-readable name used in button labels and prompts.
    public var displayName: String {
        switch self {
        case .none: return L10n.t("biometrics.kind.generic")
        case .touchID: return L10n.t("biometrics.kind.touchID")
        case .faceID: return L10n.t("biometrics.kind.faceID")
        case .opticID: return L10n.t("biometrics.kind.opticID")
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
        context.localizedFallbackTitle = L10n.t("biometrics.usePasscode")

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw APIError.biometricFailed(
                policyError?.localizedDescription ?? L10n.t("biometrics.error.unavailable")
            )
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else {
                throw APIError.biometricFailed(L10n.t("biometrics.error.notCompleted"))
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
            return L10n.t("biometrics.error.cancelled")
        case .userFallback:
            return L10n.t("biometrics.error.userFallback")
        case .biometryNotEnrolled:
            return L10n.t("biometrics.error.notEnrolled")
        case .biometryLockout:
            return L10n.t("biometrics.error.lockout")
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
            throw APIError.biometricFailed(L10n.t("biometrics.error.cancelled"))
        }
    }
}
