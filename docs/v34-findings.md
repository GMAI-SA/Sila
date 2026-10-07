# Skeptic findings for the ios lane of v34

## 1. [medium] /Users/abdulazizalwakeel/social-sa-ios/Sila/Modules/Account/Presentation/AccountScreen.swift

Line 5 of the consent card tells the person they can withdraw in 'Settings › Privacy › Verification photos' (Arabic: الإعدادات › الخصوصية › صور التحقق). iOS has no screen with that name. The row was added as a 'Privacy' section inside the Account sheet, whose title is account.nav.title 'Account' / 'الحساب', and that sheet opens from 'Edit profile' and the profile's owner routes. No string in Localizable.xcstrings says 'Settings'. So the withdrawal path written in the consent text does not match what the person sees, and that text is what makes the consent withdrawable (§7.2, §7.8).

Suggested fix: Either make the route the person follows actually read Settings › Privacy (rename or alias the entry and sheet title), or get the contract owner to approve platform wording for line 5 that names the real iOS path, in both languages. Add a UI check that the label on the card matches the route.

## 2. [medium] /Users/abdulazizalwakeel/social-sa-ios/Sila/Modules/Verification/Presentation/DocumentVerificationScreen.swift

§7.2 requires every line of the card to be visible without scrolling on a phone at the default text size, beside Send. The new sendStep puts an extra displayM title 'Ready to send' and a body message above the card (title, five caption lines, checkbox, link), with Send below it, all inside the flow's ScrollView. On an iPhone SE-class screen, and probably near the limit on an iPhone 15, Send and the lower lines will fall below the fold. Nothing checks this: the UI journey only uses exists/isEnabled, never isHittable or a frame inside the window.

Suggested fix: Remove or shrink the 'Ready to send' title and message when the card is shown, or tighten the spacing. Add a UI assertion on the smallest supported simulator that the title, line 5, the checkbox and Send all have frames inside app.windows.firstMatch.frame without scrolling.

## 3. [low] /Users/abdulazizalwakeel/social-sa-ios/Sila/Modules/Verification/Presentation/DocumentVerificationViewModel.swift

retrySend() (the 'Try again' after a network failure) calls submit() directly. It skips the fresh GET /verification/status that §7.1 asks for 'just before submitting', and still carries the tick and version from before. If the switch changed in the meantime, the server's 409/400 catches it and the handler goes back to the card. So the promise still holds, but at the cost of a refused round trip and an error notice instead of reading the offer first as send() does.

Suggested fix: Send retrySend through the same offer re-read as send(): re-read the status, compare it with the version shown, and redraw the card unticked if it changed. Add a test for it.

## 4. [low] /Users/abdulazizalwakeel/social-sa-ios/Sila/Modules/Auth/Domain/AuthModels.swift

The new status key retention_consent_required is not in the contract, and when true it disables Send until the box is ticked (canSend). §7.2 says outright 'Send is always enabled' and 'The tick is optional (Deviation 3)'. The client now carries a path that contradicts the contract, and it depends on a key name the backend has not agreed.

Suggested fix: Remove the consentRequired gate until the contract adds the key. Otherwise get the backend lane and the contract to name and document it before merge, so the 'Send never blocked' guarantee holds unless the owner changes it explicitly.

## 5. [low] /Users/abdulazizalwakeel/social-sa-ios/Tests/VerificationFilesConsentTests.swift

The tests check less than §11 asks. (1) 'The copy variants follow retention': testTheOldWordingStaysAndTheNewOneSaysKept only checks that the strings exist. Nothing tests that RejectedScreen.explanation picks .kept from the latest case's retention and images_kept, or that the old copy stays for an unticked or withdrawn case at screen level. (2) The UI journeys run against VerificationServiceMock launch arguments, not 'canned specimen images against a local dev server (or staging)' as §11 requires, so the real multipart parts and the server's consent refusals are never exercised end to end. (3) No UI journey covers the Verification photos row. (4) The test 'tick cleared by a retake' passes whatever retakeFront does, because proceedAfterLiveness clears the tick anyway, and the claimed resets on an invalid MRZ and a liveness redo are untested.

Suggested fix: Pull the rejected-screen variant choice into a testable function and test it with with_account/true, with_account/false and until_decision. Add one journey against the local dev server using specimen images. Add a UI journey for the photos row. Test the tick resets on the invalidMrz and livenessMismatch refusals directly.

## 6. [low] /Users/abdulazizalwakeel/social-sa-ios/Sila/Resources/Localizable.xcstrings

document.consent.line3 ships the 'Canada / transfer stated' wording while gate G3 is open. The lane disclosed this. §7.2 says only the line 3 that G3 settles may ship, so this is a release blocker that has to be tracked, not a code defect today.

Suggested fix: Track it as a pre-release gate: settle G3 and swap the en/ar values if the model moves to the Kingdom before submitting to the App Store.
