import XCTest
@testable import TrustNet

/// The six-box code field: auto-advance, backspace, paste, verification and
/// the resend countdown.
@MainActor
final class OTPVerificationViewModelTests: XCTestCase {

    private func makeViewModel(
        scenario: AuthServiceMock.MockScenario = .pendingReview,
        countdown: Int = 60
    ) -> (OTPVerificationViewModel, AuthServiceMock) {
        let service = AuthServiceMock(scenario: scenario)
        let viewModel = OTPVerificationViewModel(
            email: "aziz@example.com",
            purpose: .register,
            service: service,
            initialCountdown: countdown
        )
        return (viewModel, service)
    }

    // MARK: Digit entry

    func testStartsEmptyWithFocusOnFirstBox() {
        let (viewModel, _) = makeViewModel()
        XCTAssertEqual(viewModel.digits.count, AppConfig.otpLength)
        XCTAssertTrue(viewModel.digits.allSatisfy(\.isEmpty))
        XCTAssertEqual(viewModel.focusedIndex, 0)
        XCTAssertFalse(viewModel.isComplete)
    }

    func testTypingADigitAdvancesFocus() {
        let (viewModel, _) = makeViewModel()

        viewModel.input("4", at: 0)

        XCTAssertEqual(viewModel.digits[0], "4")
        XCTAssertEqual(viewModel.focusedIndex, 1)
    }

    func testFocusClearsOnTheLastBoxSoTheKeyboardCanDismiss() {
        let (viewModel, _) = makeViewModel()
        for index in 0..<AppConfig.otpLength {
            viewModel.input("\(index)", at: index)
        }

        XCTAssertNil(viewModel.focusedIndex)
        XCTAssertTrue(viewModel.isComplete)
        XCTAssertEqual(viewModel.code, "012345")
    }

    func testNonDigitsAreIgnored() {
        let (viewModel, _) = makeViewModel()

        viewModel.input("a", at: 0)

        XCTAssertEqual(viewModel.digits[0], "")
        XCTAssertEqual(viewModel.focusedIndex, 0, "Focus must not advance on a rejected character")
    }

    func testOnlyTheFirstCharacterOfASingleEntryIsKept() {
        let (viewModel, _) = makeViewModel()

        viewModel.input("7x", at: 0)

        XCTAssertEqual(viewModel.digits[0], "7")
    }

    // MARK: Backspace

    func testBackspaceOnAFilledBoxClearsItAndKeepsFocus() {
        let (viewModel, _) = makeViewModel()
        viewModel.input("4", at: 0)
        viewModel.input("8", at: 1)

        viewModel.backspace(at: 1)

        XCTAssertEqual(viewModel.digits[1], "")
        XCTAssertEqual(viewModel.focusedIndex, 1)
    }

    func testBackspaceOnAnEmptyBoxClearsThePreviousOneAndMovesBack() {
        let (viewModel, _) = makeViewModel()
        viewModel.input("4", at: 0)

        viewModel.backspace(at: 1)

        XCTAssertEqual(viewModel.digits[0], "")
        XCTAssertEqual(viewModel.focusedIndex, 0)
    }

    func testBackspaceOnTheFirstEmptyBoxIsANoOp() {
        let (viewModel, _) = makeViewModel()

        viewModel.backspace(at: 0)

        XCTAssertEqual(viewModel.focusedIndex, 0)
        XCTAssertTrue(viewModel.digits.allSatisfy(\.isEmpty))
    }

    // MARK: Paste

    func testPastingAFullCodeFillsEveryBoxRegardlessOfTargetBox() {
        let (viewModel, _) = makeViewModel()

        viewModel.input("482913", at: 3)

        XCTAssertEqual(viewModel.code, "482913")
        XCTAssertTrue(viewModel.isComplete)
        XCTAssertNil(viewModel.focusedIndex)
    }

    func testPastingStripsFormattingCharacters() {
        let (viewModel, _) = makeViewModel()

        viewModel.paste("48-29 13")

        XCTAssertEqual(viewModel.code, "482913")
    }

    func testPastingALongerStringTakesTheFirstSixDigits() {
        let (viewModel, _) = makeViewModel()

        viewModel.paste("4829135566")

        XCTAssertEqual(viewModel.code, "482913")
    }

