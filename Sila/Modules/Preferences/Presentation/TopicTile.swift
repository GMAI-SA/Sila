import SwiftUI

/// The symbol each topic wears.
///
/// A picker of twenty-one identical rows is a list nobody finishes reading.
/// With a face on each one it is a thing you scan, which is the difference
/// between choosing your feed and giving up on it.
enum TopicIcon {

    private static let symbols: [String: String] = [
        "technology": "cpu",
        "business": "briefcase",
        "finance": "chart.line.uptrend.xyaxis",
        "politics": "building.columns",
        "news": "newspaper",
        "sports": "figure.run",
        "health": "heart.text.square",
        "science": "atom",
        "education": "graduationcap",
        "religion": "moon.stars",
        "culture": "theatermasks",
        "entertainment": "music.mic",
        "movies_tv": "film",
        "gaming": "gamecontroller",
        "art": "paintpalette",
        "food": "fork.knife",
        "travel": "airplane",
        "environment": "leaf",
        "motoring": "car",
        "real_estate": "house",
        "jobs": "person.text.rectangle",
    ]

    /// A topic added on the server before this app knew about it still gets a
    /// tile — an honest generic one rather than a blank square.
    static func symbol(for topicId: String) -> String {
        symbols[topicId] ?? "number"
    }
}

/// One topic, as a tile.
///
/// Three states, and each says what it means without a legend: **off** is
/// plain, **following** is tinted and ticked, and **hidden** is greyed with
/// its name struck through. Tapping the tile follows or unfollows; the small
/// button in the corner is the one that takes a subject off the timeline
/// entirely, which is a different decision and deserves its own control.
@MainActor
struct TopicTile: View {

    let topic: TopicOption
    let stance: TopicStance
    let onSelect: @MainActor (TopicStance) -> Void

    private var isInterested: Bool { stance == .interested }
    private var isMuted: Bool { stance == .muted }

    var body: some View {
        VStack(spacing: SLSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous)
                            .strokeBorder(border, lineWidth: isInterested ? 2 : 1)
                    )
                    .frame(height: 84)
                    .overlay {
                        Image(systemName: TopicIcon.symbol(for: topic.id))
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(tint)
                            .symbolRenderingMode(.hierarchical)
                    }

                Button {
                    onSelect(isMuted ? .none : .muted)
                } label: {
                    Image(systemName: isMuted ? "eye.slash.fill" : "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isMuted ? SLColor.danger : SLColor.textMuted)
                        .padding(6)
                        .background(Circle().fill(SLColor.surface1))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(Text(isMuted
                    ? L10n.t("preferences.topics.unhide.a11yLabel", topic.label)
                    : L10n.t("preferences.topics.hide.a11yLabel", topic.label)))
                .accessibilityHint(Text(L10n.t("preferences.topics.hide.a11yHint")))
                .accessibilityIdentifier("preferences.topic.hide.\(topic.id)")
            }

            Text(topic.label)
                .font(SLFont.caption)
                .foregroundStyle(isMuted ? SLColor.textMuted : SLColor.textPrimary)
                .strikethrough(isMuted, color: SLColor.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // The corner button owns hiding; the tile itself only ever means
            // "more of this" or "no opinion".
            onSelect(isInterested ? .none : .interested)
        }
        .opacity(isMuted ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(topic.label). \(stance.title)"))
        .accessibilityValue(Text(topic.detail))
        .accessibilityIdentifier("preferences.topic.\(topic.id)")
    }

    private var background: Color {
        if isMuted { return SLColor.surface2 }
        return isInterested ? SLColor.primary.opacity(0.16) : SLColor.surface2
    }

    private var border: Color {
        isInterested ? SLColor.primary : SLColor.stroke
    }

    private var tint: Color {
        if isMuted { return SLColor.textMuted }
        return isInterested ? SLColor.primary : SLColor.textSecondary
    }
}
