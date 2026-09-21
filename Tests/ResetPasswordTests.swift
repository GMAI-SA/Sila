import XCTest
@testable import Sila

/// Setting a forgotten password.
///
/// The flow used to end on the OTP screen, which exchanges a code for a
/// session — and the server refuses a reset code there deliberately, so the
/// last step of "forgot password" was an error nobody could act on and a
/// forgotten password could not be changed from the app at all.
@MainActor
final class ResetPasswordTests: XCTestCase {

    private func makeModel(
        code: String = "123456",
        scenario: AuthServiceMock.MockScenario = .verified
    ) -> (ResetPasswordViewModel, AuthServiceMock) {
        let service = AuthServiceMock(scenario: scenario, acceptedCode: code)
        return (ResetPasswordViewModel(email: "aziz@example.com", service: service), service)
    }

    func testTheCodeGoesToTheResetRouteWithTheNewPassword() async {
        let (model, service) = makeModel()
        model.code = "123456"
        model.password = "Passw0rd!234"
        model.confirmPassword = "Passw0rd!234"

        let ok = await model.submit()

        let calls = await service.resetCalls
        XCTAssertTrue(ok)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.email, "aziz@example.com")
        XCTAssertEqual(calls.first?.code, "123456")
        XCTAssertEqual(calls.first?.newPassword, "Passw0rd!234",
                       "the password somebody chose is the one that must be sent")
    }

    func testAWrongCodeSaysSoAndChangesNothing() async {
        let (model, _) = makeModel(code: "999999")
        model.code = "123456"
        model.password = "Passw0rd!234"
        model.confirmPassword = "Passw0rd!234"

        let ok = await model.submit()

        XCTAssertFalse(ok)
        XCTAssertNotNil(model.toast, "a refused code has to say so")
    }

    func testTheSamePasswordRulesAsCreatingAnAccount() async {
        let (model, service) = makeModel()
        model.code = "123456"
        model.password = "short"
        model.confirmPassword = "short"

        let ok = await model.submit()

        let calls = await service.resetCalls
        XCTAssertFalse(ok)
        XCTAssertTrue(calls.isEmpty, "a password the server would refuse must not be sent")
        XCTAssertNotNil(model.passwordError)
    }

    func testAMistypedConfirmationIsCaughtHere() async {
        let (model, service) = makeModel()
        model.code = "123456"
        model.password = "Passw0rd!234"
        model.confirmPassword = "Passw0rd!235"

        let ok = await model.submit()

        let calls = await service.resetCalls
        XCTAssertFalse(ok)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNotNil(model.confirmError,
                        "a password nobody can reproduce is worse than the one they forgot")
    }

    func testTheButtonStaysOffUntilEverythingIsThere() async {
        let (model, _) = makeModel()
        XCTAssertFalse(model.canSubmit)
        model.code = "123456"
        XCTAssertFalse(model.canSubmit)
        model.password = "Passw0rd!234"
        XCTAssertFalse(model.canSubmit)
        model.confirmPassword = "Passw0rd!234"
        XCTAssertTrue(model.canSubmit)
    }

    func testAnotherCodeCanBeAskedFor() async {
        let (model, service) = makeModel()
        await model.resend()
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.contains { $0.hasPrefix("sendOTP") },
                      "a message that never arrived needs a second one")
        XCTAssertNotNil(model.toast)
    }

    func testACancelledRequestIsNotReportedAsAFailure() async {
        let service = AuthServiceMock(scenario: .verified, acceptedCode: "123456", latency: 0.4)
        let model = ResetPasswordViewModel(email: "aziz@example.com", service: service)
        model.code = "123456"
        model.password = "Passw0rd!234"
        model.confirmPassword = "Passw0rd!234"

        let task = Task { await model.submit() }
        task.cancel()
        _ = await task.value

        XCTAssertNil(model.toast, "a request that was abandoned did not fail")
    }
}
