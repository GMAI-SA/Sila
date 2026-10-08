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
                        #if DEBUG
                        // `-openLink URL`: a UI journey's way to tap a link.
                        // Debug builds only (FeatureFlags.readsTestArguments).
                        if let link = FeatureFlags.launchLink() {
                            container.open(link)
                        }
                        #endif
                        await container.pushRegistrar.refreshRegistration()
                    }
                    // The socket: up in the foreground, closed in the
                    // background (the push covers the time between).
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        switch phase {
                        case .active: container.sceneChanged(active: true)
                        case .background: container.sceneChanged(active: false)
                        default: break
                        }
                    }
                    // …and only while somebody is signed in and not suspended.
                    .onChange(of: container.session.route) { container.updateRealtime() }
                    .onChange(of: container.session.user?.id) { container.updateRealtime() }
                    .onChange(of: container.suspension.isSuspended) { container.updateRealtime() }
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
                        // A video iOS stopped compressing while the app was
                        // away starts again now, by itself.
                        container.videoUploads.sceneDidBecomeActive()
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
