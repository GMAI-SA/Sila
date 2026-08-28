import XCTest
@testable import TrustNet

/// Sign-in: credentials, the `email_unverified` detour, and biometric unlock.
@MainActor
final class SignInViewModelTests: XCTestCase {

    private func makeViewModel(
        scenario: AuthServiceMock.MockScenario = .verified,
        hasBiometricCredential: Bool = false,
        biometry: BiometryKind = .faceID,
        biometricsEnabled: Bool = true
    ) -> (SignInViewModel, AuthServiceMock) {
        let service = AuthServiceMock(
            scenario: scenario,
            biometry: biometry,
            hasBiometricCredential: hasBiometricCredential
        )
        let viewModel = SignInViewModel(service: service, biometricsEnabled: biometricsEnabled)
        return (viewModel, service)
    }

    // MARK: Validation

    func testErrorsStaySilentUntilFirstSubmit() {
        let (viewModel, _) = makeViewModel()
        viewModel.email = "nope"

        XCTAssertNil(viewModel.emailError)
        XCTAssertNil(viewModel.passwordError)
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testInvalidFormDoesNotReachTheNetwork() async {
        let (viewModel, service) = makeViewModel()
        viewModel.email = "nope"
        viewModel.password = ""

        await viewModel.submit()

        XCTAssertEqual(viewModel.emailError, "Enter a valid email address.")
        XCTAssertEqual(viewModel.passwordError, "Enter your password.")
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Happy path

    func testSuccessfulSignInYieldsAPairAndDiscardsThePassword() async {
        let (viewModel, service) = makeViewModel(scenario: .verified)
        viewModel.email = "Aziz@Example.com"
        viewModel.password = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertNotNil(viewModel.signedInPair)
        XCTAssertEqual(viewModel.password, "", "The password must never outlive the call")
        XCTAssertEqual(viewModel.signedInPair?.user.verificationStatus, .verified)

        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["signIn"])
    }

    func testConsumeSignedInPairOnlyYieldsOnce() async {
        let (viewModel, _) = makeViewModel(scenario: .verified)
        viewModel.email = "aziz@example.com"
        viewModel.password = "Str0ng!Passw0rd"
        await viewModel.submit()

        XCTAssertNotNil(viewModel.consumeSignedInPair())
        XCTAssertNil(viewModel.consumeSignedInPair())
    }

    // MARK: Failure paths

    func testInvalidCredentialsShowAToastAndNoRoute() async {
        let (viewModel, _) = makeViewModel(scenario: .invalidCredentials)
        viewModel.email = "aziz@example.com"
        viewModel.password = "wrong-password"

        await viewModel.submit()

        XCTAssertNil(viewModel.signedInPair)
        XCTAssertNil(viewModel.needsEmailVerification)
        XCTAssertEqual(viewModel.toast?.kind, .error)
        XCTAssertEqual(viewModel.toast?.text, "That email and password don't match.")
        XCTAssertEqual(viewModel.password, "")
    }

    func testUnverifiedEmailRoutesToOTPAndRequestsAFreshCode() async {
        let (viewModel, service) = makeViewModel(scenario: .emailUnverified)
        viewModel.email = "  Aziz@Example.com "
        viewModel.password = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertNil(viewModel.signedInPair)
        XCTAssertEqual(viewModel.needsEmailVerification, "aziz@example.com")
        XCTAssertNil(viewModel.toast, "The detour is not an error the user needs shouting at them")

        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["signIn", "sendOTP:login"])
        XCTAssertEqual(viewModel.consumeNeedsEmailVerification(), "aziz@example.com")
        XCTAssertNil(viewModel.consumeNeedsEmailVerification(), "Navigation must not fire twice")
    }

