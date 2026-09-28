import SwiftUI

/// Sila's entry point.
///
/// Builds the one and only ``AppContainer`` and hands it to ``RootView``.
/// Nothing else in the app constructs dependencies.
@main
@MainActor
struct SilaApp: App {

    @State private var container = AppContainer()
    @UIApplicationDelegateAdaptor(SilaAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if AppConfig.isRunningUnitTests {
                // The unit-test bundle is hosted by this app. Rendering the
                // real UI here would run animations for the whole test run.
                Color.black.ignoresSafeArea()
            } else {
                RootView(container: container)
                    .preferredColorScheme(.dark)
                    // Universal links (sila.gmai.sa/posts/…, /u/…). Held on the
                    // router; the tab view opens it when it can.
                    .onOpenURL { url in
                        guard let link = DeepLink.parse(url) else { return }
                        container.open(link)
                    }
                    .task {
                        container.analytics.track(
                            .appLaunched,
                            properties: ["mockAuth": String(container.flags.useMockAuth)]
                        )
                        appDelegate.registrar = container.pushRegistrar
                        container.pushRegistrar.openLink = { link in container.open(link) }
                        // "@noura confirmed your vouch", arriving while the
                        // person waits at the wall with the app open: the
                        // account is re-read now, not only if the banner is
                        // tapped (contract v24 §8).
                        container.pushRegistrar.onForegroundPush = { info in
                            guard PushRegistrar.isVouching(info), container.session.user != nil else { return }
                            Task { await container.session.refreshUser() }
                        }
                        // `-openLink URL`: a UI journey's way to tap a link.
                        let arguments = ProcessInfo.processInfo.arguments
                        if let index = arguments.firstIndex(of: "-openLink"), arguments.indices.contains(index + 1),
                           let url = URL(string: arguments[index + 1]), let link = DeepLink.parse(url) {
                            container.open(link)
                        }
                        await container.pushRegistrar.refreshRegistration()
                    }
                    // Every foreground: retention is measured from this.
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        guard phase == .active else { return }
                        container.analytics.track(.appOpened)
                        // Opened on the cached account because the server
                        // could not be reached: try it again now.
                        container.session.retryIfOffline()
                        // A claim waiting at the wall: the voucher may have
                        // answered while the app was away.
                        if container.session.user?.vouch?.isPending == true {
                            Task { await container.session.refreshUser() }
                        }
                    }
                    .onChange(of: container.session.user?.id) { _, id in
                        guard id != nil else { return }
                        Task { await container.pushRegistrar.refreshRegistration() }
                    }
                    // Videos still going up resume for this account, and only
                    // this one's; with nobody signed in, none run.
                    .onChange(of: container.session.user?.id, initial: true) { _, id in
                        container.videoUploads.restore(accountId: id)
                    }
            }
        }
    }
}
