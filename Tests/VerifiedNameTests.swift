import XCTest
@testable import Sila

/// The verified name: read from the identity check, hideable, never edited.
final class VerifiedNameTests: XCTestCase {

    func testAPersonCarriesTheConfirmedNameWhenTheServerSendsOne() throws {
        let json = """
        {"id": "22222222-0000-4000-8000-000000000002", "handle": "aziz", "display_name": "Aziz",
         "is_verified": true, "verified_name": "Abdulaziz Alwakeel"}
        """
        let person = try JSONCoding.decoder.decode(UserSummary.self, from: Data(json.utf8))
        XCTAssertEqual(person.verifiedName, "Abdulaziz Alwakeel")
        XCTAssertEqual(person.displayName, "Aziz")
    }

    func testAHiddenOrAbsentNameReadsAsNone() throws {
        let hidden = """
        {"id": "22222222-0000-4000-8000-000000000002", "handle": "aziz", "display_name": "Aziz",
         "is_verified": true, "verified_name": null}
        """
        XCTAssertNil(try JSONCoding.decoder.decode(UserSummary.self, from: Data(hidden.utf8)).verifiedName)
        let empty = """
        {"id": "22222222-0000-4000-8000-000000000002", "handle": "aziz", "is_verified": true, "verified_name": ""}
        """
        XCTAssertNil(try JSONCoding.decoder.decode(UserSummary.self, from: Data(empty.utf8)).verifiedName)
    }

    func testTheOwnerSeesTheirOwnNameAndWhetherItIsHidden() throws {
        let json = """
        {"id": "22222222-0000-4000-8000-000000000002", "email": "a@example.com", "handle": "aziz",
         "email_verified": true, "verification_status": "verified", "created_at": "2026-09-09T08:00:00Z",
         "verified_name": "Abdulaziz Alwakeel", "hide_verified_name": true}
        """
        let me = try JSONCoding.decoder.decode(AuthUser.self, from: Data(json.utf8))
        XCTAssertEqual(me.verifiedName, "Abdulaziz Alwakeel")
        XCTAssertTrue(me.hideVerifiedName)
        let account = try JSONCoding.decoder.decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(account.verifiedName, "Abdulaziz Alwakeel")
        XCTAssertTrue(account.hideVerifiedName)
    }

    func testTheEditorSendsOnlyTheHideSwitchAndNeverTheName() throws {
        let stored = Account(
            id: UUID(), email: "a@example.com", handle: "aziz", displayName: "Aziz",
            verifiedName: "Abdulaziz Alwakeel", hideVerifiedName: false
        )
        var draft = ProfileDraft(account: stored)
        XCTAssertTrue(ProfileUpdate.difference(from: stored, to: draft).isEmpty)

        draft.hideVerifiedName = true
        let update = ProfileUpdate.difference(from: stored, to: draft)
        XCTAssertEqual(update.hideVerifiedName, true)
        XCTAssertNil(update.displayName)

        let body = try JSONCoding.encoder.encode(update)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["hide_verified_name"] as? Bool, true)
        XCTAssertNil(json["verified_name"])
    }
}
