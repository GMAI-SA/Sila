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

    func testAChosenImageIsShrunkToTheCamerasSize() throws {
        let jpeg = try XCTUnwrap(DocumentImport.jpeg(from: image()))
        let decoded = try XCTUnwrap(UIImage(data: jpeg))
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

    func testNoReadableZoneIsSaidAndTheScreenStays() async {
        let (viewModel, _) = make(zone: nil)
        viewModel.choose(.passport)
        await viewModel.importDocument(image(), source: .photos)
        XCTAssertEqual(viewModel.phase, .captureFront)
        XCTAssertEqual(viewModel.importError, L10n.t("document.upload.error.noZone"))
        XCTAssertNil(viewModel.frontImage)
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
