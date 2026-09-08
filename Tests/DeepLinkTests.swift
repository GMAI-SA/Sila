import XCTest
@testable import Sila

/// A share produces a link; a tap on that link comes back as a screen. The
/// two have to agree, and a look-alike host must never drive navigation.
final class DeepLinkTests: XCTestCase {

    func testAPostPermalinkRoundTrips() {
        let id = UUID()
        let url = Permalink.post(id)
        XCTAssertEqual(url.absoluteString, "https://sila.gmai.sa/posts/\(id.uuidString.lowercased())")
        XCTAssertEqual(DeepLink.parse(url), .post(id: id))
    }

    func testAProfilePermalinkRoundTrips() {
        let url = Permalink.profile("Noura")
        XCTAssertEqual(url.absoluteString, "https://sila.gmai.sa/u/noura")
        XCTAssertEqual(DeepLink.parse(url), .profile(handle: "noura"))
    }

    func testUpperCaseIdsAndTrailingSlashesStillParse() {
        let id = UUID()
        XCTAssertEqual(DeepLink.parse(URL(string: "https://sila.gmai.sa/posts/\(id.uuidString)/")!), .post(id: id))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://SILA.gmai.sa/u/faisal")!), .profile(handle: "faisal"))
    }

    func testOtherHostsAndSchemesAreIgnored() {
        let id = UUID()
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa.evil.example/posts/\(id.uuidString)")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://evil.example/posts/\(id.uuidString)")!))
        XCTAssertNil(DeepLink.parse(URL(string: "http://sila.gmai.sa/posts/\(id.uuidString)")!))
    }

    func testPathsThatNameNoScreenAreIgnored() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa/")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa/legal/terms")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa/posts/not-a-uuid")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa/posts")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa/u/")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://sila.gmai.sa/u/a/b")!))
    }
}
