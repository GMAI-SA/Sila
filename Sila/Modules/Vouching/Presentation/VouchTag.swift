import SwiftUI

/// What a tap on somebody's tag does, provided once by the shell that owns
/// the sheets (``MainTabView``, ``GuestTabView``) and read by every card,
/// header and row that draws a tag — so no screen has to thread a callback
/// down to a chip.
public struct VouchTagAction {
    public let open: @MainActor (UserSummary) -> Void

    public init(open: @escaping @MainActor (UserSummary) -> Void) {
        self.open = open
    }
}

private struct VouchTagActionKey: EnvironmentKey {
    static let defaultValue: VouchTagAction? = nil
}

extension EnvironmentValues {
    /// `nil` draws tags inert — previews, and surfaces with no shell above.
    public var vouchTagAction: VouchTagAction? {
        get { self[VouchTagActionKey.self] }
        set { self[VouchTagActionKey.self] = newValue }
    }
}

/// The tag for one person, or nothing.
///
/// The rendering rule of contract v24 §3, in one place: `is_verified` → the
/// seal and the flag (drawn by the caller, as before); otherwise a
/// `vouched_by` → this; otherwise nothing. ``UserSummary`` already drops a
/// tag beside a seal, and this checks again rather than trust it.
public struct VouchTag: View {

    private let person: UserSummary
    private let style: SLVouchTag.Style
    @Environment(\.vouchTagAction) private var action

    public init(person: UserSummary, style: SLVouchTag.Style = .full) {
        self.person = person
        self.style = style
    }

    public var body: some View {
        if !person.isVerified, let vouchedBy = person.vouchedBy {
            SLVouchTag(
                text: VouchCopy.tag(vouchedBy),
                accessibilityLabel: VouchCopy.tagAccessibility(vouchedBy),
                style: style,
                action: action.map { action in { action.open(person) } }
            )
        }
    }
}
