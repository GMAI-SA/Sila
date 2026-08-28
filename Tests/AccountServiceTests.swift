import XCTest
@testable import Sila

/// ``AccountService`` against a scripted transport: paths, verbs, bodies, and
/// the one request in the app that is not JSON.
final class AccountServiceTests: XCTestCase {

    private func makeService(
        _ network: StubNetworkClient,
        token: String? = "access-123"
    ) -> AccountService {
        AccountService(
            network: network,
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
    }

    private static let account = """
    {"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "email": "aziz@example.com", "handle": "aziz"}
    """

    private func body(_ request: APIRequest?) -> String {
        String(decoding: request?.body ?? Data(), as: UTF8.self)
    }

    // MARK: - Paths and verbs

    func testEveryEndpointUsesTheDocumentedPathAndVerb() async throws {
        let network = StubNetworkClient(responses: [
            Self.account,                                     // fetchAccount
            "{}", Self.account,                               // updateProfile: PATCH then GET
            Self.account,                                     // uploadAvatar
            Self.account,                                     // removeAvatar
            #"{"changed": true, "other_sessions_signed_out": true}"#,
            #"{"sent": true, "to": "new@example.com"}"#,
            Self.account,                                     // confirmEmailChange
            Self.account,                                     // setPhone
            "{}",                                             // export
            #"{"deactivated": true, "grace_days": 30}"#,
            Self.account                                      // cancelDeletion
        ])
        let service = makeService(network)

        _ = try await service.fetchAccount()
        _ = try await service.updateProfile(ProfileUpdate(displayName: "Aziz"))
        _ = try await service.uploadAvatar(AvatarImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        _ = try await service.removeAvatar()
        _ = try await service.changePassword(currentPassword: "a", newPassword: "bbbbbbbb")
        _ = try await service.requestEmailChange(currentPassword: "a", newEmail: "new@example.com")
        _ = try await service.confirmEmailChange(newEmail: "new@example.com", code: "123456")
        _ = try await service.setPhone(currentPassword: "a", phone: "+966501234567")
        _ = try await service.exportData()
        _ = try await service.requestDeletion(
            DeletionConfirmation(currentPassword: "a", typedWord: "DELETE")
        )
        _ = try await service.cancelDeletion()

        let seen = network.requests.map { "\($0.method.rawValue) \($0.path)" }
        XCTAssertEqual(seen, [
            "GET /me/account",
            "PATCH /me/profile",
            "GET /me/account",
            "PUT /me/avatar",
            "DELETE /me/avatar",
            "POST /me/password",
            "POST /me/email/request",
            "POST /me/email/confirm",
            "PUT /me/phone",
            "GET /me/export",
            "POST /me/delete",
            "POST /me/delete/cancel"
        ])
        XCTAssertTrue(network.requests.allSatisfy { $0.accessToken == "access-123" })
    }

    /// `PATCH /me/profile` answers a post-author summary with no `bio`, `email`
    /// or `phone` in it. Folding that into the local copy would let the screen
    /// show fields nobody confirmed, so the write is followed by a read.
    func testProfileSaveReReadsTheAccountBecausePatchAnswersTheWrongShape() async throws {
        let network = StubNetworkClient(responses: [
            #"{"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "handle": "aziz", "is_verified": true}"#,
            #"{"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "email": "aziz@example.com", "bio": "Fresh"}"#
        ])

        let account = try await makeService(network).updateProfile(ProfileUpdate(bio: "Fresh"))

        XCTAssertEqual(network.requests.count, 2)
        XCTAssertEqual(network.requests.first?.method, .patch)
        XCTAssertEqual(network.requests.last?.method, .get)
        XCTAssertEqual(account.bio, "Fresh")
        XCTAssertEqual(account.email, "aziz@example.com")
    }

    func testAnEmptyProfileUpdateNeverPatches() async throws {
        let network = StubNetworkClient(responses: [Self.account])

        _ = try await makeService(network).updateProfile(ProfileUpdate())

        XCTAssertEqual(network.requests.map(\.method), [.get])
    }

    // MARK: - Bodies

    func testCredentialBodiesCarryTheCurrentPassword() async throws {
        let network = StubNetworkClient(responses: [
            #"{"changed": true}"#,
            #"{"sent": true, "to": "n@e.com"}"#,
            Self.account,
            #"{"deactivated": true}"#
        ])
        let service = makeService(network)

        _ = try await service.changePassword(currentPassword: "old-pw", newPassword: "new-pw-12")
        _ = try await service.requestEmailChange(currentPassword: "old-pw", newEmail: "n@e.com")
        _ = try await service.setPhone(currentPassword: "old-pw", phone: "+966501234567")
        _ = try await service.requestDeletion(
            DeletionConfirmation(currentPassword: "old-pw", typedWord: "DELETE")
        )

        for request in network.requests {
            XCTAssertTrue(
                body(request).contains("\"current_password\":\"old-pw\""),
                "\(request.path) went out without the current password"
            )
        }
    }

    func testPhoneClearingSendsAnExplicitNullOverTheWire() async throws {
        let network = StubNetworkClient(responses: [Self.account])

        _ = try await makeService(network).setPhone(currentPassword: "pw", phone: nil)

        XCTAssertTrue(body(network.lastRequest).contains("\"phone\":null"), body(network.lastRequest))
    }

    func testEmailConfirmationSendsTheNewAddressAndTheCode() async throws {
        let network = StubNetworkClient(responses: [Self.account])

        _ = try await makeService(network).confirmEmailChange(
            newEmail: "new@example.com",
            code: "123456"
        )

        let sent = body(network.lastRequest)
        XCTAssertTrue(sent.contains("\"new_email\":\"new@example.com\""), sent)
        XCTAssertTrue(sent.contains("\"code\":\"123456\""), sent)
        XCTAssertFalse(sent.contains("current_password"), "the code is the proof at this step")
    }

    // MARK: - The multipart upload

    /// The one request in the app that is not JSON, asserted byte for byte.
    func testAvatarUploadBuildsAConformingMultipartBody() {
        let pixels = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        let image = AvatarImage(data: pixels)

        let form = AvatarUpload.form(for: image, boundary: "TestBoundary123")
        let encoded = form.encoded()
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=TestBoundary123")
        XCTAssertTrue(text.hasPrefix("--TestBoundary123\r\n"), text)
        XCTAssertTrue(
            text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n"),
            text
        )
        XCTAssertTrue(text.contains("Content-Type: image/jpeg\r\n\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n--TestBoundary123--\r\n"), text)
        // The bytes are copied in verbatim — nothing re-encodes them client-side.
        XCTAssertTrue(encoded.range(of: pixels) != nil)
    }

    /// The field name is the contract. `file` is what `UploadFile = File(...)`
    /// binds to; anything else is a 422 the user cannot act on.
    func testAvatarPartIsNamedFile() {
        let text = String(
            decoding: AvatarUpload.form(
                for: AvatarImage(data: Data([0x89, 0x50, 0x4E, 0x47])),
                boundary: "B"
            ).encoded(),
            as: UTF8.self
        )

        XCTAssertTrue(text.contains("name=\"file\""))
        XCTAssertEqual(AvatarUpload.fieldName, "file")
    }

    func testAvatarRequestCarriesTheBoundaryInItsContentTypeHeader() async throws {
        let network = StubNetworkClient(responses: [Self.account])

        _ = try await makeService(network).uploadAvatar(
            AvatarImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        )

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.path, "/me/avatar")
        let contentType = try XCTUnwrap(request.contentType)
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        // A multipart body is unparseable without the boundary in the header,
        // and the body must actually use the one that was advertised.
        let boundary = String(contentType.split(separator: "=").last ?? "")
        XCTAssertTrue(
            String(decoding: request.body ?? Data(), as: UTF8.self).contains("--\(boundary)"),
            "the header advertised a boundary the body does not use"
        )
    }

    func testEachUploadGetsAFreshBoundary() {
        let first = MultipartFormData().boundary
        let second = MultipartFormData().boundary
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Format sniffing

    /// The declared `Content-Type` is derived from the bytes, not from what the
    /// picker or a filename claims — those are things somebody made up.
    func testFormatIsSniffedFromTheBytes() {
        let cases: [(Data, AvatarUpload.Format, String)] = [
            (Data([0xFF, 0xD8, 0xFF, 0xE0]), .jpeg, "image/jpeg"),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .png, "image/png"),
            (Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), .gif, "image/gif"),
            (Data("RIFF????WEBPVP8 ".utf8), .webp, "image/webp"),
            (Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8), .heic, "image/heic"),
            (Data("not an image at all".utf8), .unknown, "application/octet-stream")
        ]

