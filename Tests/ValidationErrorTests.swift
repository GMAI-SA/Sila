import XCTest
@testable import Sila

/// A refused form must be explained in words, never in the server's JSON.
///
/// A two-letter room name once put
/// `{"detail":[{"type":"string_too_short","loc":["body","title"],…}]}` on a
/// screen, verbatim. Three shapes can carry a validation reply and every
/// one of them has to come out as a sentence.
final class ValidationErrorTests: XCTestCase {

    private func error(_ status: Int, _ body: String) -> APIError {
        URLSessionNetworkClient.makeError(status: status, data: Data(body.utf8))
    }

    func testFastAPIsOwnListShapeBecomesASentenceAboutTheField() {
        let error = error(422, #"{"detail":[{"type":"string_too_short","loc":["body","title"],"msg":"String should have at least 3 characters","input":"Gg","ctx":{"min_length":3}}]}"#)
        XCTAssertEqual(error.code, .validationError)
        XCTAssertEqual(error.userMessage, L10n.plural("error.validation.tooShort", 3))
        XCTAssertFalse(error.userMessage.contains("{"), "no JSON reaches a screen")
        XCTAssertFalse(error.userMessage.contains("string_too_short"))
    }

    func testTheServersWrappedShapeIsRebuiltFromItsFieldsNotItsWording() {
        let error = error(422, #"{"detail":{"code":"validation_error","message":"Title: String should have at least 3 characters","fields":[{"field":"title","type":"string_too_long","message":"too long","ctx":{"max_length":120}}]}}"#)
        XCTAssertEqual(error.code, .validationError)
        XCTAssertEqual(error.userMessage, L10n.plural("error.validation.tooLong", 120))
        XCTAssertFalse(error.userMessage.contains("Title:"), "the server's sentence is for developers")
    }

    func testARuleWithoutALimitFallsBackToTheGenericSentence() {
        let error = error(422, #"{"detail":[{"type":"value_error","loc":["body","scope"],"msg":"bad scope"}]}"#)
        XCTAssertEqual(error.code, .validationError)
        XCTAssertEqual(error.userMessage, L10n.t("error.validation"))
    }

    func testAnUnrecognisable422StillNeverShowsItsBody() {
        let error = error(422, #"<html>nope</html>"#)
        XCTAssertEqual(error.code, .validationError)
        XCTAssertEqual(error.userMessage, L10n.t("error.validation"))
    }

    func testOtherStructuredErrorsAreUntouched() {
        let error = error(409, #"{"detail":{"code":"email_taken","message":"An account with this email already exists"}}"#)
        XCTAssertEqual(error.code, .emailTaken)
    }

    @MainActor
    func testTheRoomFormRefusesATwoLetterNameBeforeAsking() async {
        let service = RoomsServiceMock()
        let viewModel = CreateRoomViewModel(
            author: ComposerAuthor(countryCode: "SA", isVerified: true),
            service: service,
            preferences: PreferencesServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        viewModel.title = "Gg"
        XCTAssertEqual(viewModel.blockingReason, RoomCopy.titleTooShort)
        XCTAssertFalse(viewModel.canCreate)
        let created = await viewModel.create()
        XCTAssertNil(created)
        XCTAssertEqual(viewModel.titleError, RoomCopy.titleTooShort)
        let calls = await service.recordedCalls
        XCTAssertFalse(calls.contains { $0.hasPrefix("create") }, "nothing was sent")

        viewModel.title = "Ggg"
        XCTAssertNil(viewModel.blockingReason)
    }
}
