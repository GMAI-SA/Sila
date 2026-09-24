import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Where a document image came from. Sent with the submission as
/// `document_source`, so a reviewer knows a picture was chosen, not taken.
public enum DocumentSource: String, Sendable, Equatable {
    case camera
    case photos
    case file
}

/// Turns a chosen photo or file into the same JPEG the camera path produces.
///
/// The face check never comes through here: the selfie and the head-turn are
/// camera-only, because a live face is how the document is tied to the person
/// holding it.
public enum DocumentImport {

    /// The long edge a document image is kept at — the camera path's size.
    public static let maxEdge: CGFloat = 1600
    /// PDFs are rendered at this resolution before being scaled down.
    public static let pdfDPI: CGFloat = 200

    /// The types "Choose a file" offers.
    public static let fileTypes: [UTType] = [.pdf, .jpeg, .png, .heic]

    /// A JPEG from whatever was chosen, or `nil` if it is not a readable
    /// image or PDF.
    public static func jpeg(from data: Data, isPDF: Bool? = nil) -> Data? {
        let pdf = isPDF ?? looksLikePDF(data)
        guard let image = pdf ? renderFirstPage(of: data) : UIImage(data: data) else { return nil }
        return ImageEncoding.jpeg(image, maxEdge: maxEdge)
    }

    /// `%PDF` at the start of the file.
    public static func looksLikePDF(_ data: Data) -> Bool {
        data.prefix(4) == Data("%PDF".utf8)
    }

    /// Page one of a PDF, drawn on white at ``pdfDPI``.
    public static func renderFirstPage(of data: Data) -> UIImage? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = pdfDPI / 72
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
}
