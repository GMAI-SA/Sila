import SwiftUI

/// Pick a GIF for a post.
///
/// A search field, what people from the viewer's country share on Sila, and
/// the provider's trending list for that country. The provider is credited
/// when it answered, and only then.
@MainActor
public struct GifPickerSheet: View {

    @State private var viewModel: GifPickerViewModel
    private let onPick: @MainActor (Gif) -> Void
    private let onClose: @MainActor () -> Void
    @FocusState private var isFieldFocused: Bool

    public init(viewModel: GifPickerViewModel, onPick: @escaping @MainActor (Gif) -> Void, onClose: @escaping @MainActor () -> Void) {
        self._viewModel = State(initialValue: viewModel)
        self.onPick = onPick
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("composer.gif.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.cancel"), action: onClose)
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityIdentifier("composer.gif.cancel")
                }
            }
            .task { await viewModel.load() }
        }
        .tint(SLColor.primary)
    }

    private var searchField: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SLColor.textMuted)
                .accessibilityHidden(true)
            TextField(
                L10n.t("composer.gif.search.placeholder"),
                text: Binding(get: { viewModel.query }, set: { viewModel.updateQuery($0) })
            )
            .font(SLFont.body)
            .foregroundStyle(SLColor.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isFieldFocused)
            .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.query))
            .onSubmit { viewModel.updateQuery(viewModel.query, immediately: true) }
            .accessibilityIdentifier("composer.gif.search")

            if !viewModel.query.isEmpty {
                Button { viewModel.clear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("search.field.clear.a11yLabel")))
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: SLRadius.lg)
                .fill(SLColor.surface1)
                .overlay(RoundedRectangle(cornerRadius: SLRadius.lg).strokeBorder(isFieldFocused ? SLColor.primary : SLColor.stroke, lineWidth: 1))
        )
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView()
                .tint(SLColor.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            SLEmptyState(
                icon: "exclamationmark.triangle",
                title: message,
                tint: SLColor.textSecondary,
                actionTitle: L10n.t("feed.error.retry"),
                action: { Task { await viewModel.reload() } }
            )
            .padding(SLSpacing.lg)

        case .loaded:
            if viewModel.isLibraryEmpty {
                SLEmptyState(
                    icon: "photo.on.rectangle.angled",
                    title: L10n.t("composer.gif.empty.title"),
                    subtitle: L10n.t("composer.gif.empty.subtitle"),
                    tint: SLColor.textSecondary
                )
                .padding(SLSpacing.lg)
            } else if viewModel.isSearching && viewModel.gifs.isEmpty {
                SLEmptyState(
                    icon: "magnifyingglass",
                    title: L10n.t("composer.gif.noResults.title", viewModel.query),
                    tint: SLColor.textSecondary
                )
                .padding(SLSpacing.lg)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SLSpacing.md) {
                if !viewModel.sharedHere.isEmpty {
                    sectionTitle(
                        viewModel.countryName.map { L10n.t("composer.gif.sharedHere.title", $0) }
                            ?? L10n.t("composer.gif.sharedHere.titleNoCountry")
                    )
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SLSpacing.sm) {
                            ForEach(viewModel.sharedHere, id: \.listKey) { gif in
                                tile(gif, height: 96)
                                    .frame(width: 96 * max(0.7, min(gif.aspectRatio, 1.8)), height: 96)
                            }
                        }
                        .padding(.horizontal, SLSpacing.lg)
                    }
                    sectionTitle(L10n.t("composer.gif.trending.title"))
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: SLSpacing.xs), GridItem(.flexible(), spacing: SLSpacing.xs)], spacing: SLSpacing.xs) {
                    ForEach(viewModel.gifs, id: \.listKey) { gif in
                        tile(gif, height: 150)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .task { await viewModel.loadMoreIfNeeded(current: gif) }
                    }
                }
                .padding(.horizontal, SLSpacing.lg)

                if viewModel.isLoadingMore {
                    ProgressView().tint(SLColor.primary).frame(maxWidth: .infinity).padding(SLSpacing.md)
                }

                if viewModel.isFromProvider {
                    // The provider's terms ask for this, and it is true.
                    Text(L10n.t("composer.gif.attribution"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SLSpacing.md)
                }
            }
            .padding(.bottom, SLSpacing.xxl)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SLFont.caption)
            .foregroundStyle(SLColor.textSecondary)
            .padding(.horizontal, SLSpacing.lg)
    }

    private func tile(_ gif: Gif, height: CGFloat) -> some View {
        Button {
            onPick(gif)
        } label: {
            ZStack {
                SLColor.surface2
                AnimatedGifView(url: gif.thumbnailURL, stillURL: gif.stillURL)
            }
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(gif.title ?? L10n.t("post.gif.a11yLabel")))
        .accessibilityHint(Text(L10n.t("composer.gif.tile.a11yHint")))
    }
}
