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
                        container.router.pendingLink = link
                    }
                    .task {
                        container.analytics.track(
                            .appLaunched,
                            properties: ["mockAuth": String(container.flags.useMockAuth)]
                        )
                        appDelegate.registrar = container.pushRegistrar
                        container.pushRegistrar.openLink = { link in container.router.pendingLink = link }
                        await container.pushRegistrar.refreshRegistration()
                    }
                    // Every foreground: retention is measured from this.
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        guard phase == .active else { return }
                        container.analytics.track(.appOpened)
                    }
                    .onChange(of: container.session.user?.id) { _, id in
                        guard id != nil else { return }
                        Task { await container.pushRegistrar.refreshRegistration() }
                    }
            }
        }
    }
}
