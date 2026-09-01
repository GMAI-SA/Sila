import SwiftUI

/// An underline-style segmented control. **Design-system component.**
///
/// `Picker(.segmented)` cannot carry the brand's underline indicator and starts
/// truncating at four options, which is exactly the count the feed needs
/// (For You · Following · My Country · International). This scrolls
/// horizontally instead of truncating, and keeps the selected segment visible.
///
/// ```swift
/// SLSegmentedControl(items: FeedTab.allCases, selection: $tab) { $0.title }
/// ```
public struct SLSegmentedControl<Item: Hashable & Identifiable>: View {

    private let items: [Item]
    @Binding private var selection: Item
    private let title: (Item) -> String
    private let accessibilityHint: (Item) -> String?

    @Namespace private var indicator

    /// Creates a segmented control.
    /// - Parameters:
    ///   - items: Segments, left to right.
    ///   - selection: The bound current segment.
    ///   - accessibilityHint: What selecting a segment does. Optional per item.
    ///   - title: Visible label for a segment.
    public init(
        items: [Item],
        selection: Binding<Item>,
        accessibilityHint: @escaping (Item) -> String? = { _ in nil },
        title: @escaping (Item) -> String
    ) {
        self.items = items
        self._selection = selection
        self.accessibilityHint = accessibilityHint
        self.title = title
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        segment(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, SLSpacing.sm)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selection) { _, new in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(new.id, anchor: .center)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SLColor.stroke)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                selection = item
            }
        } label: {
            VStack(spacing: SLSpacing.sm) {
                Text(title(item))
                    .font(isSelected ? SLFont.bodyEmphasis : SLFont.body)
                    .foregroundStyle(isSelected ? SLColor.textPrimary : SLColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                ZStack {
                    Capsule().fill(Color.clear).frame(height: 3)
                    if isSelected {
                        Capsule()
                            .fill(SLColor.brandGradient)
                            .frame(height: 3)
                            .matchedGeometryEffect(id: "tn.segment.indicator", in: indicator)
                    }
                }
            }
            .padding(.horizontal, SLSpacing.md)
            .padding(.top, SLSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The item's own id, not its title. A UI test that located a segment by
        // its label would be testing English and would fail the moment the app
        // ran in Arabic — which is the one run where the layout most needs
        // checking.
        .accessibilityIdentifier("segment.\(item.id)")
        .accessibilityLabel(Text(title(item)))
        .accessibilityHint(Text(accessibilityHint(item) ?? L10n.t("ds.segmentedControl.defaultHint", title(item))))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("SLSegmentedControl") {
    struct Demo: View {
        struct Tab: Hashable, Identifiable { let id: String }
        @State private var selection = Tab(id: "For You")
        var body: some View {
            SLSegmentedControl(
                items: ["For You", "Following", "My Country", "International"].map(Tab.init),
                selection: $selection
            ) { $0.id }
        }
    }
    return Demo()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SLColor.background)
        .preferredColorScheme(.dark)
}
