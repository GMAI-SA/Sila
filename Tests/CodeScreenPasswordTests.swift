import XCTest
@testable import Sila

/// The password travels with the code (contract v26 §7.1).
///
/// When a code confirms an address for the first time, the password beside it
/// is the one the account takes — not whichever registration of the address,
/// perhaps a stranger's, the server has on file. So the code screen after
/// registering sends the registration's password again, and the one after a
/// sign-in that answered `email_unverified` sends the password just typed.
/// It is held in memory for as long as that screen is up, and nowhere else.
@MainActor
final class CodeScreenPasswordTests: XCTestCase {

    private static let password = "Str0ng!Passw0rd"

    // MARK: - Registration

    func testTheRegistrationCodeScreenSendsTheRegistrationsPassword() async {
        let service = AuthServiceMock(scenario: .unstarted)
        let register = RegisterViewModel(service: service)
        register.email = "aziz@example.com"
        register.password = Self.password
        register.confirmPassword = Self.password

        await register.submit()

        let email = register.consumeRegisteredEmail()
        let password = register.consumeRegisteredPassword()
        XCTAssertEqual(email, "aziz@example.com")
        XCTAssertEqual(password, Self.password)
        XCTAssertNil(register.consumeRegisteredPassword(), "handed over once, then not kept")

        let code = OTPVerificationViewModel(email: "aziz@example.com", purpose: .register, password: password, service: service)
        code.paste("123456")
        await code.verify()

        XCTAssertNotNil(code.consumeVerifiedPair())
        let sent = await service.verifiedPasswords
        XCTAssertEqual(sent, [Self.password])
    }

    func testARegistrationTheServerRefusedHandsOverNoPassword() async {
        let service = AuthServiceMock(scenario: .offline)
        let register = RegisterViewModel(service: service)
        register.email = "aziz@example.com"
        register.password = Self.password
        register.confirmPassword = Self.password

        await register.submit()

        XCTAssertNil(register.consumeRegisteredEmail())
        XCTAssertNil(register.consumeRegisteredPassword())
    }

    /// The code screen a relaunch opens on an unconfirmed session: nobody
    /// typed a password on this launch, so the code goes alone.
    func testACodeScreenWithNoPasswordSendsTheCodeAlone() async {
        let service = AuthServiceMock(scenario: .unstarted)
        let code = OTPVerificationViewModel(email: "aziz@example.com", purpose: .login, service: service)
        code.paste("123456")
        await code.verify()

        let sent = await service.verifiedPasswords
        XCTAssertEqual(sent, [nil])
    }

    // MARK: - Sign-in that answered email_unverified

    func testASignInThatNeedsTheCodeHandsTheTypedPasswordToTheCodeScreen() async {
        let service = AuthServiceMock(scenario: .emailUnverified)
        let signIn = SignInViewModel(service: service)
        signIn.email = "aziz@example.com"
        signIn.password = Self.password

        await signIn.submit()

        XCTAssertEqual(signIn.password, "", "the field is still cleared")
        XCTAssertEqual(signIn.consumeNeedsEmailVerification(), "aziz@example.com")
        XCTAssertEqual(signIn.consumePasswordForCode(), Self.password)
        XCTAssertNil(signIn.consumePasswordForCode(), "handed over once, then not kept")
    }

    func testAWrongPasswordHandsNothingOver() async {
        let service = AuthServiceMock(scenario: .invalidCredentials)
        let signIn = SignInViewModel(service: service)
        signIn.email = "aziz@example.com"
        signIn.password = "wrong-password"

        await signIn.submit()

        XCTAssertNil(signIn.consumeNeedsEmailVerification())
        XCTAssertNil(signIn.consumePasswordForCode())
    }

    // MARK: - The router holds it for the code screen, not in the route

    func testTheRouterHandsThePasswordOnlyToTheCodeScreenItWasTypedFor() {
        let router = AppRouter()
        router.push(.register)
        router.pushCodeScreen(email: "aziz@example.com", purpose: .register, password: Self.password)

        XCTAssertEqual(router.authPath, [.register, .otp(email: "aziz@example.com", purpose: .register)],
                       "the route carries the address and the purpose, never the password")
        XCTAssertEqual(router.password(forCodeTo: "aziz@example.com"), Self.password)
        XCTAssertNil(router.password(forCodeTo: "someone@example.com"))

        // Swiped back to the form: the code screen is gone, and so is its password.
        router.pop()
        XCTAssertNil(router.password(forCodeTo: "aziz@example.com"))
    }

    func testReturningToTheWelcomeScreenForgetsThePassword() {
        let router = AppRouter()
        router.replaceWithOTP(email: "aziz@example.com", purpose: .login, password: Self.password)
        XCTAssertEqual(router.password(forCodeTo: "aziz@example.com"), Self.password)

        router.popToRoot()
        router.push(.otp(email: "aziz@example.com", purpose: .login))
        XCTAssertNil(router.password(forCodeTo: "aziz@example.com"), "a later code screen does not inherit it")
    }

    func testANewCodeScreenReplacesThePasswordOfTheLastOne() {
        let router = AppRouter()
        router.replaceWithOTP(email: "aziz@example.com", purpose: .login, password: Self.password)
        router.replaceWithOTP(email: "aziz@example.com", purpose: .login)
        XCTAssertNil(router.password(forCodeTo: "aziz@example.com"))
    }

    // MARK: - On the wire

    private func verify(password: String?) async throws -> [String: Any] {
        let network = ScriptedNetwork { _ in AuthFixtures.pairJSON(access: "a", refresh: "r") }
        let service = AuthService(
            network: network,
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: .isolated()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await service.verifyOTP(email: "Aziz@Example.com", code: "123456", purpose: .register, password: password)
        let request = try XCTUnwrap(network.requests.first { $0.path == "/auth/otp/verify" })
        let body = try XCTUnwrap(request.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testTheCodeAndThePasswordGoTogether() async throws {
        let body = try await verify(password: Self.password)
        XCTAssertEqual(body["email"] as? String, "aziz@example.com")
        XCTAssertEqual(body["code"] as? String, "123456")
        XCTAssertEqual(body["purpose"] as? String, "register")
        XCTAssertEqual(body["password"] as? String, Self.password)
    }

    func testWithoutAPasswordTheFieldIsLeftOut() async throws {
        let body = try await verify(password: nil)
        XCTAssertNil(body["password"], "a server before the field must see the body it always saw")
    }

    /// The server checks the password before the code, and refuses one that
    /// does not fit — which would keep somebody whose old password predates
    /// the 72-byte rule from ever confirming their address. Such a password
    /// is not sent; the code is judged on its own.
    func testAPasswordTheServerWouldRefuseIsNotSent() async throws {
        let tooManyBytes = String(repeating: "ب", count: 37)   // 74 bytes
        let tooShort = "short"
        let tooLong = String(repeating: "a", count: 129)
        for password in [tooManyBytes, tooShort, tooLong] {
            let body = try await verify(password: password)
            XCTAssertNil(body["password"], "\(password.utf8.count) bytes, \(password.count) characters")
        }

        let latinLimit = String(repeating: "a", count: 72)
        let arabicLimit = String(repeating: "ب", count: 36)   // 72 bytes
        for password in [latinLimit, arabicLimit] {
            let body = try await verify(password: password)
            XCTAssertEqual(body["password"] as? String, password)
        }
    }
}
