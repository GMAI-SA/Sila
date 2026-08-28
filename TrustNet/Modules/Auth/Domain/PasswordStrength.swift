import SwiftUI

/// Scores a password on five independent signals and maps the total to a
/// four-step ladder used by the registration meter.
///
/// This is deliberately a pure value type with no dependencies, so the strength
/// rules are unit-testable without touching a view.
public enum PasswordStrength: Int, Comparable, CaseIterable, Sendable {
    /// Fewer than 2 of 5 signals — reject.
    case weak = 0
    /// 2 of 5 — reject.
    case fair = 1
    /// 3–4 of 5 — accept.
    case good = 2
    /// All 5 — accept.
    case strong = 3

    /// The minimum length TrustNet accepts.
    public static let minimumLength = 8

    /// Evaluates a password.
    ///
    /// Length is a gate, not a signal: anything shorter than
    /// ``minimumLength`` is ``weak`` and no amount of variety rescues it. Once
    /// the gate is cleared, four independent signals grade the rest —
    /// length ≥ 12, mixed case, a digit, and a symbol.
    ///
    /// | Signals cleared | Result |
    /// |---|---|
    /// | 0–1 | ``fair`` |
    /// | 2 | ``good`` |
    /// | 3–4 | ``strong`` |
    ///
    /// Keeping length out of the grade is what lets ``advice`` stay truthful:
    /// "use at least 8 characters" is only ever shown to someone who has not.
    public static func evaluate(_ password: String) -> PasswordStrength {
        guard password.count >= minimumLength else { return .weak }

        var signals = 0
        if password.count >= 12 { signals += 1 }

        let hasLower = password.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasUpper = password.rangeOfCharacter(from: .uppercaseLetters) != nil
        if hasLower && hasUpper { signals += 1 }

        if password.rangeOfCharacter(from: .decimalDigits) != nil { signals += 1 }

        let symbols = CharacterSet.alphanumerics.inverted
        if password.rangeOfCharacter(from: symbols) != nil { signals += 1 }

        switch signals {
        case 0, 1: return .fair
        case 2: return .good
        default: return .strong
        }
    }

    /// Fill fraction for ``TNProgressBar``.
    public var fraction: Double {
        switch self {
        case .weak: return 0.25
        case .fair: return 0.5
        case .good: return 0.75
        case .strong: return 1.0
        }
    }

    /// Short label shown next to the meter.
    public var title: String {
        switch self {
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .good: return "Good"
        case .strong: return "Strong"
        }
    }

    /// Meter colour.
    public var color: Color {
        switch self {
        case .weak: return TNColor.danger
        case .fair: return TNColor.warning
        case .good: return TNColor.primary
        case .strong: return TNColor.secondary
        }
    }

    /// Whether a password at this strength may be submitted.
    public var isAcceptable: Bool { self >= .good }

    /// Guidance shown when the password is not yet acceptable.
    public var advice: String {
        switch self {
        case .weak:
            return "Use at least \(Self.minimumLength) characters."
        case .fair:
            return "Add a capital letter, a number or a symbol."
        case .good, .strong:
            return ""
        }
    }

    public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Email syntax checking shared by registration, sign-in and password reset.
public enum EmailValidator {

    /// A pragmatic RFC-5322 subset: one `@`, a dot-separated domain, no spaces.
    private static let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#

    /// `true` when `email` is plausibly deliverable.
    public static func isValid(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 254 else { return false }
        return trimmed.range(of: pattern, options: [.regularExpression]) != nil
    }

    /// Lower-cased, whitespace-stripped form sent to the API.
    public static func normalise(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