        for (bytes, expected, mime) in cases {
            XCTAssertEqual(AvatarUpload.sniffFormat(bytes), expected)
            XCTAssertEqual(AvatarImage(data: bytes).mimeType, mime)
        }
    }

    func testUnknownBytesAreNotPassedOffAsAJPEG() {
        let image = AvatarImage(data: Data("definitely a PDF".utf8))

        XCTAssertEqual(image.mimeType, "application/octet-stream")
        XCTAssertEqual(image.filename, "avatar.bin")
    }

    // MARK: - Client-side size limit

    /// Refusing here rather than after a 413 is the difference between a message
    /// and a minute of somebody's data allowance spent earning one.
    func testOversizedImagesAreRefusedBeforeAnyRequest() {
        let big = Data(repeating: 0xFF, count: AvatarUpload.maximumBytes + 1)

        guard case let .tooLarge(bytes) = AvatarUpload.rejection(for: big) else {
            return XCTFail("a 5 MB + 1 byte image was not refused")
        }
        XCTAssertEqual(bytes, AvatarUpload.maximumBytes + 1)
        XCTAssertTrue(AvatarRejection.tooLarge(bytes: bytes).message.contains("5 MB"))
        XCTAssertTrue(AvatarRejection.tooLarge(bytes: bytes).message.contains("5.0 MB"))
    }

    func testAnImageExactlyOnTheLimitIsAccepted() {
        XCTAssertNil(AvatarUpload.rejection(for: Data(repeating: 0xFF, count: AvatarUpload.maximumBytes)))
    }

    func testAnEmptyPickIsRefusedWithItsOwnMessage() {
        XCTAssertEqual(AvatarUpload.rejection(for: Data()), .empty)
        XCTAssertTrue(AvatarRejection.empty.message.contains("couldn't be read"))
    }

    // MARK: - Export

    /// The export is returned untouched. Decoding and re-encoding it would hand
    /// somebody a document this app invented instead of the one the server sent.
    func testExportReturnsTheServerBodyVerbatim() async throws {
        let payload = #"{"exported_at": "2026-08-28T09:15:00+00:00", "note": "…"}"#
        let network = StubNetworkClient(responses: [payload])

        let data = try await makeService(network).exportData()

        XCTAssertEqual(String(decoding: data, as: UTF8.self), payload)
        XCTAssertEqual(network.lastRequest?.path, "/me/export")
        XCTAssertEqual(network.lastRequest?.method, .get)
    }

    // MARK: - Errors

    func testAServerErrorSurfacesItsCode() async {
        let network = StubNetworkClient(
            error: .api(code: .imageTooLarge, message: "Images must be under 5MB", status: 413)
        )

        do {
            _ = try await makeService(network).uploadAvatar(
                AvatarImage(data: Data([0xFF, 0xD8, 0xFF]))
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, .imageTooLarge)
        }
    }

    func testNoSessionMeansNoRequestAtAll() async {
        let network = StubNetworkClient(responses: [Self.account])

        do {
            _ = try await makeService(network, token: nil).fetchAccount()
            XCTFail("expected an unauthenticated failure")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthenticated)
            XCTAssertTrue(network.requests.isEmpty)
        }
    }
}
