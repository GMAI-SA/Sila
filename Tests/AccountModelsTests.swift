import XCTest
@testable import Sila

/// Contract v5's wire shapes, and the rules the client mirrors from the server.
///
/// These are the tests that would notice the backend changing shape under the
/// account screen — which matters more here than on a feed, because a field
/// that quietly stops decoding on this surface is somebody's phone number or
/// their deletion deadline.
final class AccountModelsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - GET /me/account

    private static let fullAccount = """
    {
      "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
      "email": "aziz@example.com",
      "handle": "aziz_sa",
      "display_name": "Aziz Alwakeel",
      "bio": "Building things in Riyadh.",
      "avatar_url": "/api/v1/media/avatars/6c1b1f7e-1a2b3c4d.jpg",
      "phone": "+966501234567",
      "phone_verified": false,
      "country_code": "SA",
      "verification_status": "verified",
      "deletion_requested_at": null,
      "purge_after": null
    }
    """

    func testAccountDecodesTheDocumentedPayload() throws {
        let account = try decode(Account.self, from: Self.fullAccount)

        XCTAssertEqual(account.email, "aziz@example.com")
        XCTAssertEqual(account.handle, "aziz_sa")
        XCTAssertEqual(account.atHandle, "@aziz_sa")
        XCTAssertEqual(account.displayName, "Aziz Alwakeel")
        XCTAssertEqual(account.bio, "Building things in Riyadh.")
        XCTAssertEqual(account.phone, "+966501234567")
        XCTAssertEqual(account.countryCode, "SA")
        XCTAssertEqual(account.verificationStatus, .verified)
        XCTAssertFalse(account.isPendingDeletion)
        XCTAssertEqual(account.initials, "AA")
    }

    /// The server sends a **root-relative** avatar path. Decoded straight into a
    /// `URL` it is unloadable, so the model keeps the string and resolves it.
    func testAvatarPathIsResolvedIntoAnAbsoluteURL() throws {
        let account = try decode(Account.self, from: Self.fullAccount)

        XCTAssertEqual(account.avatarPath, "/api/v1/media/avatars/6c1b1f7e-1a2b3c4d.jpg")
        XCTAssertEqual(
            account.avatarURL?.absoluteString,
            "https://sila.gmai.sa/api/v1/media/avatars/6c1b1f7e-1a2b3c4d.jpg"
        )
    }

    func testAnAbsoluteAvatarURLIsLeftAlone() {
        XCTAssertEqual(
            AppConfig.mediaURL("https://cdn.example.com/a.jpg")?.absoluteString,
            "https://cdn.example.com/a.jpg"
        )
        XCTAssertNil(AppConfig.mediaURL(nil))
        XCTAssertNil(AppConfig.mediaURL(""))
    }

    /// **The phone must never be able to render as verified.**
    ///
    /// The strongest available guarantee is structural: the model does not carry
    /// the flag at all, so no view can bind a checkmark to it by accident. This
    /// test fails the moment somebody adds the property back.
    func testAccountCarriesNoPhoneVerifiedFlagAtAll() throws {
        let account = try decode(Account.self, from: Self.fullAccount)
        let properties = Mirror(reflecting: account).children.compactMap(\.label)

        XCTAssertFalse(properties.contains("phoneVerified"))
        XCTAssertFalse(properties.contains("isPhoneVerified"))
        XCTAssertEqual(
            properties.filter { $0.lowercased().contains("verif") },
            ["verificationStatus"],
            "the only verification on this model is identity verification"
        )
    }

    /// Even if the server started claiming a verified number, this build would
    /// not repeat the claim.
    func testAServerClaimingAVerifiedPhoneChangesNothing() throws {
        let json = Self.fullAccount.replacingOccurrences(
            of: "\"phone_verified\": false",
            with: "\"phone_verified\": true"
        )
        let account = try decode(Account.self, from: json)

        XCTAssertEqual(account.phone, "+966501234567")
        XCTAssertTrue(
            PhoneNumber.unverifiedCaption.contains("has not checked"),
            "the caption is a constant, never derived from the wire"
        )
    }

    func testAMissingFieldDoesNotFailTheWholeDecode() throws {
        let account = try decode(Account.self, from: #"{"email": "a@b.com"}"#)

        XCTAssertEqual(account.email, "a@b.com")
        XCTAssertNil(account.handle)
        XCTAssertNil(account.phone)
        XCTAssertNil(account.avatarURL)
        XCTAssertEqual(account.verificationStatus, .unstarted)
    }

    func testEmptyStringsDecodeAsAbsentRatherThanBlank() throws {
        let account = try decode(
            Account.self,
            from: #"{"email": "a@b.com", "handle": "", "bio": "", "avatar_url": ""}"#
        )

        XCTAssertNil(account.handle)
        XCTAssertNil(account.bio)
        XCTAssertNil(account.avatarURL)
    }

    // MARK: - Deletion timestamps

    func testPendingDeletionIsReadFromEitherTimestamp() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "email": "leaving@example.com",
          "deletion_requested_at": "2026-08-28T09:15:00.123456+00:00",
          "purge_after": "2026-09-27T09:15:00.123456+00:00"
        }
        """
        let account = try decode(Account.self, from: json)

        XCTAssertTrue(account.isPendingDeletion)
        XCTAssertNotNil(account.deletionRequestedAt)
        XCTAssertNotNil(account.purgeAfter)
    }

    /// Python's `isoformat()` emits six fractional digits and a `+00:00` offset.
    /// Both are handled, and so is the version with no fraction at all.
    func testPythonISOFormatTimestampsDecode() throws {
        for stamp in [
            "2026-09-27T09:15:00.123456+00:00",
            "2026-09-27T09:15:00+00:00",
            "2026-09-27T09:15:00Z"
        ] {
            let account = try decode(
                Account.self,
                from: #"{"email": "a@b.com", "purge_after": "\#(stamp)"}"#
            )
            XCTAssertNotNil(account.purgeAfter, "\(stamp) did not decode")
        }
    }

    func testDaysUntilPurgeFloorsAndNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func account(daysAway: Double) -> Account {
            Account(
                id: UUID(),
                email: "a@b.com",
                purgeAfter: now.addingTimeInterval(daysAway * 86_400)
            )
        }

        XCTAssertEqual(account(daysAway: 30).daysUntilPurge(now: now), 30)
        XCTAssertEqual(account(daysAway: 29.9).daysUntilPurge(now: now), 29)
        XCTAssertEqual(account(daysAway: 0.4).daysUntilPurge(now: now), 0)
        XCTAssertEqual(account(daysAway: -5).daysUntilPurge(now: now), 0)
        XCTAssertNil(Account(id: UUID(), email: "a@b.com").daysUntilPurge(now: now))
    }

    // MARK: - POST /me/delete response

    func testDeletionScheduleDecodesTheDocumentedPayload() throws {
        let json = """
        {
          "deactivated": true,
          "purge_after": "2026-09-27T09:15:00+00:00",
          "grace_days": 30,
          "reversible_until_purge": true,
          "what_is_kept": "Nothing is retained after the purge date at present."
        }
        """
        let schedule = try decode(DeletionSchedule.self, from: json)

        XCTAssertTrue(schedule.deactivated)
        XCTAssertTrue(schedule.reversibleUntilPurge)
        XCTAssertEqual(schedule.graceDays, 30)
        XCTAssertNotNil(schedule.purgeAfter)
        XCTAssertEqual(schedule.graceDays, DeletionDisclosure.graceDays)
    }

    func testPasswordChangeResultDecodes() throws {
        let result = try decode(
            PasswordChangeResult.self,
            from: #"{"changed": true, "other_sessions_signed_out": true}"#
        )
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.otherSessionsSignedOut)
    }

    func testEmailChangeSentReportsTheNewAddress() throws {
        let sent = try decode(EmailChangeSent.self, from: #"{"sent": true, "to": "new@example.com"}"#)
        XCTAssertEqual(sent.to, "new@example.com")
    }

    // MARK: - Request bodies

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
    }

    func testProfileUpdateSendsOnlyTheFieldsThatChanged() throws {
        let stored = Account(
            id: UUID(),
            email: "a@b.com",
            handle: "aziz",
            displayName: "Aziz",
            bio: "Old bio"
        )
        let draft = ProfileDraft(displayName: "Aziz", handle: "aziz", bio: "New bio")

        let update = ProfileUpdate.difference(from: stored, to: draft.normalised)

        XCTAssertNil(update.displayName)
        XCTAssertNil(update.handle)
        XCTAssertEqual(update.bio, "New bio")
        let json = try encoded(update)
        XCTAssertTrue(json.contains("\"bio\""))
        XCTAssertFalse(json.contains("display_name"))
        XCTAssertFalse(json.contains("\"handle\""))
    }

    /// Clearing a field must be sent as `""`, not omitted — omitting it means
    /// "leave it alone", which would silently keep the text the user deleted.
    func testClearingAFieldIsSentAsAnEmptyStringNotOmitted() throws {
        let stored = Account(id: UUID(), email: "a@b.com", bio: "Old bio")
        let draft = ProfileDraft(displayName: "", handle: "", bio: "")

        let update = ProfileUpdate.difference(from: stored, to: draft.normalised)

        XCTAssertEqual(update.bio, "")
        XCTAssertNil(update.displayName, "was already empty, so nothing changed")
        XCTAssertTrue(try encoded(update).contains("\"bio\":\"\""))
    }

    func testAnUnchangedDraftProducesAnEmptyUpdate() {
        let stored = Account(id: UUID(), email: "a@b.com", handle: "aziz", displayName: "Aziz")
        let draft = ProfileDraft(account: stored)

        XCTAssertTrue(ProfileUpdate.difference(from: stored, to: draft.normalised).isEmpty)
    }

    /// `phone: null` is how the number is cleared, so it must survive encoding.
    /// The synthesised encoder drops `nil`s, which would turn "remove it" into
    /// a no-op the screen would then report as a success.
    func testClearingThePhoneSendsAnExplicitNull() throws {
        let json = try encoded(PhoneUpdate(currentPassword: "pw", phone: nil))

        XCTAssertTrue(json.contains("\"phone\":null"), json)
        XCTAssertTrue(json.contains("\"current_password\":\"pw\""), json)
    }

    func testSettingThePhoneSendsTheNumber() throws {
        let json = try encoded(PhoneUpdate(currentPassword: "pw", phone: "+966501234567"))
        XCTAssertTrue(json.contains("\"phone\":\"+966501234567\""), json)
    }

    func testDeletionRequestCarriesTheLiteralConfirmationWord() throws {
        let confirmation = DeletionConfirmation(currentPassword: "pw", typedWord: "DELETE")
        let json = try encoded(confirmation.request)

        XCTAssertTrue(json.contains("\"confirm\":\"DELETE\""), json)
        XCTAssertTrue(json.contains("\"current_password\":\"pw\""), json)
    }

    // MARK: - Handles

    func testHandleRuleMirrorsTheServerRegex() {
        for good in ["aziz", "aziz_sa", "a_1", "abc", String(repeating: "a", count: 20)] {
            XCTAssertTrue(Handle.isValid(good), "\(good) should be accepted")
        }
        for bad in ["ab", String(repeating: "a", count: 21), "Aziz", "aziz-sa", "aziz sa", "عزيز", ""] {
            XCTAssertFalse(Handle.isValid(bad), "\(bad) should be refused")
        }
    }

    func testProfileDraftRefusesOverlongFieldsBeforeARoundTrip() {
        var draft = ProfileDraft(displayName: String(repeating: "a", count: 81))
        XCTAssertNotNil(draft.validationError)

        draft = ProfileDraft(bio: String(repeating: "b", count: 161))
        XCTAssertNotNil(draft.validationError)

        // The draft lowercases before validating, so typing capitals is not an
        // error — the server would only ever see `nocaps`.
        draft = ProfileDraft(handle: "NoCaps")
        XCTAssertNil(draft.validationError)

        draft = ProfileDraft(handle: "no")
        XCTAssertNotNil(draft.validationError, "too short even after lowercasing")

        draft = ProfileDraft(handle: "no-dashes-here")
        XCTAssertNotNil(draft.validationError, "dashes are not in the server's character set")

        draft = ProfileDraft(displayName: "Aziz", handle: "aziz_sa", bio: "Hello")
        XCTAssertNil(draft.validationError)
    }

    func testDraftNormalisationTrimsAndLowercasesTheHandle() {
        let draft = ProfileDraft(displayName: "  Aziz  ", handle: " AZIZ_SA ", bio: " Hi ")
        XCTAssertEqual(draft.normalised, ProfileDraft(displayName: "Aziz", handle: "aziz_sa", bio: "Hi"))
    }

    // MARK: - The disclosures

    /// The four consequences the deletion screen is obliged to state.
    /// Asserted here rather than only rendered, because this wording is the
    /// difference between consent and a button somebody pressed.
    func testDeletionDisclosureStatesAllFourConsequences() {
        let all = DeletionDisclosure.consequences.joined(separator: " ").lowercased()

        XCTAssertEqual(DeletionDisclosure.consequences.count, 4)
        XCTAssertTrue(all.contains("deactivated the moment"), "immediate deactivation")
        XCTAssertTrue(all.contains("signed out"), "sessions revoked")
        XCTAssertTrue(all.contains("every feed"), "posts leave the feeds")
        XCTAssertTrue(all.contains("30 days"), "the grace period, in days")
        XCTAssertEqual(DeletionDisclosure.graceDays, 30)
    }

    func testDeletionDisclosureSaysWhatIsPermanentToo() {
        XCTAssertTrue(DeletionDisclosure.permanent.contains("deleted, not"))
        XCTAssertTrue(DeletionDisclosure.permanent.lowercased().contains("cannot be undone"))
    }

    /// The picture disclosure has to mention the two things the re-encode does
    /// that a user would not expect from "set a photo".
    func testAvatarDisclosureNamesTheReEncodeAndTheStrippedLocation() {
        let text = AvatarUpload.processingDisclosure.lowercased()

        XCTAssertTrue(text.contains("re-encode"))
        XCTAssertTrue(text.contains("location data"))
        XCTAssertTrue(text.contains("exif"))
    }

    /// The phone caption must say the number is *not* checked, and must never
    /// use the vocabulary reserved for identity verification.
    func testPhoneCaptionRefusesToImplyVerification() {
        let text = PhoneNumber.unverifiedCaption

        XCTAssertTrue(text.contains("Contact detail only"))
        XCTAssertTrue(text.contains("has not checked"))
        XCTAssertTrue(text.contains("not part of your verified identity"))
        XCTAssertFalse(text.contains("✓"))
        XCTAssertFalse(text.lowercased().contains("confirmed"))
    }
}
