import Foundation
import Observation
import UIKit
import UserNotifications

/// Push notifications: asking, registering, and opening what was tapped.
///
/// Never asks on first launch. The prompt comes after somebody has done
/// something that makes a reply or a reminder worth hearing about — posting,
/// voting, following, setting a room reminder — and only once.
///
/// The payload carries a localisation key and ids only (contract v21): the
/// words are the app's own `push.<kind>` strings, so nothing anybody wrote
/// crosses Apple's servers.
@MainActor
@Observable
public final class PushRegistrar {

    public private(set) var status: UNAuthorizationStatus = .notDetermined
    public private(set) var deviceToken: String?

    private let service: PushServiceProtocol
    private let storage: StorageClient
    private let analytics: AnalyticsClient
    private let isSignedIn: @MainActor () -> Bool
    private let center: UNUserNotificationCenter?
    /// Opens a universal link inside the app.
    var openLink: (@MainActor (DeepLink) -> Void)?

    static let askedKey = StorageKey("com.socialsa.sila.pushAsked")
    static let tokenKey = StorageKey("com.socialsa.sila.pushToken")

    /// `sandbox` in debug builds, `production` for TestFlight and the store.
    public static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    public init(
        service: PushServiceProtocol,
        storage: StorageClient,
        analytics: AnalyticsClient,
        isSignedIn: @escaping @MainActor () -> Bool,
        center: UNUserNotificationCenter? = AppConfig.isRunningUnitTests ? nil : .current()
    ) {
        self.service = service
        self.storage = storage
        self.analytics = analytics
        self.isSignedIn = isSignedIn
        self.center = center
        self.deviceToken = storage.value(for: Self.tokenKey, as: String.self)
    }

    /// Whether the system prompt has been shown by Sila already.
    public var hasAsked: Bool { storage.flag(Self.askedKey) }

    // MARK: - Asking

    /// Called after a meaningful action. Asks once; afterwards only makes sure
    /// the phone is registered.
    public func requestIfAppropriate(after action: String) async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined:
            guard !hasAsked else { return }
            storage.setFlag(true, for: Self.askedKey)
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            analytics.track(.pushPermissionAnswered, properties: ["result": granted ? "granted" : "denied", "source": action])
            status = granted ? .authorized : .denied
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    /// On launch and after sign-in: a phone already allowed re-registers, so a
    /// rotated token or a new account reaches the server.
    public func refreshRegistration() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await sendToken()
    }

    // MARK: - Tokens

    /// APNs answered with this phone's token.
    public func didRegister(deviceToken data: Data) async {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        storage.set(token, for: Self.tokenKey)
        await sendToken()
    }

    private func sendToken() async {
        guard let deviceToken, isSignedIn() else { return }
        try? await service.register(token: deviceToken, environment: Self.environment)
    }

    /// Before the access token is dropped: this phone stops getting this
    /// account's pushes.
    public func willSignOut() async {
        guard let deviceToken else { return }
        try? await service.unregister(token: deviceToken)
    }

    // MARK: - Opening

    /// A push was tapped: open where it points, and say it was opened.
    public func handleTap(userInfo: [AnyHashable: Any]) async {
        if let raw = userInfo["url"] as? String, let url = URL(string: raw), let link = DeepLink.parse(url) {
            openLink?(link)
        }
        analytics.track(.pushOpened, properties: ["kind": userInfo["kind"] as? String ?? "unknown"])
        if let pushId = userInfo["push_id"] as? String, isSignedIn() {
            try? await service.markOpened(pushId: pushId)
        }
    }
}

/// The app delegate, only for what SwiftUI has no hook for: the APNs token and
/// the notification centre's delegate.
final class SilaAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    @MainActor weak var registrar: PushRegistrar?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if !AppConfig.isRunningUnitTests {
            UNUserNotificationCenter.current().delegate = self
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await registrar?.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// In the foreground: show it as a banner, like anywhere else.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { [weak self] in
            Task { await self?.registrar?.handleTap(userInfo: info) }
        }
    }
}