    func testOfflineShowsATransportToast() async {
        let (viewModel, _) = makeViewModel(scenario: .offline)
        viewModel.email = "aziz@example.com"
        viewModel.password = "Str0ng!Passw0rd"

        await viewModel.submit()

        XCTAssertNil(viewModel.signedInPair)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    // MARK: Biometrics

    func testBiometricButtonHiddenWithoutASavedCredential() async {
        let (viewModel, _) = makeViewModel(hasBiometricCredential: false)

        await viewModel.loadBiometricState()

        XCTAssertNil(viewModel.biometricEmail)
        XCTAssertFalse(viewModel.showsBiometricButton)
    }

    func testBiometricButtonShownAndEmailPrefilledWhenACredentialExists() async {
        let (viewModel, _) = makeViewModel(hasBiometricCredential: true)

        await viewModel.loadBiometricState()

        XCTAssertEqual(viewModel.biometricEmail, "saved@trustnet.app")
        XCTAssertEqual(viewModel.email, "saved@trustnet.app")
        XCTAssertTrue(viewModel.showsBiometricButton)
        XCTAssertEqual(viewModel.biometricButtonTitle, "Sign in with Face ID")
    }

    func testBiometricButtonHiddenWhenTheDeviceHasNoBiometry() async {
        let (viewModel, _) = makeViewModel(hasBiometricCredential: true, biometry: .none)

        await viewModel.loadBiometricState()

        XCTAssertFalse(viewModel.showsBiometricButton)
    }

    func testBiometricButtonHiddenWhenTheFeatureFlagIsOff() async {
        let (viewModel, _) = makeViewModel(hasBiometricCredential: true, biometricsEnabled: false)

        await viewModel.loadBiometricState()

        XCTAssertNil(viewModel.biometricEmail)
        XCTAssertFalse(viewModel.showsBiometricButton)
    }

    func testBiometricSignInYieldsAPair() async {
        let (viewModel, service) = makeViewModel(scenario: .verified, hasBiometricCredential: true)
        await viewModel.loadBiometricState()

        await viewModel.signInWithBiometrics()

        XCTAssertEqual(viewModel.signedInPair?.user.email, "saved@trustnet.app")
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["signInBiometric"])
    }

    func testBiometricSignInIsIgnoredWhenTheButtonIsNotAvailable() async {
        let (viewModel, service) = makeViewModel(hasBiometricCredential: false)
        await viewModel.loadBiometricState()

        await viewModel.signInWithBiometrics()

        XCTAssertNil(viewModel.signedInPair)
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTouchIDDeviceLabelsTheButtonCorrectly() async {
        let (viewModel, _) = makeViewModel(hasBiometricCredential: true, biometry: .touchID)

        await viewModel.loadBiometricState()

        XCTAssertEqual(viewModel.biometricButtonTitle, "Sign in with Touch ID")
    }
}

/// The forgotten-password step.
@MainActor
final class ForgotPasswordViewModelTests: XCTestCase {

    func testSendsAResetPurposeCode() async {
        let service = AuthServiceMock(scenario: .verified)
        let viewModel = ForgotPasswordViewModel(service: service)
        viewModel.email = " Aziz@Example.com "

        await viewModel.submit()

        XCTAssertEqual(viewModel.sentToEmail, "aziz@example.com")
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["sendOTP:reset"])
    }

    func testInvalidEmailIsRejectedLocally() async {
        let service = AuthServiceMock(scenario: .verified)
        let viewModel = ForgotPasswordViewModel(service: service)
        viewModel.email = "nope"

        await viewModel.submit()

        XCTAssertEqual(viewModel.emailError, "Enter a valid email address.")
        XCTAssertNil(viewModel.sentToEmail)
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testConsumeSentEmailOnlyYieldsOnce() async {
        let service = AuthServiceMock(scenario: .verified)
        let viewModel = ForgotPasswordViewModel(service: service, prefilledEmail: "aziz@example.com")

        await viewModel.submit()

        XCTAssertEqual(viewModel.consumeSentToEmail(), "aziz@example.com")
        XCTAssertNil(viewModel.consumeSentToEmail())
    }
}
