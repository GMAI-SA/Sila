import SafariServices
import SwiftUI
import UIKit

// MARK: - The account's label

/// "Official news" beside the news account's name (contract v37 §1): a
/// newspaper glyph and the label, never the human verified seal.
public struct NewsAccountLabel: View {

    private let compact: Bool

    /// - Parameter compact: The smaller form, for a post card's header.
    public init(compact: Bool = true) {
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "newspaper.fill")
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(L10n.t("post.news.label"))
                .font(compact ? SLFont.micro : SLFont.caption)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(SLColor.primary)
        .padding(.horizontal, SLSpacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(SLColor.primary.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("post.news.label")))
    }
}

// MARK: - The post body

/// What a news post shows instead of its text (contract v37 §2): the summary
/// in the interface's language, then the other one, then the link card.
@MainActor
public struct NewsPostBody: View {

    private let news: PostNews
    private let isDetail: Bool
    private let onOpenPost: @MainActor () -> Void

    public init(news: PostNews, isDetail: Bool, onOpenPost: @escaping @MainActor () -> Void) {
        self.news = news
        self.isDetail = isDetail
        self.onOpenPost = onOpenPost
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            let summaries = news.summaries(languageCode: L10n.languageCode)
            ForEach(summaries) { summary in
                let isFirst = summary.id == summaries.first?.id
                let direction: TextDirection = summary.language == "ar" ? .rightToLeft : .leftToRight
                Text(summary.text)
                    .font(isFirst ? (isDetail ? SLFont.bodyEmphasis : SLFont.body) : SLFont.caption)
                    .foregroundStyle(isFirst ? SLColor.textPrimary : SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // `.leading` inside the summary's own direction: an
                    // Arabic summary starts at the right in any interface.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .slContentDirection(direction)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenPost() }
            }

            NewsLinkCard(news: news)
        }
    }
}

/// The original article: source, headline, domain and time, on a generated
/// source card (the article's own image only when the server sends one).
/// A tap opens the article in the in-app browser — `http(s)` only.
@MainActor
public struct NewsLinkCard: View {

    private let news: PostNews

    public init(news: PostNews) {
        self.news = news
    }

    private var sourceName: String { news.sourceDisplayName(languageCode: L10n.languageCode) }

    public var body: some View {
        Button {
            if let url = news.url { InAppBrowser.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                sourceTile
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .clipped()

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    if let title = news.title {
                        Text(title)
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .slContentDirection(TextDirection.resolve(languageCode: nil, text: title))
                    }
                    HStack(spacing: SLSpacing.xs) {
                        if let domain = news.displayDomain {
                            Text(domain)
                                .lineLimit(1)
                                .slContentDirection(.leftToRight)
                        }
                        if let date = news.publishedAt {
                            if news.displayDomain != nil { Text("·") }
                            Text(RelativeTime.short(date))
                        }
                        Spacer(minLength: 0)
                        if news.url != nil {
                            Image(systemName: "arrow.up.right.square")
                                .accessibilityHidden(true)
                        }
                    }
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                }
                .padding(SLSpacing.md)
            }
            .background(SLColor.surface1)
            .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous)
                    .strokeBorder(SLColor.textMuted.opacity(0.35), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SLRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(news.url == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("post.news.card.a11yLabel", sourceName, news.title ?? news.displayDomain ?? "")))
        .accessibilityHint(Text(L10n.t("post.news.card.a11yHint")))
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("post.news.card")
    }

    @ViewBuilder
    private var sourceTile: some View {
        if let image = news.imageURL {
            AsyncImage(url: image) { phase in
                switch phase {
                case let .success(loaded):
                    loaded.resizable().scaledToFill()
                default:
                    generatedTile
                }
            }
        } else {
            generatedTile
        }
    }

    /// News glyph + source name on a tinted background.
    private var generatedTile: some View {
        ZStack {
            LinearGradient(
                colors: [SLColor.primary.opacity(0.22), SLColor.secondary.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .accessibilityHidden(true)
                Text(sourceName)
                    .font(SLFont.bodyEmphasis)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(SLColor.primary)
            .padding(.horizontal, SLSpacing.lg)
        }
    }
}

// MARK: - In-app browser

/// Opens a web page in `SFSafariViewController` over whatever is on screen.
///
/// Presented from UIKit rather than through a SwiftUI sheet, so a card in a
/// lazily recycled feed row cannot take its browser down with it.
@MainActor
public enum InAppBrowser {

    /// Opens `url` when it is an absolute `http(s)` address; ignores anything else.
    public static func open(_ url: URL) {
        guard let safe = PostNews.webURL(url.absoluteString) else { return }
        guard let presenter = topViewController() else {
            UIApplication.shared.open(safe)
            return
        }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let browser = SFSafariViewController(url: safe, configuration: configuration)
        browser.preferredControlTintColor = UIColor(SLColor.primary)
        browser.dismissButtonStyle = .close
        presenter.present(browser, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let allWindows: [UIWindow] = scenes.flatMap { $0.windows }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive })
        let activeKey = activeScene?.windows.first(where: { $0.isKeyWindow })
        let window = activeKey ?? allWindows.first(where: { $0.isKeyWindow }) ?? allWindows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
