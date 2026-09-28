import CoreImage
import UIKit
import XCTest
@testable import Sila

/// Uploading a document instead of photographing it: the same zone checks,
/// and the face check stays live.
@MainActor
final class DocumentUploadTests: XCTestCase {

    private func image(_ color: UIColor = .white, size: CGSize = CGSize(width: 2400, height: 1600)) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 700, width: 500, height: 60))
        }
    }

    private func make(zone: String?, nafathAvailable: Bool = false) -> (DocumentVerificationViewModel, VerificationServiceMock) {
        let service = VerificationServiceMock()
        let viewModel = DocumentVerificationViewModel(service: service, analytics: RecordingAnalyticsClient(),
                                                      declaredDateOfBirth: "1990-01-01", nafathAvailable: nafathAvailable)
        viewModel.zoneReader = { _ in zone }
        return (viewModel, service)
    }

    /// A photo as a phone camera saves it: every pixel different, so it
    /// compresses as badly as a real one.
    private func fullResolutionPhoto(width: Int = 4032, height: Int = 3024) -> Data? {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage,
              let pixels = CIContext().createCGImage(noise, from: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }
        return UIImage(cgImage: pixels).jpegData(compressionQuality: 0.9)
    }

    func testAChosenImageIsShrunkToTheCamerasSize() throws {
        let jpeg = try XCTUnwrap(DocumentImport.jpeg(from: image()))
        let decoded = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(max(decoded.size.width, decoded.size.height), DocumentImport.maxEdge, accuracy: 1)
    }

    /// A genuine photo from the library, far over the old 5 MB limit, is
    /// taken as it is — never refused on the phone — and shrunk to the
    /// camera's size, far below what the server accepts per picture
    /// (contract v27: 40 MB, and verification uploads stay seamless).
    func testAFullResolutionPhotoIsTakenAndShrunk() async throws {
        XCTAssertEqual(DocumentSubmission.maximumBytesPerImage, 40 * 1024 * 1024, "the server's limit per picture")
        let photo = try XCTUnwrap(fullResolutionPhoto())
        XCTAssertGreaterThan(photo.count, 5 * 1024 * 1024, "not a photo the old limit would have refused")

        let (viewModel, _) = make(zone: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.choose(.passport)
        await viewModel.importDocument(photo, source: .photos)

        XCTAssertNil(viewModel.importError)
        XCTAssertEqual(viewModel.phase, .review)
        let front = try XCTUnwrap(viewModel.frontImage)
        XCTAssertLessThan(front.count, DocumentSubmission.maximumBytesPerImage)
        let decoded = try XCTUnwrap(UIImage(data: front))
        XCTAssertEqual(max(decoded.size.width, decoded.size.height), DocumentImport.maxEdge, accuracy: 1)
    }

    func testAPDFIsRenderedFromItsFirstPage() throws {
        let data = pdf()
        XCTAssertTrue(DocumentImport.looksLikePDF(data))
        let page = try XCTUnwrap(DocumentImport.renderFirstPage(of: data))
        XCTAssertEqual(page.size.width, 595 * 200 / 72, accuracy: 1, "rendered at 200 dpi")
        XCTAssertNotNil(DocumentImport.jpeg(from: data))
        XCTAssertNil(DocumentImport.jpeg(from: Data("not a document".utf8)))
    }

    func testAnImageWithAReadableZoneMovesOn() async {
        let (viewModel, _) = make(zone: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.choose(.passport)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertTrue(viewModel.zoneIsReadable)
        XCTAssertEqual(viewModel.documentSource, .photos)
        XCTAssertNil(viewModel.importError)
    }

    func testAPDFIsReadTheSameWay() async {
        let (viewModel, _) = make(zone: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.choose(.nationalId)
        await viewModel.importDocument(pdf(), isPDF: true, source: .file)
        XCTAssertEqual(viewModel.phase, .captureBack)
        await viewModel.importDocument(image(), source: .file)
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertEqual(viewModel.documentSource, .file)
    }

    /// A passport whose zone the reader missed goes on exactly as the same
    /// photo from the camera would: to the review step, which says the zone
    /// could not be read and offers another try, and then to a reviewer.
    /// Refusing it here made the passport camera-only whenever the reader missed.
    func testAPassportWhoseZoneWasNotReadGoesToReviewLikeAPhoto() async {
        let (viewModel, _) = make(zone: nil)
        viewModel.choose(.passport)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertNil(viewModel.importError)
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertNotNil(viewModel.frontImage)
        XCTAssertFalse(viewModel.zoneIsReadable)
        XCTAssertTrue(viewModel.canContinueFromReview, "a reviewer reads it by hand")
        XCTAssertEqual(viewModel.documentSource, .photos)
    }

    /// Every Saudi ID card has no zone: a zoneless card goes to a reviewer,
    /// exactly as a zoneless photo of it does.
    func testAZonelessIDCardUploadProceedsToReview() async {
        let (viewModel, _) = make(zone: nil)
        viewModel.choose(.nationalId)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertNil(viewModel.importError)
        XCTAssertEqual(viewModel.phase, .captureBack)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertEqual(viewModel.phase, .review)
        XCTAssertFalse(viewModel.zoneIsReadable)
        XCTAssertTrue(viewModel.canContinueFromReview, "a reviewer reads it by hand")
    }

    /// Every side of every document takes a photo from Photos or a file —
    /// the front, the back, the passport's one page — and only the face
    /// stays live.
    func testEverySideOfEveryDocumentCanBeUploaded() async {
        for type in DocumentType.allCases {
            for source in [DocumentSource.photos, .file] {
                let (viewModel, _) = make(zone: nil)
                viewModel.choose(type)
                await viewModel.importDocument(image(), source: source)
                XCTAssertNil(viewModel.importError, "\(type) front from \(source)")
                if type.hasBack {
                    XCTAssertEqual(viewModel.phase, .captureBack, "\(type) front from \(source)")
                    await viewModel.importDocument(pdf(), isPDF: true, source: source)
                    XCTAssertNil(viewModel.importError, "\(type) back from \(source)")
                    XCTAssertNotNil(viewModel.backImage, "\(type) back from \(source)")
                }
                XCTAssertEqual(viewModel.phase, .review, "\(type) from \(source)")
                XCTAssertEqual(viewModel.documentSource, source)
                viewModel.confirmDetails()
                XCTAssertEqual(viewModel.phase, .liveness, "\(type) from \(source) reaches the live face check")
            }
        }
    }

    /// The picker or the browser that hands back nothing is said on the
    /// screen, on either side — never a tap that did nothing.
    func testAPickThatBringsNothingIsSaid() async {
        let (viewModel, _) = make(zone: nil)
        viewModel.choose(.nationalId)
        viewModel.importFailed()
        XCTAssertEqual(viewModel.importError, L10n.t("document.upload.error.unreadableFile"))
        XCTAssertEqual(viewModel.phase, .captureFront)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertNil(viewModel.importError)
        viewModel.importFailed()
        XCTAssertEqual(viewModel.importError, L10n.t("document.upload.error.unreadableFile"))
        XCTAssertEqual(viewModel.phase, .captureBack)
    }

    func testAPDFIDCardProceeds() async {
        let (viewModel, _) = make(zone: nil)
        viewModel.choose(.residencePermit)
        await viewModel.importDocument(pdf(), isPDF: true, source: .file)
        XCTAssertEqual(viewModel.phase, .captureBack)
        XCTAssertNotNil(viewModel.frontImage)
        XCTAssertEqual(viewModel.documentSource, .file)
    }

    func testAnUnopenableFileIsSaid() async {
        let (viewModel, _) = make(zone: nil)
        viewModel.choose(.passport)
        await viewModel.importDocument(Data("junk".utf8), source: .file)
        XCTAssertEqual(viewModel.importError, L10n.t("document.upload.error.unreadableFile"))
    }

    func testAnExpiredUploadIsStoppedLikeAPhoto() async {
        let (viewModel, _) = make(zone: MRZParserTests.passport(number: "X12345678", nationality: "USA", expiry: "200101"))
        viewModel.choose(.passport)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertEqual(viewModel.phase, .documentExpired)
    }

    func testASaudiZoneFollowsNafathAvailability() async {
        let saudi = MRZParserTests.passport(number: "X12345678", nationality: "SAU")
        let (closed, _) = make(zone: saudi, nafathAvailable: false)
        closed.choose(.passport)
        await closed.importDocument(image(), source: .photos)
        XCTAssertEqual(closed.phase, .review, "while Nafath is coming soon a Saudi document is the way in")
        let (open, _) = make(zone: saudi, nafathAvailable: true)
        open.choose(.passport)
        await open.importDocument(image(), source: .photos)
        XCTAssertEqual(open.phase, .useNafath)
    }

    func testTheSourceTravelsWithTheSubmission() {
        var submission = DocumentSubmission(documentType: .passport, front: Data([1]), selfie: Data([2]))
        submission.source = .file
        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"document_source\"\r\n\r\nfile"), body.prefix(400).description)
        let camera = String(decoding: DocumentSubmission(documentType: .passport, front: Data([1]), selfie: Data([2]))
            .form(boundary: "B").encoded(), as: UTF8.self)
        XCTAssertTrue(camera.contains("name=\"document_source\"\r\n\r\ncamera"))
    }

    func testUploadsAreOnlyForTheDocumentNotTheFace() async {
        let (viewModel, _) = make(zone: MRZParserTests.passport(number: "X12345678", nationality: "USA"))
        viewModel.choose(.passport)
        await viewModel.importDocument(image(), source: .photos)
        viewModel.confirmDetails()
        XCTAssertEqual(viewModel.phase, .liveness)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertEqual(viewModel.phase, .liveness, "nothing chosen can stand in for the live face check")
        XCTAssertNil(viewModel.selfie)
    }
}