    func testPastingAPartialCodeLeavesFocusOnTheFirstEmptyBox() {
        let (viewModel, _) = makeViewModel()

        viewModel.paste("482")

        XCTAssertEqual(viewModel.digits[0], "4")
        XCTAssertEqual(viewModel.digits[2], "2")
        XCTAssertEqual(viewModel.focusedIndex, 3)
        XCTAssertFalse(viewModel.isComplete)
    }

    // MARK: Countdown

    func testCountdownStartsAtTheSuppliedValueAndBlocksResend() {
        let (viewModel, _) = makeViewModel(countdown: 60)

        XCTAssertEqual(viewModel.resendCountdown, 60)
        XCTAssertFalse(viewModel.canResend)
        XCTAssertEqual(viewModel.resendTitle, "Resend in 60s")
    }

    func testEachTickDecrementsByOneSecond() {
        let (viewModel, _) = makeViewModel(countdown: 3)

        XCTAssertTrue(viewModel.tickCountdown())
        XCTAssertEqual(viewModel.resendCountdown, 2)
        XCTAssertTrue(viewModel.tickCountdown())
        XCTAssertEqual(viewModel.resendCountdown, 1)
    }

    func testTheFinalTickReturnsFalseSoTheDriverStops() {
        let (viewModel, _) = makeViewModel(countdown: 1)

        XCTAssertFalse(viewModel.tickCountdown(), "Reaching zero must stop the loop")
        XCTAssertEqual(viewModel.resendCountdown, 0)
        XCTAssertTrue(viewModel.canResend)
        XCTAssertEqual(viewModel.resendTitle, "Resend code")
    }

    func testTickingBelowZeroIsNotPossible() {
        let (viewModel, _) = makeViewModel(countdown: 0)

        XCTAssertFalse(viewModel.tickCountdown())
        XCTAssertEqual(viewModel.resendCountdown, 0)
    }

    func testResendRestartsTheCountdownAndClearsTheBoxes() async {
        let (viewModel, service) = makeViewModel(countdown: 0)
        viewModel.paste("482913")

        await viewModel.resend()
        viewModel.stopCountdown()

        XCTAssertEqual(viewModel.resendCountdown, AppConfig.defaultOTPResendSeconds)
        XCTAssertFalse(viewModel.canResend)
        XCTAssertEqual(viewModel.code, "", "A fresh code means a fresh field")
        XCTAssertEqual(viewModel.toast?.kind, .success)

        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["sendOTP:register"])
    }

    func testResendIsIgnoredWhileTheCountdownIsRunning() async {
        let (viewModel, service) = makeViewModel(countdown: 42)

        await viewModel.resend()

        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(viewModel.resendCountdown, 42)
    }

    // MARK: Verification

    func testVerifyingTheCorrectCodeYieldsATokenPair() async {
        let (viewModel, _) = makeViewModel()
        viewModel.paste("123456")

        await viewModel.verify()

        XCTAssertNotNil(viewModel.verifiedPair)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.consumeVerifiedPair()?.user.email, "aziz@example.com")
        XCTAssertNil(viewModel.consumeVerifiedPair(), "Navigation must not fire twice")
    }

    func testVerifyingAnIncorrectCodeClearsTheFieldAndExplains() async {
        let (viewModel, _) = makeViewModel(scenario: .otpAlwaysInvalid)
        viewModel.paste("000000")

        await viewModel.verify()

        XCTAssertNil(viewModel.verifiedPair)
        XCTAssertEqual(viewModel.errorMessage, "That code isn't right. Check the digits and try again.")
        XCTAssertEqual(viewModel.code, "")
        XCTAssertEqual(viewModel.focusedIndex, 0)
    }

    func testVerifyDoesNothingUntilAllSixBoxesAreFilled() async {
        let (viewModel, service) = makeViewModel()
        viewModel.paste("123")

        await viewModel.verify()

        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Display

    func testEmailIsMaskedForDisplay() {
        let (viewModel, _) = makeViewModel()
        XCTAssertEqual(viewModel.maskedEmail, "a••z@example.com")
    }
}
