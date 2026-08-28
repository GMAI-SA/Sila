import XCTest
@testable import Sila

/// ``AccountViewModel`` against ``AccountServiceMock``.
///
/// The interesting behaviour on this surface is entirely in the refusals and in
/// one piece of routing, so that is what these cover: the gate in front of
/// deletion, the 403 that must never become an error alert, and the phone rules
/// that keep an unverified number from looking like a verified one.
@MainActor
final class AccountViewModelTests: XCTestCase {

    private func makeViewModel(
        _ scenario: AccountServiceMock.MockScenario = .populated,
        analytics: RecordingAnalyticsClient = RecordingAnalyticsClient(),
        onSignOut: (@MainActor () -> Void)? = nil
    ) -> (AccountViewModel, AccountServiceMock) {
        let service = AccountServiceMock(scenario: scenario)
        let viewModel = AccountViewModel(
            service: service,
            analytics: analytics,
            onSignOut: onSignOut
        )
        return (viewModel, service)
    }

    private let password = AccountServiceMock.correctPassword

    // MARK: - Loading

    func testLoadingAdoptsTheServerCopyAndSeedsTheDraft() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.load()

        XCTAssertEqual(viewModel.route, .settings)
        XCTAssertEqual(viewModel.account?.email, "aziz@example.com")
        XCTAssertEqual(viewModel.profileDraft, ProfileDraft(account: AccountServiceMock.filledIn))
        XCTAssertFalse(viewModel.hasProfileChanges)
        XCTAssertNil(viewModel.loadError)
    }

    func testAFailedLoadReportsItselfAndOffersARetry() async {
        let (viewModel, service) = makeViewModel(.offline)

        await viewModel.load()
        XCTAssertNotNil(viewModel.loadError)
        XCTAssertNil(viewModel.account)

        await service.setScenario(.populated)
        await viewModel.reload()
        XCTAssertNil(viewModel.loadError)
        XCTAssertNotNil(viewModel.account)
    }

    // MARK: - The deletion gate

    /// **Both conditions, and only both.** This is the last barrier in front of
    /// an action that takes somebody's account away.
    func testDeletionIsBlockedUntilThePasswordAndTheExactWordAreBothThere() {
        var gate = DeletionConfirmation()
        XCTAssertFalse(gate.isConfirmable, "empty form")

        gate = DeletionConfirmation(currentPassword: "", typedWord: "DELETE")
        XCTAssertFalse(gate.isConfirmable, "word without a password")

        gate = DeletionConfirmation(currentPassword: "pw", typedWord: "")
        XCTAssertFalse(gate.isConfirmable, "password without a word")

        gate = DeletionConfirmation(currentPassword: "pw", typedWord: "DELETE")
        XCTAssertTrue(gate.isConfirmable, "both present")
    }

    /// Case-sensitive, and **no trimming into a match**. A stray space typed by
    /// somebody who has not finished reading is not consent, and the server
    /// refuses those with `confirmation_required` anyway.
    func testTheConfirmationWordIsCompareByteForByte() {
        let near = ["delete", "Delete", "DELETE ", " DELETE", "DELETE\n", "DELETED", "DEL ETE", "ELETE"]
        for word in near {
            XCTAssertFalse(
                DeletionConfirmation(currentPassword: "pw", typedWord: word).isConfirmable,
                "\"\(word)\" must not count as confirmation"
            )
        }
        XCTAssertTrue(DeletionConfirmation(currentPassword: "pw", typedWord: "DELETE").isConfirmable)
    }

    /// A password of nothing but spaces is a password. Trimming it would refuse
    /// a real one.
    func testAWhitespacePasswordStillCountsAsPresent() {
        XCTAssertTrue(DeletionConfirmation(currentPassword: " ", typedWord: "DELETE").isConfirmable)
    }

    func testTheGateSaysWhichHalfIsMissing() {
        XCTAssertEqual(
            DeletionConfirmation().blockingReason,
            "Enter your password and type DELETE to continue."
        )
        XCTAssertEqual(
            DeletionConfirmation(currentPassword: "", typedWord: "DELETE").blockingReason,
            "Enter your current password to continue."
        )
        XCTAssertEqual(
            DeletionConfirmation(currentPassword: "pw", typedWord: "delete").blockingReason,
            "Type DELETE in capitals, exactly, to continue."
        )
        XCTAssertNil(DeletionConfirmation(currentPassword: "pw", typedWord: "DELETE").blockingReason)
    }

    func testTheViewModelRefusesToCallDeleteUntilTheGateOpens() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        viewModel.deletion = DeletionConfirmation(currentPassword: password, typedWord: "delete")
        XCTAssertFalse(viewModel.canConfirmDeletion)
        await viewModel.requestDeletion()
        var seen = await service.receivedDeletions
        XCTAssertTrue(seen.isEmpty, "a lowercase word reached the server")

        viewModel.deletion = DeletionConfirmation(currentPassword: "", typedWord: "DELETE")
        XCTAssertFalse(viewModel.canConfirmDeletion)
        await viewModel.requestDeletion()
        seen = await service.receivedDeletions
        XCTAssertTrue(seen.isEmpty, "a missing password reached the server")

        viewModel.deletion = DeletionConfirmation(currentPassword: password, typedWord: "DELETE")
        XCTAssertTrue(viewModel.canConfirmDeletion)
        await viewModel.requestDeletion()
        seen = await service.receivedDeletions
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.typedWord, "DELETE")
    }

    func testASuccessfulDeletionRoutesStraightToRecovery() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.deletion = DeletionConfirmation(currentPassword: password, typedWord: "DELETE")
        await viewModel.requestDeletion()

        XCTAssertEqual(viewModel.route, .recovery)
        XCTAssertNil(viewModel.presentedSheet)
        XCTAssertEqual(viewModel.deletionSchedule?.graceDays, DeletionDisclosure.graceDays)
        XCTAssertEqual(
            viewModel.deletion, DeletionConfirmation(),
            "the password typed to delete an account has no reason to outlive the call"
        )
    }

    func testAWrongPasswordAtDeletionIsReportedAndChangesNothing() async {
        let (viewModel, _) = makeViewModel(.wrongPassword)
        await viewModel.load()

        viewModel.deletion = DeletionConfirmation(currentPassword: "nope", typedWord: "DELETE")
        await viewModel.requestDeletion()

        XCTAssertEqual(viewModel.route, .settings)
        XCTAssertNotNil(viewModel.deletionError)
        XCTAssertNil(viewModel.deletionSchedule)
    }

    // MARK: - 403 routing

    func testTheDeactivationErrorMapsToRecoveryAndNothingElseDoes() {
        XCTAssertEqual(
            AccountRouting.route(forError: APIError.api(
                code: .accountDeactivated, message: "…", status: 403
            )),
            .recovery
        )
        // A 403 that is *not* a deactivation — a wrong current password — is an
        // ordinary failure the form must report, not a route.
        XCTAssertNil(AccountRouting.route(forError: APIError.api(
            code: .invalidCredentials, message: "…", status: 403
        )))
        XCTAssertNil(AccountRouting.route(forError: APIError.transport("offline")))
        XCTAssertNil(AccountRouting.route(forError: APIError.unauthenticated))
    }

    /// `GET /me/account` answers `200` for a deactivated account, so the
    /// recovery screen appears on the way in rather than after some later call
    /// happens to fail.
    func testLoadingAPendingDeletionLandsOnRecovery() async {
        let (viewModel, _) = makeViewModel(.pendingDeletion)

        await viewModel.load()

        XCTAssertEqual(viewModel.route, .recovery)
        XCTAssertNil(viewModel.loadError, "this is a state, not a failure")
        XCTAssertEqual(viewModel.account?.isPendingDeletion, true)
        XCTAssertNotNil(viewModel.daysUntilPurge())
    }

    /// **The core requirement.** Any call answering `403 account_deactivated`
    /// routes to recovery and publishes no error string — a generic alert with a
    /// Retry button would loop somebody through the same 403 until the purge
    /// ran and the choice stopped existing.
    func testEveryCallThatIsRefusedForDeactivationRoutesInsteadOfErroring() async {
        // Each closure is one call the account screen can make.
        let calls: [(String, (AccountViewModel) async -> Void)] = [
            ("password", { viewModel in
                viewModel.passwordCurrent = "pw"
                viewModel.passwordNew = "new-password"
                viewModel.passwordRepeat = "new-password"
                await viewModel.changePassword()
            }),
            ("email request", { viewModel in
                viewModel.emailPassword = "pw"
                viewModel.emailNew = "new@example.com"
                await viewModel.requestEmailChange()
            }),
            ("phone", { viewModel in
                viewModel.phonePassword = "pw"
                viewModel.phoneDraft = "+966501234567"
                await viewModel.savePhone()
            }),
            ("avatar", { viewModel in
                await viewModel.setAvatar(data: Data([0xFF, 0xD8, 0xFF, 0xE0]))
            }),
            ("profile", { viewModel in
                viewModel.profileDraft.displayName = "Something else"
                await viewModel.saveProfile()
            }),
            ("export", { viewModel in await viewModel.exportAccount() })
        ]

        for (name, call) in calls {
            let (viewModel, _) = makeViewModel(.pendingDeletion)
            await viewModel.load()
            // Pretend the screen never noticed on the way in, so the 403 is the
            // only thing that can produce the route.
            viewModel.forceRouteForTesting(.settings)

            await call(viewModel)

            XCTAssertEqual(viewModel.route, .recovery, "\(name) did not route to recovery")
            XCTAssertNil(viewModel.passwordError, "\(name) published an error")
            XCTAssertNil(viewModel.emailError, "\(name) published an error")
            XCTAssertNil(viewModel.phoneError, "\(name) published an error")
            XCTAssertNil(viewModel.avatarError, "\(name) published an error")
            XCTAssertNil(viewModel.profileError, "\(name) published an error")
            XCTAssertNil(viewModel.exportError, "\(name) published an error")
        }
    }

    func testRoutingToRecoveryClosesTheSheetAndForgetsEveryPassword() async {
        let (viewModel, _) = makeViewModel(.pendingDeletion)
        await viewModel.load()
        viewModel.forceRouteForTesting(.settings)
        viewModel.presentedSheet = .password
        viewModel.passwordCurrent = "secret"
        viewModel.passwordNew = "another-secret"
        viewModel.passwordRepeat = "another-secret"

        await viewModel.changePassword()

        XCTAssertEqual(viewModel.route, .recovery)
        XCTAssertNil(viewModel.presentedSheet)
        XCTAssertEqual(viewModel.passwordCurrent, "")
        XCTAssertEqual(viewModel.passwordNew, "")
        XCTAssertEqual(viewModel.passwordRepeat, "")
    }

    func testTheRouteIsRecordedWithItsSource() async {
        let analytics = RecordingAnalyticsClient()
        let (viewModel, _) = makeViewModel(.pendingDeletion, analytics: analytics)

        await viewModel.load()

        XCTAssertTrue(analytics.events.contains(.accountDeletionRouted))
    }

    // MARK: - Recovery

    func testCancellingDeletionRestoresTheAccountAndTheSettingsSurface() async {
        let (viewModel, _) = makeViewModel(.pendingDeletion)
        await viewModel.load()
        XCTAssertEqual(viewModel.route, .recovery)

        await viewModel.cancelDeletion()

        XCTAssertEqual(viewModel.route, .settings)
        XCTAssertEqual(viewModel.account?.isPendingDeletion, false)
        XCTAssertNil(viewModel.recoveryError)
        XCTAssertNotNil(viewModel.toast)
    }

    /// Nothing left to cancel is the outcome the person wanted, so it is
    /// reported as one rather than as a failure.
    func testCancellingWhenThereIsNothingToCancelIsNotAnError() async {
        let (viewModel, _) = makeViewModel(.populated)
        await viewModel.load()
        viewModel.forceRouteForTesting(.recovery)

        await viewModel.cancelDeletion()

        XCTAssertEqual(viewModel.route, .settings)
        XCTAssertNil(viewModel.recoveryError)
        XCTAssertEqual(viewModel.toast?.kind, .success)
    }

    func testDeleteThenCancelIsAFullRoundTrip() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.deletion = DeletionConfirmation(currentPassword: password, typedWord: "DELETE")
        await viewModel.requestDeletion()
        XCTAssertEqual(viewModel.route, .recovery)

        await viewModel.cancelDeletion()
        XCTAssertEqual(viewModel.route, .settings)
        XCTAssertEqual(viewModel.account?.email, "aziz@example.com")
    }

    func testTheRecoveryScreenCanEndTheSession() async {
        var signedOut = false
        let (viewModel, _) = makeViewModel(.pendingDeletion, onSignOut: { signedOut = true })
        await viewModel.load()

        viewModel.signOut()

        XCTAssertTrue(signedOut)
    }

    // MARK: - Phone

    func testNormalisationStripsExactlyWhatTheServerStrips() {
        XCTAssertEqual(PhoneNumber.normalised(" +966 50 123 4567 "), "+966501234567")
        XCTAssertEqual(PhoneNumber.normalised("+966-50-123-4567"), "+966501234567")
        // Brackets and dots are *not* stripped by the server, so they are not
        // stripped here either — accepting more than the server does would send
        // a number it will reject.
        XCTAssertEqual(PhoneNumber.normalised("+966(50)1234567"), "+966(50)1234567")
        XCTAssertFalse(PhoneNumber.isE164(PhoneNumber.normalised("+966(50)1234567")))
    }

    func testE164ShapeMatchesTheServersLengthRule() {
        XCTAssertTrue(PhoneNumber.isE164("+9665012"), "8 characters is the floor")
        XCTAssertFalse(PhoneNumber.isE164("+966501"), "7 characters is under it")
        XCTAssertTrue(PhoneNumber.isE164("+" + String(repeating: "9", count: 15)), "16 is the ceiling")
        XCTAssertFalse(PhoneNumber.isE164("+" + String(repeating: "9", count: 16)), "17 is over it")
        XCTAssertFalse(PhoneNumber.isE164("0501234567"), "no plus")
        XCTAssertFalse(PhoneNumber.isE164("+96650123456a"), "not all digits")
        XCTAssertFalse(PhoneNumber.isE164("+"), "nothing after the plus")
        XCTAssertFalse(PhoneNumber.isE164("+٩٦٦٥٠١٢٣٤٥٦"), "Arabic-Indic digits are not ASCII digits")
    }

    func testValidationReportsWhyRatherThanJustFailing() {
        XCTAssertEqual(PhoneNumber.validate("  "), .failure(.empty))
        XCTAssertEqual(PhoneNumber.validate("0501234567"), .failure(.notE164))
        XCTAssertEqual(PhoneNumber.validate(" +966 50 123 4567"), .success("+966501234567"))
        XCTAssertTrue(PhoneEntryError.notE164.message.contains("+966501234567"))
    }

    /// The display grouping is cosmetic and reversible. It never claims to know
    /// where the country code ends, because this client does not.
    func testDisplayGroupingIsPurelyVisualAndRoundTrips() {
        XCTAssertEqual(PhoneNumber.display("+966501234567"), "+966 501 234 567")
        XCTAssertEqual(PhoneNumber.display("+12025550143"), "+120 255 501 43")
        XCTAssertEqual(
            PhoneNumber.normalised(PhoneNumber.display("+966501234567") ?? ""),
            "+966501234567",
            "formatting must never change what would be stored"
        )
        XCTAssertNil(PhoneNumber.display(nil))
        XCTAssertEqual(PhoneNumber.display("nonsense"), "nonsense", "left alone rather than mangled")
    }

    func testAnInvalidNumberNeverReachesTheServer() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        viewModel.phonePassword = password
        viewModel.phoneDraft = "0501234567"
        await viewModel.savePhone()

        let seen = await service.receivedPhones
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(viewModel.phoneError, PhoneEntryError.notE164.message)
        XCTAssertEqual(viewModel.account?.phone, "+966501234567", "the stored number is untouched")
    }

    func testSavingAValidNumberSendsTheNormalisedFormAndClearsThePassword() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        viewModel.phonePassword = password
        viewModel.phoneDraft = "+966 50 999 8888"
        await viewModel.savePhone()

        let seen = await service.receivedPhones
        XCTAssertEqual(seen.map(\.phone), ["+966509998888"])
        XCTAssertEqual(viewModel.account?.phone, "+966509998888")
        XCTAssertEqual(viewModel.displayPhone, "+966 509 998 888")
        XCTAssertEqual(viewModel.phonePassword, "", "the password does not outlive the call")
    }

    /// Removing a contact detail is still a change to the account, so the rule
    /// does not bend for the changes that happen to be subtractive.
    func testRemovingTheNumberStillRequiresThePassword() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        viewModel.phonePassword = ""
        await viewModel.removePhone()
        var seen = await service.receivedPhones
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(viewModel.account?.phone, "+966501234567")

        viewModel.phonePassword = password
        await viewModel.removePhone()
        seen = await service.receivedPhones
        XCTAssertEqual(seen.count, 1)
        XCTAssertNil(seen.first?.phone, "cleared with an explicit null")
        XCTAssertNil(viewModel.account?.phone)
        XCTAssertFalse(viewModel.hasPhone)
    }

    func testAWrongPasswordOnThePhoneFormIsReportedNotRouted() async {
        let (viewModel, _) = makeViewModel(.wrongPassword)
        await viewModel.load()

        viewModel.phonePassword = "nope"
        viewModel.phoneDraft = "+966509998888"
        await viewModel.savePhone()

        XCTAssertEqual(viewModel.route, .settings, "a wrong password is not a deactivation")
        XCTAssertNotNil(viewModel.phoneError)
    }

    // MARK: - Avatar

    func testAnOversizedPhotoIsRefusedWithoutAnUpload() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        await viewModel.setAvatar(data: Data(repeating: 0xFF, count: AvatarUpload.maximumBytes + 1))

        let uploads = await service.receivedAvatars
        XCTAssertTrue(uploads.isEmpty, "5 MB went over the wire to earn a 413")
        XCTAssertEqual(viewModel.avatarError, AvatarRejection.tooLarge(
            bytes: AvatarUpload.maximumBytes + 1
        ).message)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testARefusedPhotoIsRecordedAsAClientSideRefusal() async {
        let analytics = RecordingAnalyticsClient()
        let (viewModel, _) = makeViewModel(analytics: analytics)
        await viewModel.load()

        await viewModel.setAvatar(data: Data(repeating: 0xFF, count: AvatarUpload.maximumBytes + 1))

        XCTAssertTrue(analytics.events.contains(.accountAvatarRejected))
        XCTAssertFalse(analytics.events.contains(.accountAvatarUploaded))
    }

    func testAGoodPhotoIsUploadedAndTheToastMentionsTheStrippedLocation() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        await viewModel.setAvatar(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))

        let uploads = await service.receivedAvatars
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.mimeType, "image/jpeg")
        XCTAssertNil(viewModel.avatarError)
        XCTAssertEqual(viewModel.toast?.kind, .success)
        XCTAssertTrue(viewModel.toast?.text.contains("Location data") == true)
    }

    func testRemovingThePictureClearsIt() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()
        XCTAssertNotNil(viewModel.account?.avatarPath)

        await viewModel.removeAvatar()

        XCTAssertNil(viewModel.account?.avatarPath)
        XCTAssertNil(viewModel.account?.avatarURL)
    }

    // MARK: - Profile

    func testProfileSaveSendsOnlyTheChangedFieldAndAdoptsTheResponse() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        viewModel.profileDraft.bio = "A new bio"
        XCTAssertTrue(viewModel.hasProfileChanges)
        XCTAssertTrue(viewModel.canSaveProfile)

        await viewModel.saveProfile()

        let updates = await service.receivedProfileUpdates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.bio, "A new bio")
        XCTAssertNil(updates.first?.handle)
        XCTAssertNil(updates.first?.displayName)
        XCTAssertEqual(viewModel.account?.bio, "A new bio")
        XCTAssertFalse(viewModel.hasProfileChanges)
    }

    func testAnInvalidHandleNeverLeavesTheDevice() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.load()

        viewModel.profileDraft.handle = "no"
        XCTAssertNotNil(viewModel.profileValidationError)
        XCTAssertFalse(viewModel.canSaveProfile)

        await viewModel.saveProfile()

        let updates = await service.receivedProfileUpdates
        XCTAssertTrue(updates.isEmpty)
    }

    func testARejectedSaveKeepsTheEdits() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.profileDraft.handle = AccountServiceMock.takenHandle
        await viewModel.saveProfile()

        XCTAssertEqual(viewModel.profileDraft.handle, AccountServiceMock.takenHandle)
        XCTAssertNotNil(viewModel.profileError)
        XCTAssertTrue(viewModel.hasProfileChanges)
    }

    func testDiscardingRestoresTheStoredProfile() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.profileDraft.displayName = "Someone else"
        viewModel.discardProfileChanges()

        XCTAssertFalse(viewModel.hasProfileChanges)
        XCTAssertEqual(viewModel.profileDraft.displayName, "Aziz Alwakeel")
    }

    // MARK: - Password

    func testThePasswordFormWillNotSubmitUntilItIsConsistent() {
        let (viewModel, _) = makeViewModel()

        viewModel.passwordCurrent = "old"
        viewModel.passwordNew = "short"
        viewModel.passwordRepeat = "short"
        XCTAssertFalse(viewModel.canChangePassword)
        XCTAssertNotNil(viewModel.passwordValidationError)

        viewModel.passwordNew = "long-enough"
        viewModel.passwordRepeat = "long-enougi"
        XCTAssertFalse(viewModel.canChangePassword)
        XCTAssertEqual(viewModel.passwordValidationError, "Those two don't match.")

        viewModel.passwordRepeat = "long-enough"
        XCTAssertTrue(viewModel.canChangePassword)
        XCTAssertNil(viewModel.passwordValidationError)

        viewModel.passwordCurrent = ""
        XCTAssertFalse(viewModel.canChangePassword, "the current password is never optional")
    }

    func testASuccessfulPasswordChangeWipesEveryFieldAndSaysThisDeviceIsIncluded() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.passwordCurrent = password
        viewModel.passwordNew = "a-brand-new-one"
        viewModel.passwordRepeat = "a-brand-new-one"
        await viewModel.changePassword()

        XCTAssertNotNil(viewModel.passwordChanged)
        XCTAssertEqual(viewModel.passwordCurrent, "")
        XCTAssertEqual(viewModel.passwordNew, "")
        XCTAssertEqual(viewModel.passwordRepeat, "")
        // The server revokes every refresh token, this device's included, so
        // "other sessions" would understate what just happened.
        XCTAssertTrue(viewModel.passwordChangeOutcome.contains("including this one"))
    }

    func testReusingTheSamePasswordIsRefusedByTheServerAndReported() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.passwordCurrent = password
        viewModel.passwordNew = password
        viewModel.passwordRepeat = password
        await viewModel.changePassword()

        XCTAssertNil(viewModel.passwordChanged)
        XCTAssertEqual(viewModel.passwordError, APIError.api(
            code: .passwordUnchanged, message: "", status: 400
        ).userMessage)
    }

    // MARK: - Email

    func testTheEmailChangeIsTwoStepsAndTheCodeGoesToTheNewAddress() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.emailPassword = password
        viewModel.emailNew = "New@Example.com"
        await viewModel.requestEmailChange()

        guard case let .awaitingCode(address) = viewModel.emailStage else {
            return XCTFail("did not advance to the code step")
        }
        XCTAssertEqual(address, "new@example.com")
        XCTAssertEqual(viewModel.account?.email, "aziz@example.com", "not changed until confirmed")
        XCTAssertEqual(viewModel.emailPassword, "", "the password does not outlive the request")

        viewModel.emailCode = AccountServiceMock.emailCode
        await viewModel.confirmEmailChange()

        XCTAssertEqual(viewModel.emailStage, .confirmed(address: "new@example.com"))
        XCTAssertEqual(viewModel.account?.email, "new@example.com")
    }

    func testAWrongCodeKeepsTheUserOnTheCodeStep() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.emailPassword = password
        viewModel.emailNew = "new@example.com"
        await viewModel.requestEmailChange()

        viewModel.emailCode = "000000"
        await viewModel.confirmEmailChange()

        XCTAssertEqual(viewModel.emailStage, .awaitingCode(sentTo: "new@example.com"))
        XCTAssertNotNil(viewModel.emailError)
        XCTAssertEqual(viewModel.account?.email, "aziz@example.com")
    }

    /// The address can be claimed while the code sits in an inbox, and the
    /// server re-checks at exactly that moment. The code is spent, so the form
    /// has to go back rather than leave a dead code on screen.
    func testAnAddressClaimedWhileTheCodeWasInTheInboxSendsTheFormBack() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.emailPassword = password
        viewModel.emailNew = AccountServiceMock.claimedDuringConfirmEmail
        await viewModel.requestEmailChange()
        XCTAssertEqual(
            viewModel.emailStage,
            .awaitingCode(sentTo: AccountServiceMock.claimedDuringConfirmEmail)
        )

        viewModel.emailCode = AccountServiceMock.emailCode
        await viewModel.confirmEmailChange()

        XCTAssertEqual(viewModel.emailStage, .entry)
        XCTAssertEqual(viewModel.account?.email, "aziz@example.com", "address unchanged")
        XCTAssertTrue(viewModel.emailError?.contains("claimed") == true)
        XCTAssertTrue(viewModel.emailError?.contains("unchanged") == true)
    }

    func testAnAddressAlreadyTakenIsRefusedBeforeAnyCodeIsSent() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.emailPassword = password
        viewModel.emailNew = AccountServiceMock.takenEmail
        await viewModel.requestEmailChange()

        XCTAssertEqual(viewModel.emailStage, .entry)
        XCTAssertNotNil(viewModel.emailError)
    }

    func testTheOwnAddressIsRefused() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.emailPassword = password
        viewModel.emailNew = "aziz@example.com"
        await viewModel.requestEmailChange()

        XCTAssertEqual(viewModel.emailStage, .entry)
        XCTAssertEqual(viewModel.emailError, APIError.api(
            code: .emailUnchanged, message: "", status: 400
        ).userMessage)
    }

    // MARK: - Export

    func testExportingWritesAFileTheShareSheetCanTake() async throws {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        await viewModel.exportAccount()

        let file = try XCTUnwrap(viewModel.exportFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(text.contains("exported_at"))
        XCTAssertTrue(text.contains("not included"), "the server's note about topic labels")

        viewModel.clearExport()
        XCTAssertNil(viewModel.exportFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Form hygiene

    /// Passwords typed into a form somebody backed out of have no reason to
    /// outlive the form.
    func testDismissingASheetForgetsWhatItCollected() {
        let (viewModel, _) = makeViewModel()

        viewModel.passwordCurrent = "secret"
        viewModel.emailPassword = "secret"
        viewModel.phonePassword = "secret"
        viewModel.deletion = DeletionConfirmation(currentPassword: "secret", typedWord: "DELETE")

        for sheet in [AccountSheet.password, .email, .phone, .delete] {
            viewModel.sheetDismissed(sheet)
        }

        XCTAssertEqual(viewModel.passwordCurrent, "")
        XCTAssertEqual(viewModel.emailPassword, "")
        XCTAssertEqual(viewModel.phonePassword, "")
        XCTAssertEqual(viewModel.deletion, DeletionConfirmation())
    }

    /// A code that has already been sent is still valid, so closing the sheet
    /// must not force a second one to be spent.
    func testDismissingTheEmailSheetKeepsAnAlreadySentCodeAlive() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.load()

        viewModel.emailPassword = password
        viewModel.emailNew = "new@example.com"
        await viewModel.requestEmailChange()

        viewModel.sheetDismissed(.email)

        XCTAssertEqual(viewModel.emailStage, .awaitingCode(sentTo: "new@example.com"))
    }

    // MARK: - Flags

    func testTheAccountSurfaceShipsOnByDefault() {
        let flags = FeatureFlags.resolved(arguments: ["Sila"])
        XCTAssertTrue(flags.account)
        XCTAssertFalse(flags.useMockAccount)
    }

    func testMockAccountArgumentsSelectAScenario() {
        XCTAssertTrue(FeatureFlags.resolved(arguments: ["Sila", "-mockAccount"]).useMockAccount)

        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockAccountScenario", "pendingDeletion"]
        )
        XCTAssertTrue(flags.useMockAccount)
        XCTAssertEqual(flags.mockAccountScenario, .pendingDeletion)
    }

    /// A mocked session carries no token the live API would accept, and the
    /// deletion demo is the one that must never run against a real account.
    func testMockingAuthImpliesMockingTheAccount() {
        XCTAssertTrue(FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"]).useMockAccount)
    }
}

// MARK: - Test seam

extension AccountViewModel {
    /// Forces the route, so a test can prove the **403** produced it rather than
    /// the load that came before.
    func forceRouteForTesting(_ route: AccountRoute) {
        self.route = route
    }
}
