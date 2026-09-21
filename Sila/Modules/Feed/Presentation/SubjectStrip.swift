import SwiftUI

/// The subjects, in the timeline, one tap away.
///
/// Choosing what you see used to mean opening a settings screen and picking
/// tiles inside it — two taps and a context switch away from the thing you
/// were reading. This is the same choice where it belongs: a row above the
/// posts, always there, scrolling sideways. Tap a subject and the timeline
/// narrows to it; tap it again and everything comes back. The choice follows
/// you across all four tabs, because it is about what you want to read, not
/// about which tab you happen to be on. Several can be on at once, and they
/// mean *any* of them — two taps are two conversations, not the intersection
/// of both.
///
/// Subjects somebody has hidden are absent: the strip is for choosing what
/// to see, and offering a subject they already said "never" to would be
/// offering to undo that decision by accident.
@MainActor
struct SubjectStrip: View {

    /// The taxonomy, already ordered: chosen interests first.
    let subjects: [TopicOption]
    /// The subjects pinned right now. Several are allowed.
    let pinned: [String]
    /// Opens the full preferences screen. `nil` hides the affordance.
    let onOpenPreferences: (@MainActor () -> Void)?
    let onSelect: @MainActor (String?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Pinned at the leading edge rather than trailing the row: with
            // twenty-odd subjects, anything at the far end of a horizontal
            // scroll view is a control most people never find.
            if let onOpenPreferences {
                Button(action: onOpenPreferences) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SLColor.textSecondary)
                        .padding(.horizontal, SLSpacing.md)
                        .padding(.vertical, SLSpacing.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, SLSpacing.sm)
                .accessibilityLabel(Text(L10n.t("feed.preferencesBar.a11yLabel")))
                .accessibilityHint(Text(L10n.t("feed.preferencesBar.hint")))
                .accessibilityIdentifier("feed.subject.preferences")
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SLSpacing.sm) {
                        ForEach(subjects) { subject in
                            chip(subject)
                                .id(subject.id)
                        }
                    }
                    .padding(.horizontal, SLSpacing.md)
                    .padding(.vertical, SLSpacing.sm)
                }
                .onAppear {
                    // A pinned subject can be anywhere in the row; show one.
                    if let first = pinned.first { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
        .overlay(alignment: .bottom) { SLDivider() }
        .accessibilityIdentifier("feed.subjectStrip")
    }

    private func chip(_ subject: TopicOption) -> some View {
        let isPinned = pinned.contains(subject.id)
        return Button {
            // Tapping a pinned chip takes it out; tapping another adds it.
            onSelect(subject.id)
        } label: {
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: TopicIcon.symbol(for: subject.id))
                    .font(.system(size: 12, weight: .semibold))
                Text(subject.label)
                    .font(SLFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isPinned ? SLColor.background : SLColor.textPrimary)
            .padding(.horizontal, SLSpacing.md)
            .padding(.vertical, SLSpacing.sm)
            .background(Capsule().fill(isPinned ? SLColor.primary : SLColor.surface2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(subject.label))
        .accessibilityValue(Text(isPinned ? L10n.t("feed.subject.pinned") : ""))
        .accessibilityHint(Text(isPinned ? L10n.t("feed.subject.clear.hint") : L10n.t("feed.subject.pin.hint")))
        .accessibilityAddTraits(isPinned ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("feed.subject.\(subject.id)")
    }
}
