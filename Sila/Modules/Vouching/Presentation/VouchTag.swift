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

/// "What this vouch means", as a VoiceOver action, on a row or card that
/// reads as one element with the tag inside it — the search row, the quote
/// card — so the explainer is reachable there too.
struct VouchTagAccessibilityAction: ViewModifier {
    let person: UserSummary
    let action: VouchTagAction?

    func body(content: Content) -> some View {
        if let action, !person.isVerified, person.vouchedBy != nil {
            content.accessibilityAction(named: Text(L10n.t("vouch.tag.a11yAction"))) { action.open(person) }
        } else {
            content
        }
    }
}

/// Where a tag sits inside something that is itself a button, so the tag
/// can be drawn over it instead — a button inside another button's label
/// never gets its own tap.
struct VouchTagAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
