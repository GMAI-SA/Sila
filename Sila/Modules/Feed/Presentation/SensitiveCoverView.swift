import SwiftUI

/// The author's warning, and the reader's choice.
///
/// Says *what kind* of thing is covered — "Spoiler alert" and "Violent content"
/// are different promises — plus the author's own note. Nothing about the post
/// is shown until the reader opens it, and it closes again on request: a
/// spoiler you have read is still a spoiler for whoever is looking over your
/// shoulder.
///
/// Tinted by kind. A spoiler is a courtesy and takes the brand colour; violence
/// is a caution and takes the danger colour — so the colour says as much as the
/// word does before the reader has read it.
public struct SensitiveCoverView: View {

    private let kind: SensitiveKind
    private let note: String?
    @Binding private var isRevealed: Bool

    public init(kind: SensitiveKind, note: String?, isRevealed: Binding<Bool>) {
        self.kind = kind
        self.note = note
        self._isRevealed = isRevealed
    }

    public var body: some View {
        if isRevealed {
            openedLabel
        } else {
            cover
        }
    }

    /// Once open: one line naming the warning, and the way to close it again.
    private var openedLabel: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .semibold))
            Text(SensitiveCopy.title(kind))
                .font(SLFont.micro)
            Spacer(minLength: 0)
            Button(SensitiveCopy.hide) { withAnimation(.easeInOut(duration: 0.15)) { isRevealed = false } }
                .font(SLFont.micro)
                .foregroundStyle(SLColor.primary)
                .accessibilityIdentifier("post.sensitive.hide")
        }
        .foregroundStyle(SLColor.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("post.sensitive.open")
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(SensitiveCopy.title(kind))
                    .font(SLFont.bodyEmphasis)
            }
            .foregroundStyle(tint)

            if let note {
                // The author's words, in their direction.
                Text(note)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: note))
            }

            Text(SensitiveCopy.covered)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)

            SLButton(
                SensitiveCopy.show,
                variant: .secondary,
                size: .compact,
                icon: "eye",
                accessibilityHint: SensitiveCopy.showHint(kind),
                action: { withAnimation(.easeInOut(duration: 0.15)) { isRevealed = true } }
            )
            .frame(width: 120)
            .padding(.top, SLSpacing.xs)
            .accessibilityIdentifier("post.sensitive.show")
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1)
        )
        // One element: the kind, the note and the button, read together.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(SensitiveCopy.accessibilityLabel(kind, note: note)))
        .accessibilityIdentifier("post.sensitive.cover")
        // The card underneath opens the post on tap; the cover must not.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var tint: Color {
        switch kind {
        case .spoiler: return SLColor.primary
        case .violence: return SLColor.danger
        case .other: return SLColor.warning
        }
    }

    private var background: Color {
        kind == .violence ? SLColor.danger.opacity(0.08) : SLColor.surface1
    }
}

/// Every sentence the cover says, in one place so it can be asserted.
public enum SensitiveCopy {

    /// "Spoiler alert", "Violent content", "Sensitive content".
    ///
    /// A switch rather than an interpolated key: the catalogue guard reads
    /// keys out of the source, and a key it cannot see is a key it cannot
    /// prove exists in both languages.
    public static func title(_ kind: SensitiveKind) -> String {
        switch kind {
        case .spoiler: return L10n.t("post.sensitive.spoiler.title")
        case .violence: return L10n.t("post.sensitive.violence.title")
        case .other: return L10n.t("post.sensitive.other.title")
        }
    }

    public static var show: String { L10n.t("post.sensitive.show") }
    public static var hide: String { L10n.t("post.sensitive.hide") }
    /// Under the title: who covered it and what opening does.
    public static var covered: String { L10n.t("post.sensitive.covered") }

    public static func showHint(_ kind: SensitiveKind) -> String {
        L10n.t("post.sensitive.show.hint", title(kind))
    }

    /// The whole cover as one spoken line: the kind, then the note.
    public static func accessibilityLabel(_ kind: SensitiveKind, note: String?) -> String {
        guard let note, !note.isEmpty else { return title(kind) }
        return "\(title(kind)). \(note)"
    }

    /// Inside a quote: the kind, the note, and that the text is on its own page.
    public static func quotedLabel(_ kind: SensitiveKind, note: String?) -> String {
        let lead = (note?.isEmpty == false) ? "\(title(kind)) — \(note!)" : title(kind)
        return "\(lead). \(L10n.t("post.sensitive.quoted"))"
    }
}
