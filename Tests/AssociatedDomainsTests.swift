import XCTest
@testable import Sila

/// The links the site hands to the app and the links the app can read are
/// the same list (round-2 security finding CA-3, the iOS half).
///
/// `site` is a copy of the `applinks` components that
/// https://sila.gmai.sa/.well-known/apple-app-site-association served on
/// 2026-10-08 (200, application/json, app ID 7258Y6294P.com.socialsa.sila).
/// A path the site claims for the app but ``DeepLink`` cannot read opens
/// the app on nothing — the link is swallowed; a path the app reads but the
/// site does not claim never reaches it. When the site's file changes, this
/// copy changes with it, and the test says which side is behind.
///
/// Communities (`/c/…`) and hashtags (`/tags/…`) are deliberately on
/// neither list: the app has no link for them, so Safari keeps them.
final class AssociatedDomainsTests: XCTestCase {

    private struct Component {
        let pattern: String
        let exclude: Bool
    }

    /// In the site's order: the first component that matches decides.
    private static let site: [Component] = [
        Component(pattern: "/posts/*", exclude: false),
        Component(pattern: "/u/*", exclude: false),
        Component(pattern: "/events/new", exclude: true),
        Component(pattern: "/events/*", exclude: false),
        Component(pattern: "/rooms/series/*", exclude: true),
        Component(pattern: "/rooms/*", exclude: false),
        Component(pattern: "/vouch/*", exclude: false),
        Component(pattern: "/vouch", exclude: false),
        Component(pattern: "/vouching", exclude: false),
    ]

    private static let appID = "7258Y6294P.com.socialsa.sila"
    private static let id = "00000000-0000-4000-8000-000000000702"

    /// Whether the site hands `path` to the app, the way iOS reads the
    /// components: in order, `*` any run of characters, `?` one.
    private func siteClaims(_ path: String) -> Bool {
        for component in Self.site where glob(component.pattern, path) {
            return !component.exclude
        }
        return false
    }

    private func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        func match(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == t.count }
            if p[i] == "*" { return (j...t.count).contains { match(i + 1, $0) } }
            guard j < t.count, p[i] == "?" || p[i] == t[j] else { return false }
            return match(i + 1, j + 1)
        }
        return match(0, 0)
    }

    private func appReads(_ path: String) -> Bool {
        DeepLink.parse(URL(string: "https://sila.gmai.sa\(path)")!) != nil
    }

    /// Every link the app makes or reads is one the site hands over.
    func testEveryLinkTheAppReadsIsClaimedByTheSite() {
        for path in [
            "/posts/\(Self.id)", "/u/noura", "/events/\(Self.id)", "/rooms/\(Self.id)",
            "/vouch/abcdefghijklmnopqrstuvwxyz012345", "/vouch", "/vouching",
        ] {
            XCTAssertTrue(appReads(path), "the app cannot read \(path)")
            XCTAssertTrue(siteClaims(path), "the site does not hand \(path) to the app")
        }
        for url in [Permalink.post(UUID()), Permalink.event(UUID()), Permalink.room(UUID()), Permalink.profile("noura")] {
            XCTAssertTrue(siteClaims(url.path), "a link the app shares does not come back to it: \(url.path)")
        }
    }

    /// What the site keeps for Safari, the app does not read either.
    func testWhatTheSiteKeepsTheAppDoesNotRead() {
        for path in ["/events/new", "/rooms/series/\(Self.id)", "/c/riyadh", "/tags/coffee", "/rooms", "/messages", "/"] {
            XCTAssertFalse(siteClaims(path), "the site hands \(path) to the app")
            XCTAssertFalse(appReads(path), "the app reads \(path), which the site keeps for Safari")
        }
    }

    /// The app claims the domain the file is served from, for links and
    /// for passwords, and the file names this app.
    func testTheEntitlementsClaimTheSitesDomain() throws {
        let entitlements = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sila/Resources/Sila.entitlements")
        let data = try Data(contentsOf: entitlements)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let domains = try XCTUnwrap(plist["com.apple.developer.associated-domains"] as? [String])
        let host = try XCTUnwrap(Permalink.base.host)
        XCTAssertEqual(Set(domains), ["applinks:\(host)", "webcredentials:\(host)"])
        XCTAssertEqual(Bundle.main.bundleIdentifier.map { "7258Y6294P.\($0)" }, Self.appID)
    }
}
