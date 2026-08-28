import XCTest
@testable import Sila

/// Registration: validation rules, the happy path, and server-side rejection.
@MainActor
final class RegisterViewModelTests: XCTestCase {

    private func makeViewModel(
        scenario: AuthServiceMock.MockScenario = .unstarted
    ) -> (RegisterViewModel, AuthServiceMock) {
        let service = AuthServiceMock(scenario: scenario)
        return (RegisterViewModel(service: service), service)
    }

    // MARK: Validation

    func testErrorsStaySilentUntilFirstSubmit() {
        let (viewModel, _) = makeViewModel()
        viewModel.email = "not-an-email"
        viewModel.password = "x"

        XCTAssertNil(viewModel.emailError, "Errors must not appear while the user is still typing")
        XCTAssertNil(viewModel.passwordError)
        XCTAssertNil(viewModel.confirmError)
    }

    func testSubmitWithInvalidEmailSurfacesInlineErrorAndDoesNotCallService() async {
        let (viewModel, service) = makeViewModel()
        viewModel.email = "aziz@"
        viewModel.password = "Str0ng!Passw0rd"
        viewModel.confirmPassword = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertEqual(viewModel.emailError, "Enter a valid email address.")
        XCTAssertNil(viewModel.registeredEmail)
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty, "A locally invalid form must never hit the network")
    }

    func testMismatchedConfirmationBlocksSubmit() async {
        let (viewModel, service) = makeViewModel()
        viewModel.email = "aziz@example.com"
        viewModel.password = "Str0ng!Passw0rd"
        viewModel.confirmPassword = "Str0ng!Passw0rdd"

        XCTAssertFalse(viewModel.canSubmit)
        await viewModel.submit()

        XCTAssertEqual(viewModel.confirmError, "Passwords don't match.")
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWeakPasswordBlocksSubmit() async {
        let (viewModel, _) = makeViewModel()
        viewModel.email = "aziz@example.com"
        viewModel.password = "short"
        viewModel.confirmPassword = "short"

        await viewModel.submit()

        XCTAssertEqual(viewModel.passwordError, PasswordStrength.weak.advice)
        XCTAssertFalse(viewModel.canSubmit)
    }

    // MARK: Happy path

    func testSuccessfulRegistrationNormalisesEmailAndClearsPassword() async {
        let (viewModel, service) = makeViewModel()
        viewModel.email = "  Aziz@Example.COM "
        viewModel.password = "Str0ng!Passw0rd"
        viewModel.confirmPassword = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertEqual(viewModel.registeredEmail, "aziz@example.com")
        XCTAssertEqual(viewModel.password, "", "The password must not be retained after submit")
        XCTAssertEqual(viewModel.confirmPassword, "")
        XCTAssertFalse(viewModel.isSubmitting)

        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["register"])
    }

    func testConsumeRegisteredEmailOnlyYieldsOnce() async {
        let (viewModel, _) = makeViewModel()
        viewModel.email = "aziz@example.com"
        viewModel.password = "Str0ng!Passw0rd"
        viewModel.confirmPassword = "Str0ng!Passw0rd"
        await viewModel.submit()

        XCTAssertEqual(viewModel.consumeRegisteredEmail(), "aziz@example.com")
        XCTAssertNil(viewModel.consumeRegisteredEmail(), "Navigation must not fire twice")
    }

    // MARK: Server errors

    func testEmailTakenMapsToInlineFieldError() async {
        let (viewModel, _) = makeViewModel()
        viewModel.email = "taken@sila.app"
        viewModel.password = "Str0ng!Passw0rd"
        viewModel.confirmPassword = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertEqual(viewModel.emailError, "That email already has a Sila account.")
        XCTAssertNil(viewModel.registeredEmail)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testOfflineSurfacesToastAndLeavesFormIntact() async {
        let (viewModel, _) = makeViewModel(scenario: .offline)
        viewModel.email = "aziz@example.com"
        viewModel.password = "Str0ng!Passw0rd"
        viewModel.confirmPassword = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertNil(viewModel.registeredEmail)
        XCTAssertEqual(viewModel.toast?.kind, .error)
        XCTAssertEqual(viewModel.password, "Str0ng!Passw0rd", "A network failure must not wipe the form")
    }
}

/// The password meter's scoring rules.
final class PasswordStrengthTests: XCTestCase {

    func testShortPasswordsAreAlwaysWeak() {
        XCTAssertEqual(PasswordStrength.evaluate(""), .weak)
        XCTAssertEqual(PasswordStrength.evaluate("Ab1!"), .weak)
        XCTAssertEqual(PasswordStrength.evaluate("Ab1!xyz"), .weak, "7 characters is below the minimum")
    }

    func testEightLowercaseCharactersIsFair() {
        XCTAssertEqual(PasswordStrength.evaluate("password"), .fair)
    }

    func testMixedCaseWithDigitsIsGood() {
        XCTAssertEqual(PasswordStrength.evaluate("Passw0rd"), .good)
    }

    func testLongMixedCaseWithDigitAndSymbolIsStrong() {
        XCTAssertEqual(PasswordStrength.evaluate("Str0ng!Passw0rd"), .strong)
    }

    func testOnlyGoodAndStrongAreAcceptable() {
        XCTAssertFalse(PasswordStrength.weak.isAcceptable)
        XCTAssertFalse(PasswordStrength.fair.isAcceptable)
        XCTAssertTrue(PasswordStrength.good.isAcceptable)
        XCTAssertTrue(PasswordStrength.strong.isAcceptable)
    }

    func testFractionsAreMonotonic() {
        let fractions = PasswordStrength.allCases.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
    }
}

/// Email syntax rules shared by every auth screen.
final class EmailValidatorTests: XCTestCase {

    func testAcceptsOrdinaryAddresses() {
        XCTAssertTrue(EmailValidator.isValid("aziz@example.com"))
        XCTAssertTrue(EmailValidator.isValid("first.last+tag@sub.domain.co.uk"))
    }

    func testRejectsMalformedAddresses() {
        XCTAssertFalse(EmailValidator.isValid(""))
        XCTAssertFalse(EmailValidator.isValid("aziz@"))
        XCTAssertFalse(EmailValidator.isValid("@example.com"))
        XCTAssertFalse(EmailValidator.isValid("aziz example.com"))
        XCTAssertFalse(EmailValidator.isValid("aziz@example"))
    }

    func testNormaliseTrimsAndLowercases() {
        XCTAssertEqual(EmailValidator.normalise("  Aziz@Example.COM "), "aziz@example.com")
    }
}
