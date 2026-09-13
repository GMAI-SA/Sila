import SwiftUI
import UIKit

/// A post's words, with `@mentions` and `#hashtags` that answer a tap on
/// *themselves* and nowhere else.
///
/// SwiftUI's `Text` can only make a run tappable by giving it a `.link`
/// attribute, and the hit area that comes with that is the system's, not
/// ours: a tap in the blank space after a mention — or a few points past its
/// last glyph, or on the line below it — opened that person's profile instead
/// of the post. On a card whose whole job is "tap to open the post", that is
/// the difference between reading and being thrown somewhere.
///
/// So the text is laid out by TextKit and the hit test is ours: the glyph
/// under the finger decides. A tap on an entity opens the entity; a tap on
/// any other character — or on the empty end of a line — opens the post.
struct PostBodyText: UIViewRepresentable {

    /// The post's raw body.
    let text: String
    /// Point size and weight, already chosen by the card's style.
    let fontSize: CGFloat
    let weight: UIFont.Weight
    /// Resolved for the current colour scheme by the caller.
    let textColor: UIColor
    let entityColor: UIColor
    /// The direction the *content* reads in, which is the post's own and not
    /// the interface's — an Arabic post on an English phone still starts at
    /// the right margin.
    let direction: TextDirection
    /// A `#hashtag` or `@mention` was tapped.
    let onEntity: @MainActor (PostEntityLink) -> Void
    /// Anything else in the text was tapped: the card's own action.
    let onBody: @MainActor () -> Void

    func makeUIView(context: Context) -> BodyTextView {
        let view = BodyTextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        // Not selectable, deliberately: selection puts a magnifier and a menu
        // in front of somebody who was trying to open a post, and it is UIKit's
        // selection machinery that owns the link hit areas this exists to
        // replace.
        view.isSelectable = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.onTap = { [weak view] point in
            guard let view else { return }
            if let entity = view.entity(at: point) {
                context.coordinator.onEntity(entity)
            } else {
                context.coordinator.onBody()
            }
        }
        return view
    }

    func updateUIView(_ view: BodyTextView, context: Context) {
        context.coordinator.onEntity = onEntity
        context.coordinator.onBody = onBody
        view.attributedText = Self.attributed(
            text: text,
            fontSize: fontSize,
            weight: weight,
            textColor: textColor,
            entityColor: entityColor,
            direction: direction
        )
        view.accessibilityLabel = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BodyTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        guard width > 0, width < .infinity else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEntity: onEntity, onBody: onBody)
    }

    @MainActor
    final class Coordinator {
        var onEntity: @MainActor (PostEntityLink) -> Void
        var onBody: @MainActor () -> Void

        init(onEntity: @escaping @MainActor (PostEntityLink) -> Void, onBody: @escaping @MainActor () -> Void) {
            self.onEntity = onEntity
            self.onBody = onBody
        }
    }

    /// The body as an attributed string: entities tinted and carrying the URL
    /// the hit test reads back.
    static func attributed(
        text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        textColor: UIColor,
        entityColor: UIColor,
        direction: TextDirection
    ) -> NSAttributedString {
        let font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: fontSize, weight: weight))
        let paragraph = NSMutableParagraphStyle()
        // `.natural` inside an explicit writing direction puts the first line
        // against the edge the language starts from, and keeps punctuation at
        // the correct end — the whole reason a post carries its own direction.
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        paragraph.lineHeightMultiple = 1.08

        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        for token in PostTextParser.tokenize(text) {
            switch token {
            case let .plain(value):
                result.append(NSAttributedString(string: value, attributes: base))
            case let .mention(handle):
                result.append(entityRun("@\(handle)", link: .mention(handle), base: base, color: entityColor))
            case let .hashtag(tag):
                result.append(entityRun("#\(tag)", link: .hashtag(tag), base: base, color: entityColor))
            }
        }
        return result
    }

    private static func entityRun(
        _ string: String,
        link: PostEntityLink,
        base: [NSAttributedString.Key: Any],
        color: UIColor
    ) -> NSAttributedString {
        var attributes = base
        attributes[.foregroundColor] = color
        // An entity whose payload cannot be encoded still renders; it is
        // simply not tappable, which beats dropping the characters.
        if let url = link.url { attributes[.link] = url }
        return NSAttributedString(string: string, attributes: attributes)
    }
}

/// The text view behind ``PostBodyText``, built on TextKit 1 so the character
/// under a point is answerable.
final class BodyTextView: UITextView {

    /// Called with a point in this view's coordinates.
    var onTap: ((CGPoint) -> Void)?

    init() {
        // Constructed by hand rather than with `UITextView()`: on iOS 16 and
        // later a plain text view is TextKit 2, where `layoutManager` is a
        // compatibility shim that silently disables the new engine. Asking for
        // TextKit 1 outright is the honest version of the same thing.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: .zero, textContainer: container)
        let recogniser = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        recogniser.cancelsTouchesInView = false
        addGestureRecognizer(recogniser)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
        onTap?(recogniser.location(in: self))
    }

    /// The entity under `point`, or `nil` — including for a tap past the end
    /// of a line, which is the case that used to open somebody's profile.
    func entity(at point: CGPoint) -> PostEntityLink? {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return nil }
        var location = point
        location.x -= textContainerInset.left
        location.y -= textContainerInset.top

        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: location,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < storage.length else { return nil }

        // `characterIndex(for:)` answers with the *nearest* character however
        // far away the point is, so the glyph's own rectangle is what decides.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard box.contains(location) else { return nil }

        guard let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL else { return nil }
        return PostEntityLink.parse(url)
    }
}
