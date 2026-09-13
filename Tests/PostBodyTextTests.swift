import UIKit
import XCTest
@testable import Sila

/// Tapping a post's text.
///
/// A tap used to belong to whichever `.link` run the system decided was
/// nearest, so the blank end of a line that happened to contain a mention
/// opened that person's profile instead of the post. The character under the
/// finger decides now, and these are the cases that went wrong.
@MainActor
final class PostBodyTextTests: XCTestCase {

    private func view(_ text: String, width: CGFloat = 280) -> BodyTextView {
        let view = BodyTextView()
        view.isSelectable = false
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = PostBodyText.attributed(
            text: text,
            fontSize: 17,
            weight: .regular,
            textColor: .label,
            entityColor: .systemBlue,
            direction: .leftToRight
        )
        view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        view.layoutIfNeeded()
        return view
    }

    /// The centre of the glyph at `index`, in the view's coordinates.
    private func point(of index: Int, in view: BodyTextView) -> CGPoint {
        let glyphs = view.layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil
        )
        let box = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
        return CGPoint(x: box.midX, y: box.midY)
    }

    func testTappingAMentionOpensThatMention() {
        let view = view("hello @noura and goodbye")
        XCTAssertEqual(view.entity(at: point(of: 7, in: view)), .mention("noura"))
    }

    func testTappingTheWordsAroundAMentionIsNotTheMention() {
        let view = view("hello @noura and goodbye")
        XCTAssertNil(view.entity(at: point(of: 1, in: view)), "a tap on 'hello' belongs to the post")
        XCTAssertNil(view.entity(at: point(of: 14, in: view)), "and so does one on 'and'")
    }

    func testTappingPastTheEndOfTheLineIsNotTheNearestEntity() {
        // The bug, exactly: one mention, and a tap in the empty space after it.
        let view = view("@noura")
        let box = view.layoutManager.boundingRect(
            forGlyphRange: view.layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: 6), actualCharacterRange: nil),
            in: view.textContainer
        )
        XCTAssertNil(view.entity(at: CGPoint(x: box.maxX + 40, y: box.midY)), "the space after the words is the post's")
        XCTAssertNil(view.entity(at: CGPoint(x: box.midX, y: box.maxY + 30)), "so is the line below it")
        XCTAssertEqual(view.entity(at: point(of: 3, in: view)), .mention("noura"), "the mention itself still answers")
    }

    func testTappingAHashtagOpensThatHashtag() {
        let view = view("مساء الخير #الرياض")
        let index = ("مساء الخير #" as NSString).length + 1
        XCTAssertEqual(view.entity(at: point(of: index, in: view)), .hashtag("الرياض"))
        XCTAssertNil(view.entity(at: point(of: 2, in: view)), "the Arabic words are not the tag")
    }

    func testAnEmptyBodyHasNothingToTap() {
        XCTAssertNil(view("").entity(at: .zero))
    }

    func testEveryEntityKeepsItsLinkAndTheWordsKeepTheirColour() {
        let string = PostBodyText.attributed(
            text: "see @aziz about #sila",
            fontSize: 17,
            weight: .regular,
            textColor: .label,
            entityColor: .systemBlue,
            direction: .leftToRight
        )
        XCTAssertEqual(string.string, "see @aziz about #sila", "the text is reproduced exactly")
        var links: [PostEntityLink] = []
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let url = value as? URL, let entity = PostEntityLink.parse(url) { links.append(entity) }
        }
        XCTAssertEqual(links, [.mention("aziz"), .hashtag("sila")])
        XCTAssertEqual(string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .label)
        XCTAssertEqual(string.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor, .systemBlue)
    }

    func testAnArabicPostIsLaidOutFromTheRight() {
        let string = PostBodyText.attributed(
            text: "مرحبا", fontSize: 17, weight: .regular, textColor: .label, entityColor: .systemBlue, direction: .rightToLeft
        )
        let paragraph = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.baseWritingDirection, .rightToLeft)
        XCTAssertEqual(paragraph?.alignment, .natural)
    }
}
