import SwiftUI

/// Sila's entry point.
///
/// Builds the one and only ``AppContainer`` and hands it to ``RootView``.
/// Nothing else in the app constructs dependencies.
@main
@MainActor
struct SilaApp: App {

    @State private var container = AppContainer()

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
                    }
            }
        }
    }
}
