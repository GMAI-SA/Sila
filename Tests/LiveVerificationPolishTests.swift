import UIKit
import XCTest
@testable import Sila

/// Contract v25 against the staging backend, through the app's own services:
/// a submission taken back and sent again, and the pre-screen turning a flat
/// colour away with a reason the app can put into words.
///
/// **Disposable accounts only, on staging only.** Each run registers its own
/// `itest-ios-…@example.com` account through the staging API's dev routes
/// (`/dev/otp/peek`, `/dev/user/set`). Production runs with dev mode off and
/// is never called. It never signs in to, reads or changes anybody else's
/// account, never runs the shared test-user purge, and the pictures it sends
/// are single colours — nothing of a person, and nothing that leaves the host
/// (the pre-screen's model is on it).
///
/// Everything — the app's own calls and the dev routes — goes to the staging
/// API through the tunnel described in ``LiveTarget``:
///
/// ```
/// ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
///   xcodebuild … test -only-testing:SilaTests/LiveVerificationPolishTests
/// ```
final class LiveVerificationPolishTests: XCTestCase {

    private let password = "Passw0rd!234"

    override func setUpWithError() throws {
        _ = try LiveTarget.api()
    }

    // MARK: - A disposable account

    private struct Disposable {
        let email: String
        let auth: AuthService
        let verification: VerificationService
    }

    private func dev(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        try await LiveTarget.dev(path, query: query, body: body)
    }

    /// Registers, confirms the address with the code the dev route shows, and
    /// declares the two claims every document submission needs.
    private func disposable() async throws -> Disposable {
        let email = "itest-ios-\(UUID().uuidString.prefix(12).lowercased())@example.com"
        let auth = AuthService(
            network: LiveTarget.network(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await auth.register(email: email, password: password)
        let peek = try await dev("otp/peek", query: [URLQueryItem(name: "email", value: email)])
        let code = try XCTUnwrap(peek["code"] as? String, "no code recorded for \(email)")
        let pair = try await auth.verifyOTP(email: email, code: code, purpose: .register)
        let verification = VerificationService(
            network: LiveTarget.network(),
            tokens: StaticAccessTokenProvider(token: pair.token.accessToken),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await verification.setNationality("US")
        _ = try await verification.setDateOfBirth("1990-01-01")
        return Disposable(email: email, auth: auth, verification: verification)
    }

    /// A flat colour: a picture of nothing, and of nobody.
    private func swatch(_ color: UIColor) -> Data {
        let size = CGSize(width: 640, height: 400)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8)!
    }

    private func submission() -> DocumentSubmission {
        var submission = DocumentSubmission(
            documentType: .passport,
            front: swatch(.lightGray),
            selfie: swatch(.brown),
            turn: swatch(.orange),
            challenges: LivenessChallenge.allCases
        )
        submission.source = .file
        return submission
    }

    // MARK: - Withdraw and start again

    func testASubmissionIsWithdrawnSentAgainAndWithdrawnOnceOnly() async throws {
        let person = try await disposable()

        let sent = try await person.verification.submitDocument(submission())
        XCTAssertEqual(sent.status, .submitted)
        var status = try await person.auth.verificationStatus()
        XCTAssertEqual(status.status, .pendingReview)
        XCTAssertTrue(status.canWithdraw, "a waiting submission can be taken back")

        let withdrawn = try await person.verification.withdrawDocument()
        XCTAssertEqual(withdrawn.status, .unstarted)
        XCTAssertFalse(withdrawn.canWithdraw)
        XCTAssertNil(withdrawn.submittedAt)
        XCTAssertEqual(withdrawn.nationality, "US", "the claims stay: the methods are offered again")
        XCTAssertEqual(withdrawn.dateOfBirth, "1990-01-01")
        status = try await person.auth.verificationStatus()
        XCTAssertEqual(status, withdrawn, "the status route agrees with the withdrawal's answer")
        let latest = try await person.verification.latestDocumentCase()
        XCTAssertNil(latest, "a withdrawn first submission reads as never sent")

        do {
            _ = try await person.verification.withdrawDocument()
            XCTFail("withdrew twice")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .nothingToWithdraw)
            XCTAssertEqual(error.userMessage, L10n.t("error.nothingToWithdraw"))
        }

        // Sent again at once, and taken back again so no test case waits in
        // the moderators' queue.
        let again = try await person.verification.submitDocument(submission())
        XCTAssertEqual(again.status, .submitted)
        let second = try await person.verification.withdrawDocument()
        XCTAssertEqual(second.status, .unstarted)
    }

    // MARK: - The pre-screen

    func testThePreScreenTurnsAFlatColourAwayWithAReasonTheAppCanSay() async throws {
        let person = try await disposable()
        // Test accounts are only screened when they opt in.
        _ = try await dev("user/set", body: ["email": person.email, "doc_screening": true])

        _ = try await person.verification.submitDocument(submission())
        var status = try await person.auth.verificationStatus()
        let deadline = Date().addingTimeInterval(180)
        while status.status == .pendingReview, Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            status = try await person.auth.verificationStatus()
        }
        guard status.status == .rejected else {
            // Undecided — the model was busy or unsure. Nothing is left in the queue.
            _ = try? await person.verification.withdrawDocument()
            return XCTFail("the pre-screen did not decide within three minutes (status \(status.status))")
        }

        let reason = try XCTUnwrap(status.rejectionReason)
        XCTAssertTrue(VerificationRejection.isScreening(reason), "expected one of the four closed reasons, got \(reason)")
        let shown = try XCTUnwrap(VerificationRejection.display(reason))
        XCTAssertNotEqual(shown, reason, "the code would have reached the screen")
        XCTAssertFalse(status.canWithdraw, "a decided case cannot be taken back")
        XCTAssertNotNil(status.reviewedAt)

        // "Try again" opens the camera for the document the case was about.
        let latest = try await person.verification.latestDocumentCase()
        XCTAssertEqual(latest?.status, .rejected)
        XCTAssertEqual(latest?.rejectionReason, reason)
        XCTAssertEqual(DocumentRetake(latest: latest).documentType, .passport)

        do {
            _ = try await person.verification.withdrawDocument()
            XCTFail("withdrew a decided case")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .nothingToWithdraw)
        }
    }
}
