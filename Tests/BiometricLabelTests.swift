import XCTest
@testable import Sila

/// The Face ID prompt names an *identity*, not a credential.
///
/// Phone-registered accounts carry a placeholder address
/// (`…@phone.sila.invalid`); showing it in the biometric prompt would put
/// machine noise on screen at the exact moment the app is asking for trust.
/// The label prefers handle → phone → email, and credentials stored by builds
/// that predate labels keep working via the email fallback.
@MainActor
final class BiometricLabelTests: XCTestCase {

    private func makeStore() -> (AuthTokenStore, InMemoryKeychainClient, InMemoryStorageClient) {
        let keychain = InMemoryKeychainClient()
        let storage = InMemoryStorageClient()
        return (AuthTokenStore(keychain: keychain, storage: storage), keychain, storage)
    }

    private func user(
        email: String,
        handle: String? = nil,
        phone: String? = nil
    ) -> AuthUser {
        AuthUser(
            id: UUID(),
            email: email,
            emailVerified: true,
            verificationStatus: .verified,
            createdAt: Date(),
            handle: handle,
            phone: phone
        )
    }

    // MARK: - Label preference order

    func testLabelPrefersHandleOverPlaceholderEmail() {
        let account = user(
            email: "u1998877665@phone.sila.invalid",
            handle: "noura",
            phone: "+966501234567"
        )
        XCTAssertEqual(account.biometricIdentityLabel, "@noura")
    }

    func testLabelFallsBackToPhoneWhenThereIsNoHandle() {
        let account = user(
            email: "u1998877665@phone.sila.invalid",
            phone: "+966501234567"
        )
        XCTAssertEqual(account.biometricIdentityLabel, "+966501234567")
    }

    func testLabelFallsBackToEmailWhenThereIsNothingElse() {
        let account = user(email: "aziz@example.com")
        XCTAssertEqual(account.biometricIdentityLabel, "aziz@example.com")
    }

    func testEmptyHandleDoesNotWinOverPhone() {
        let account = user(email: "x@phone.sila.invalid", handle: "", phone: "+966501234567")
        XCTAssertEqual(account.biometricIdentityLabel, "+966501234567")
    }

    // MARK: - Store round trip

    func testStoreKeepsLabelAndEmailSeparately() async {
        let (store, _, _) = makeStore()

        await store.enableBiometrics(for: "u1@phone.sila.invalid", label: "@noura")

        let email = await store.biometricEmail()
        let label = await store.biometricLabel()
        XCTAssertEqual(email, "u1@phone.sila.invalid", "prefill still needs the raw address")
        XCTAssertEqual(label, "@noura", "the prompt shows the identity, never the placeholder")
    }

    /// A credential written by a build that predates labels: only the email is
    /// in the keychain. It must keep working — shown as the email, exactly as
    /// it always was.
    func testCredentialFromAnOlderBuildFallsBackToItsEmail() async {
        let (store, keychain, storage) = makeStore()
        try? keychain.saveString("aziz@example.com", for: .biometricEmail)
        storage.setFlag(true, for: .biometricEnabled)

        let label = await store.biometricLabel()
        XCTAssertEqual(label, "aziz@example.com")
    }

    func testReenablingWithoutALabelClearsTheStaleOne() async {
        let (store, _, _) = makeStore()
        await store.enableBiometrics(for: "a@example.com", label: "@old")

        await store.enableBiometrics(for: "b@example.com", label: nil)

        let label = await store.biometricLabel()
        XCTAssertEqual(label, "b@example.com", "a label belonging to the previous account must not survive")
    }

    func testClearWipesTheLabel() async {
        let (store, _, _) = makeStore()
        await store.enableBiometrics(for: "a@example.com", label: "@aziz")

        await store.clear()

        let label = await store.biometricLabel()
        XCTAssertNil(label)
    }

    // MARK: - The prompt itself

    /// End to end through `AuthService`: sign in as a phone-registered account
    /// whose server profile carries a handle, then unlock biometrically — the
    /// reason handed to the Face ID prompt must name the handle, never the
    /// placeholder address.
    func testBiometricPromptNamesTheHandleNotThePlaceholderEmail() async throws {
        final class RecordingBiometrics: BiometricAuthenticating, @unchecked Sendable {
            let availableBiometry: BiometryKind = .faceID
            private(set) var reasons: [String] = []
            func authenticate(reason: String) async throws { reasons.append(reason) }
        }

        let pairJSON = """
        {"access_token": "a1", "refresh_token": "r1",
         "expires_at": "2030-01-01T00:00:00Z",
         "user": {"id": "11111111-2222-3333-4444-555555555555",
                  "email": "u1998877665@phone.sila.invalid",
                  "email_verified": true, "verification_status": "verified",
                  "created_at": "2026-01-01T00:00:00Z",
                  "handle": "noura", "phone": "+966501234567"}}
        """
        let network = StubNetworkClient(responses: [pairJSON, pairJSON])
        let biometrics = RecordingBiometrics()
        let (store, _, _) = makeStore()
        let service = AuthService(
            network: network,
            store: store,
            biometrics: biometrics,
            analytics: RecordingAnalyticsClient()
        )

        _ = try await service.signIn(email: "u1998877665@phone.sila.invalid", password: "secret")
        _ = try await service.signInBiometric()

        let reason = try XCTUnwrap(biometrics.reasons.first)
        XCTAssertTrue(reason.contains("@noura"), "the prompt should name the handle: \(reason)")
        XCTAssertFalse(reason.contains("phone.sila.invalid"), "the placeholder reached the prompt: \(reason)")
    }
}
