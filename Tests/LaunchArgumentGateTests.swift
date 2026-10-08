import XCTest
@testable import Sila

/// Security round 2: the mock and test-only launch arguments are read by
/// debug builds only, the way `-apiOrigin` is. A release build (TestFlight,
/// the store) is checked here by passing `readsTestArguments: false`, which
/// is what its compiled default is.
final class LaunchArgumentGateTests: XCTestCase {

    private let everyMock = [
        "Sila", "-mockAuth", "-mockScenario", "verified", "-mockVerification", "-mockFeed",
        "-mockFeedScenario", "empty", "-mockComposer", "-mockSearch", "-mockPreferences", "-mockAccount",
        "-mockProfile", "-mockSafety", "-mockNotifications", "-mockRooms", "-mockVoiceEngine",
        "-mockGuestRooms", "-mockVouching", "-mockMessages", "-mockRealtime", "quiet", "-mockVideo",
        "-mockRetentionConsent", "-mockKeptPhotos",
    ]

    func testThisTestBuildIsADebugBuildThatReadsThem() {
        XCTAssertTrue(FeatureFlags.readsTestArguments)
        XCTAssertTrue(FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"]).useMockAuth)
    }

    func testAReleaseBuildIgnoresEveryMockSwitch() {
        let flags = FeatureFlags.resolved(arguments: everyMock, readsTestArguments: false)
        let mocks: [Bool] = [
            flags.useMockAuth, flags.useMockVerification, flags.useMockFeed, flags.useMockComposer,
            flags.useMockSearch, flags.useMockPreferences, flags.useMockAccount, flags.useMockProfile,
            flags.useMockSafety, flags.useMockNotifications, flags.useMockRooms, flags.useMockVoiceEngine,
            flags.useMockGuestRooms, flags.useMockVouching, flags.useMockMessages, flags.useMockRealtime,
            flags.useMockVideo, flags.mockRetentionConsent, flags.mockKeptPhotos,
        ]
        XCTAssertEqual(mocks, Array(repeating: false, count: mocks.count))
    }

    func testAReleaseBuildStillHonoursTheKillSwitches() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockAuth", "-noVideoPosts", "-noRealtime", "-noBiometrics"],
            readsTestArguments: false
        )
        XCTAssertFalse(flags.useMockAuth)
        XCTAssertFalse(flags.videoPosts)
        XCTAssertFalse(flags.realtime)
        XCTAssertFalse(flags.biometricSignIn)
    }

    func testTheReleaseFilterDropsTestOptionsAndTheirValues() {
        let raw = [
            "Sila", "-mockScenario", "verified", "-noRealtime", "-openLink", "https://sila.gmai.sa/u/noura",
            "-freshStorage", "-videoAutoplay", "on", "-mockVideoPick", "short", "-nafathAvailable",
            "-mockSlowDocumentUpload", "-resetVideoUploads", "-apiOrigin", "http://127.0.0.1:8101", "-noOnboarding",
        ]
        XCTAssertEqual(FeatureFlags.launchArguments(raw, readsTestArguments: false), ["Sila", "-noRealtime", "-noOnboarding"])
        XCTAssertEqual(FeatureFlags.launchArguments(raw, readsTestArguments: true), raw)
    }

    func testOpenLinkIsDebugOnly() {
        let arguments = ["Sila", "-openLink", "https://sila.gmai.sa/u/noura"]
        XCTAssertEqual(FeatureFlags.launchLink(arguments: arguments, readsTestArguments: true), .profile(handle: "noura"))
        XCTAssertNil(FeatureFlags.launchLink(arguments: arguments, readsTestArguments: false))
        XCTAssertNil(FeatureFlags.launchLink(arguments: ["Sila", "-openLink"], readsTestArguments: true))
        XCTAssertNil(
            FeatureFlags.launchLink(arguments: ["Sila", "-openLink", "https://sila.gmai.sa.evil.example/u/x"], readsTestArguments: true)
        )
    }
}
