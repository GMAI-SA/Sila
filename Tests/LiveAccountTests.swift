import XCTest
import UIKit
@testable import Sila

/// Drives the deployed account API through the app's own service.
///
/// The fixture tests agree with the contract by construction, so they would
/// stay green if the server drifted. These are the ones that would notice.
///
/// **Deliberately non-destructive.** The live account is a real one, so this
/// suite never changes a password (which revokes every session), never
/// requests a real email change (which sends mail to a real inbox), and never
/// completes a deletion. The destructive paths are covered by the backend's
/// own suite, where the accounts are disposable. What is exercised here is
/// everything that can be undone — and the *refusals*, which are safe to
/// provoke precisely because they fail.
///
/// Anything it does change is put back in `tearDown`.
///
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LiveAccountTests: XCTestCase {

    private var token: String?
    private var password = ""
    private var originalPhone: String?
    private var hadAvatarAtStart = false

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"], let pw = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        password = pw
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        token = try await auth.signIn(email: email, password: pw).token.accessToken

        let account = try await service().fetchAccount()
        originalPhone = account.phone
        hadAvatarAtStart = account.avatarPath != nil
    }

    override func tearDown() async throws {
        guard let token, !token.isEmpty else { return }
        let service = AccountService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
        // Put the account back exactly as it was found.
        if let account = try? await service.fetchAccount() {
            if account.phone != originalPhone {
                _ = try? await service.setPhone(currentPassword: password, phone: originalPhone)
            }
            if account.avatarPath != nil && !hadAvatarAtStart {
                _ = try? await service.removeAvatar()
            }
        }
    }

    private func service() throws -> AccountService {
        AccountService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    // MARK: - Reading

    func testTheAccountDecodes() async throws {
        let account = try await service().fetchAccount()
        XCTAssertFalse(account.email.isEmpty, "an account with no email would break the header")
        XCTAssertNotNil(account.handle)
        XCTAssertFalse(account.isPendingDeletion, "this account should not be scheduled for deletion")
    }

    // MARK: - Avatars

    /// The only end-to-end exercise of the multipart seam, and of the claim
    /// that a stored avatar is actually fetchable — the bug that made every
    /// avatar silently blank was a URL that decoded fine and never loaded.
    func testAvatarUploadsAndIsThenFetchable() async throws {
        let service = try service()
        let account = try await service.uploadAvatar(
            AvatarImage(data: Self.jpegBytes(), filename: "t.jpg", mimeType: "image/jpeg")
        )

        let path = try XCTUnwrap(account.avatarPath, "server accepted the upload but stored no path")
        XCTAssertTrue(path.hasPrefix("/"), "expected a root-relative path; the resolver depends on it")

        let url = try XCTUnwrap(account.avatarURL)
        XCTAssertNotNil(url.host, "a hostless URL is what AsyncImage cannot load")

        // Unauthenticated on purpose: avatars sit beside posts in a feed that
        // is public to read, so fetch it with no token at all.
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(data.isEmpty)

        // Re-encoded server-side, so it comes back as JPEG regardless of input.
        XCTAssertEqual([UInt8](data.prefix(2)), [0xFF, 0xD8], "expected a JPEG")

        let cleared = try await service.removeAvatar()
        XCTAssertNil(cleared.avatarPath)
    }

    func testAnUploadThatIsNotAnImageIsRefused() async throws {
        do {
            _ = try await service().uploadAvatar(
                AvatarImage(data: Data("not an image".utf8), filename: "x.jpg", mimeType: "image/jpeg")
            )
            XCTFail("server stored a file it could not decode")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidImage,
                           "a declared MIME type is not evidence; only decoding is")
        }
    }

    // MARK: - Phone

    func testPhoneRoundTripsAndNormalises() async throws {
        let service = try service()
        let saved = try await service.setPhone(currentPassword: password, phone: "+966 50 123 4567")
        XCTAssertEqual(saved.phone, "+966501234567", "spaces should be normalised away")

        let cleared = try await service.setPhone(currentPassword: password, phone: nil)
        XCTAssertNil(cleared.phone)
    }

    func testAMalformedPhoneIsRefused() async throws {
        do {
            _ = try await service().setPhone(currentPassword: password, phone: "not-a-number")
            XCTFail("server stored a phone number that is not one")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidPhone)
        }
    }

    // MARK: - Refusals (safe to provoke: they fail by design)

    /// A session proves someone signed in once, not that the person holding
    /// the device now is the account holder.
    func testChangingAPhoneWithTheWrongPasswordIsRefused() async throws {
        do {
            _ = try await service().setPhone(currentPassword: "not-the-password", phone: "+966500000000")
            XCTFail("a credential change went through without the current password")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCredentials)
        }
    }

    func testAnEmailChangeWithTheWrongPasswordIsRefused() async throws {
        do {
            _ = try await service().requestEmailChange(
                currentPassword: "not-the-password",
                newEmail: "someone-else@example.com"
            )
            XCTFail("an email change was accepted without the current password")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCredentials)
        }
    }

    /// Verifies the deletion gate **without deleting anything**: both the
    /// confirmation word and the password are wrong, so the request cannot
    /// succeed whichever the server checks first.
    func testDeletionIsRefusedWithoutTheExactConfirmation() async throws {
        do {
            _ = try await service().requestDeletion(
                DeletionConfirmation(currentPassword: "not-the-password", typedWord: "delete")
            )
            XCTFail("an account deletion was accepted with a lowercase word and a wrong password")
        } catch let error as APIError {
            XCTAssertTrue(
                [.confirmationRequired, .invalidCredentials].contains(error.code),
                "expected a refusal, got \(error.code)"
            )
        }
    }

    // MARK: - Export

    func testTheExportIsJSONAndContainsTheAccount() async throws {
        let data = try await service().exportData()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "an export that is not JSON is not portable, which is the point of it"
        )
        XCTAssertFalse(object.isEmpty)
    }

    // MARK: - Helpers

    /// The smallest valid JPEG this test can hand the server, built rather than
    /// checked in so the suite carries no binary fixture.
    private static func jpegBytes() -> Data {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
