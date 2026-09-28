import XCTest
@testable import Sila

/// The refusals contracts v26–v28 added, each said in the app's own words, in
/// English and in Arabic — never the server's English sentence, which is for
/// developers, and never the generic fallback.
final class ServerCodesV26ToV28Tests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private struct Refusal {
        let raw: String
        let code: APIErrorCode
        let key: String
        let status: Int
    }

    private static let refusals: [Refusal] = [
        Refusal(raw: "sms_unavailable", code: .smsUnavailable, key: "error.smsUnavailable", status: 503),
        Refusal(raw: "password_too_long", code: .passwordTooLong, key: "error.passwordTooLong", status: 400),
        Refusal(raw: "reauth_required", code: .reauthRequired, key: "error.reauthRequired", status: 403),
        Refusal(raw: "reauth_unavailable", code: .reauthUnavailable, key: "error.reauthUnavailable", status: 409),
        Refusal(raw: "has_password", code: .hasPassword, key: "error.hasPassword", status: 409),
        Refusal(raw: "phone_unavailable", code: .phoneUnavailable, key: "error.phoneUnavailable", status: 409),
        Refusal(raw: "phone_is_sign_in", code: .phoneIsSignIn, key: "error.phoneIsSignIn", status: 409),
        Refusal(raw: "invalid_image_url", code: .invalidImageURL, key: "error.invalidImageUrl", status: 400),
        Refusal(raw: "image_unavailable", code: .imageUnavailable, key: "error.imageUnavailable", status: 400),
        Refusal(raw: "request_too_large", code: .requestTooLarge, key: "error.requestTooLarge", status: 413),
        Refusal(raw: "gif_unavailable", code: .gifUnavailable, key: "error.gifUnavailable", status: 503),
        Refusal(raw: "invalid_gif", code: .invalidGif, key: "error.invalidGif", status: 400),
    ]

    private func decoded(_ refusal: Refusal) -> APIError {
        let body = #"{"detail": {"code": "\#(refusal.raw)", "message": "The server's own words"}}"#
        return URLSessionNetworkClient.makeError(status: refusal.status, data: Data(body.utf8))
    }

    func testEveryNewCodeIsRecognised() {
        for refusal in Self.refusals {
            XCTAssertEqual(APIErrorCode(serverCode: refusal.raw), refusal.code, refusal.raw)
            XCTAssertEqual(decoded(refusal).code, refusal.code, refusal.raw)
        }
    }

    /// Off the wire exactly as the server sends it, the sentence is the app's.
    func testEachIsSaidInTheAppsOwnWords() {
        XCTAssertTrue(L10n.use("en"))
        for refusal in Self.refusals {
            let message = decoded(refusal).userMessage
            XCTAssertEqual(message, L10n.t(refusal.key), refusal.raw)
            XCTAssertNotEqual(message, refusal.key, "\(refusal.key) is missing from the catalog")
            XCTAssertNotEqual(message, "The server's own words", "\(refusal.raw) repeats the server")
        }
        let sentences = Set(Self.refusals.map { decoded($0).userMessage })
        XCTAssertEqual(sentences.count, Self.refusals.count, "two refusals share a sentence")
    }

    /// Each in its own language only: Arabic script, and no English left in it.
    func testEachHasItsOwnArabicSentence() {
        XCTAssertTrue(L10n.use("en"))
        let english = Dictionary(uniqueKeysWithValues: Self.refusals.map { ($0.raw, decoded($0).userMessage) })
        guard L10n.use("ar") else {
            return XCTFail("the build has no Arabic resources — the catalog did not compile")
        }
        for refusal in Self.refusals {
            let arabic = decoded(refusal).userMessage
            XCTAssertNotEqual(arabic, english[refusal.raw], "\(refusal.raw) renders English in Arabic")
            XCTAssertNotNil(arabic.range(of: "\\p{Arabic}", options: .regularExpression), "\(refusal.raw): \(arabic)")
            XCTAssertNil(arabic.range(of: "[A-Za-z]", options: .regularExpression), "\(refusal.raw) mixes in English: \(arabic)")
        }
    }

    /// The password limit is bytes, so the sentence gives both alphabets.
    func testThePasswordLimitNamesBothAlphabets() {
        XCTAssertTrue(L10n.use("en"))
        let english = L10n.t("error.passwordTooLong")
        XCTAssertTrue(english.contains("72") && english.contains("36"), english)
        XCTAssertTrue(L10n.use("ar"))
        let arabic = L10n.t("error.passwordTooLong")
        XCTAssertTrue(arabic.contains("72") && arabic.contains("36"), arabic)
    }

    /// Since contract v27 a picture is refused over 40 MB, not 5.
    func testThePictureSizeRefusalNamesTheServersLimit() {
        XCTAssertTrue(L10n.use("en"))
        XCTAssertTrue(APIError.api(code: .imageTooLarge, message: "", status: 413).userMessage.contains("40 MB"))
        XCTAssertTrue(L10n.use("ar"))
        XCTAssertTrue(APIError.api(code: .imageTooLarge, message: "", status: 413).userMessage.contains("40"))
    }

    /// Where a phone account without a password is sent: the sign-in screen's
    /// own "Forgot password?" button, named as it is labelled.
    func testReauthUnavailableNamesTheButtonThatSetsAPassword() {
        XCTAssertTrue(L10n.use("en"))
        XCTAssertTrue(L10n.t("error.reauthUnavailable").contains(L10n.t("auth.signIn.forgotPassword")))
        XCTAssertTrue(L10n.use("ar"))
        XCTAssertTrue(L10n.t("error.reauthUnavailable").contains(L10n.t("auth.signIn.forgotPassword")))
    }
}
